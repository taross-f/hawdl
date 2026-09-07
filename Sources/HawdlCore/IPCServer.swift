import Darwin
import Foundation

/// The daemon side of `/var/run/hawdl.sock`.
///
/// Everything runs on a single serial queue, so connection state needs no
/// locking. Writes are non-blocking with a bounded outbound buffer: a client
/// that stops reading gets dropped instead of wedging the daemon.
public final class IPCServer {
    /// Called for every request. Return the status to send back.
    public typealias Handler = (Command) -> StatusMessage

    private final class Connection {
        let fd: Int32
        var framer: LineFramer
        var subscribed = false
        var outbound = Data()
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var writeSourceActive = false
        /// Two dispatch sources share this descriptor; it may only be closed
        /// once both have finished cancelling.
        var liveSources = 0
        var fdClosed = false

        init(fd: Int32, maxLineBytes: Int) {
            self.fd = fd
            self.framer = LineFramer(maxLineBytes: maxLineBytes)
        }
    }

    public let socketPath: String
    public let socketMode: mode_t
    public let maxOutboundBytes: Int

    private let queue: DispatchQueue
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var log: (String) -> Void

    /// - Parameter socketMode: 0666 by default.
    ///
    ///   TODO: restrict the socket to the `admin` group (chown root:admin +
    ///   0660) so that a non-admin local account cannot toggle awdl0. That
    ///   needs the menu bar app to run as an admin user, or a small
    ///   authorization step, so it is deliberately left for a follow-up. Until
    ///   then this is documented in the README as a known limitation.
    public init(
        socketPath: String = HawdlPaths.socket,
        socketMode: mode_t = 0o666,
        maxOutboundBytes: Int = 256 * 1024,
        queue: DispatchQueue,
        log: @escaping (String) -> Void = { _ in },
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.socketMode = socketMode
        self.maxOutboundBytes = maxOutboundBytes
        self.queue = queue
        self.log = log
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(at: socketPath, mode: socketMode)
        try UnixSocket.setNonBlocking(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Closes every connection and removes the socket file.
    public func stop() {
        let all = Array(connections.values)
        connections.removeAll()
        for connection in all {
            teardown(connection)
        }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        _ = unlink(socketPath)
    }

    /// Pushes `status` to every subscriber.
    public func broadcast(_ status: StatusMessage) {
        guard let line = try? HawdlCodec.encodeLine(status) else { return }
        // Snapshot first: enqueue can drop a connection, which mutates
        // `connections` underneath the iteration.
        let subscribers = connections.values.filter(\.subscribed)
        for connection in subscribers {
            enqueue(line, to: connection)
        }
    }

    // MARK: - Accept

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                log("accept failed: \(String(cString: strerror(errno)))")
                return
            }
            do {
                try UnixSocket.setNonBlocking(fd)
            } catch {
                _ = Darwin.close(fd)
                continue
            }
            UnixSocket.suppressSIGPIPE(fd)
            register(fd: fd)
        }
    }

    private func register(fd: Int32) {
        let connection = Connection(fd: fd, maxLineBytes: 64 * 1024)
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        // Cancel handlers run on `queue`, which is serial, so this counter
        // needs no synchronisation.
        let onCancel = { [connection] in
            connection.liveSources -= 1
            if connection.liveSources <= 0, !connection.fdClosed {
                connection.fdClosed = true
                _ = Darwin.close(connection.fd)
            }
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable(connection) }
        readSource.setCancelHandler(handler: onCancel)
        connection.readSource = readSource

        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writeSource.setEventHandler { [weak self] in self?.flush(connection) }
        writeSource.setCancelHandler(handler: onCancel)
        connection.writeSource = writeSource
        connection.liveSources = 2

        readSource.resume()
    }

    // MARK: - Read

    private func readAvailable(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(connection.fd, &chunk, chunk.count)
            if count > 0 {
                let lines: [Data]
                do {
                    lines = try connection.framer.append(Data(chunk[0..<count]))
                } catch {
                    log("dropping client: \(error)")
                    drop(connection)
                    return
                }
                for line in lines {
                    handle(line: line, on: connection)
                }
                continue
            }
            if count == 0 {
                drop(connection)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            log("read failed: \(String(cString: strerror(errno)))")
            drop(connection)
            return
        }
    }

    private func handle(line: Data, on connection: Connection) {
        let request: Request
        do {
            request = try HawdlCodec.decodeLine(Request.self, from: line)
        } catch {
            log("ignoring bad request: \(error)")
            return
        }

        if request.cmd == .subscribe {
            connection.subscribed = true
        }

        let status = handler(request.cmd)
        if let payload = try? HawdlCodec.encodeLine(status) {
            enqueue(payload, to: connection)
        }
    }

    // MARK: - Write

    private func enqueue(_ data: Data, to connection: Connection) {
        connection.outbound.append(data)
        if connection.outbound.count > maxOutboundBytes {
            log("dropping client: outbound buffer over \(maxOutboundBytes) bytes")
            drop(connection)
            return
        }
        flush(connection)
    }

    private func flush(_ connection: Connection) {
        while !connection.outbound.isEmpty {
            let written: Int = connection.outbound.withUnsafeBytes { raw in
                guard let pointer = raw.baseAddress else { return 0 }
                return Darwin.write(connection.fd, pointer, raw.count)
            }
            if written > 0 {
                connection.outbound.removeFirst(written)
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                resumeWriteSource(connection)
                return
            }
            drop(connection)
            return
        }
        suspendWriteSource(connection)
    }

    private func resumeWriteSource(_ connection: Connection) {
        guard !connection.writeSourceActive else { return }
        connection.writeSourceActive = true
        connection.writeSource?.resume()
    }

    private func suspendWriteSource(_ connection: Connection) {
        guard connection.writeSourceActive else { return }
        connection.writeSourceActive = false
        connection.writeSource?.suspend()
    }

    // MARK: - Teardown

    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        teardown(connection)
    }

    /// A suspended DispatchSource traps if it is released, so the write source
    /// has to be resumed before it can be cancelled.
    private func teardown(_ connection: Connection) {
        if let readSource = connection.readSource {
            readSource.setEventHandler {}
            readSource.cancel()
            connection.readSource = nil
        }
        if let writeSource = connection.writeSource {
            writeSource.setEventHandler {}
            if !connection.writeSourceActive {
                connection.writeSourceActive = true
                writeSource.resume()
            }
            writeSource.cancel()
            connection.writeSource = nil
        }
        connection.outbound.removeAll()
    }
}
