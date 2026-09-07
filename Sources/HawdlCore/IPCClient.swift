import Darwin
import Foundation

/// Blocking client for the daemon's newline-delimited JSON socket.
///
/// Reads use a receive timeout rather than a blocking read so that a caller on
/// a background thread (the menu bar app) can notice cancellation without
/// having to close the descriptor out from under a blocked syscall.
public final class IPCClient {
    public enum ClientError: Error, Equatable, CustomStringConvertible {
        case daemonNotRunning(String)
        case notConnected
        case connectionClosed
        case timedOut
        case io(String)
        case protocolViolation(String)

        public var description: String {
            switch self {
            case .daemonNotRunning(let path):
                return "hawdld is not running (no socket at \(path))"
            case .notConnected:
                return "not connected"
            case .connectionClosed:
                return "the daemon closed the connection"
            case .timedOut:
                return "timed out waiting for the daemon"
            case .io(let detail):
                return detail
            case .protocolViolation(let detail):
                return detail
            }
        }
    }

    public let socketPath: String
    private var fd: Int32 = -1
    private var framer: LineFramer
    private var pending: [StatusMessage] = []

    public init(socketPath: String = HawdlPaths.socket, maxLineBytes: Int = 64 * 1024) {
        self.socketPath = socketPath
        self.framer = LineFramer(maxLineBytes: maxLineBytes)
    }

    deinit {
        close()
    }

    public var isConnected: Bool { fd >= 0 }

    /// - Parameter readTimeout: how long a single `receive` may block.
    public func connect(readTimeout: TimeInterval = 5) throws {
        close()
        do {
            fd = try UnixSocket.connect(to: socketPath)
        } catch let error as UnixSocket.SocketError {
            if case .systemCall(_, let code) = error,
               code == ENOENT || code == ECONNREFUSED {
                throw ClientError.daemonNotRunning(socketPath)
            }
            throw ClientError.io(error.description)
        }
        try? UnixSocket.setReceiveTimeout(fd, seconds: readTimeout)
        framer = LineFramer(maxLineBytes: framer.maxLineBytes)
        pending.removeAll()
    }

    public func close() {
        if fd >= 0 {
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    public func send(_ request: Request) throws {
        guard fd >= 0 else { throw ClientError.notConnected }
        let data = try HawdlCodec.encodeLine(request)
        try data.withUnsafeBytes { raw -> Void in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw ClientError.io("write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Reads the next status message, blocking up to the socket's receive
    /// timeout. Throws `.timedOut` if nothing arrived in that window.
    public func receive() throws -> StatusMessage {
        guard fd >= 0 else { throw ClientError.notConnected }
        if !pending.isEmpty {
            return pending.removeFirst()
        }

        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                let lines: [Data]
                do {
                    lines = try framer.append(Data(chunk[0..<count]))
                } catch {
                    throw ClientError.protocolViolation("\(error)")
                }
                for line in lines {
                    pending.append(try HawdlCodec.decodeLine(StatusMessage.self, from: line))
                }
                if !pending.isEmpty {
                    return pending.removeFirst()
                }
                continue
            }
            if count == 0 {
                throw ClientError.connectionClosed
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ClientError.timedOut
            }
            throw ClientError.io("read failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Connect, send one command, read one reply, disconnect.
    public static func request(
        _ command: Command,
        socketPath: String = HawdlPaths.socket,
        timeout: TimeInterval = 5
    ) throws -> StatusMessage {
        let client = IPCClient(socketPath: socketPath)
        try client.connect(readTimeout: timeout)
        defer { client.close() }
        try client.send(Request(cmd: command))
        return try client.receive()
    }
}
