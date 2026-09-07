import CHawdlSys
import Darwin
import Foundation
import HawdlCore

/// Watches PF_ROUTE for RTM_IFINFO messages.
///
/// This is the primary signal: when AirDrop, Handoff or a wake from sleep
/// brings awdl0 back up, the kernel tells us immediately instead of us finding
/// out on the next poll.
final class RouteMonitor {
    private let queue: DispatchQueue
    private let interfaceName: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    /// Resolved lazily: awdl0 may not exist yet when the daemon starts, and its
    /// index can change if the interface is recreated.
    private var cachedIndex: UInt32 = 0

    init(interfaceName: String, queue: DispatchQueue) {
        self.interfaceName = interfaceName
        self.queue = queue
    }

    func start(onChange: @escaping () -> Void) throws {
        let socketFD = hawdl_route_socket_open()
        guard socketFD >= 0 else {
            throw UnixSocket.SocketError.systemCall(name: "socket(PF_ROUTE)", code: errno)
        }
        try UnixSocket.setNonBlocking(socketFD)
        fd = socketFD

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(onChange: onChange)
        }
        source.setCancelHandler { _ = Darwin.close(socketFD) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func drain(onChange: @escaping () -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var interesting = false

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                if scan(buffer, length: count) {
                    interesting = true
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            break // EAGAIN / EWOULDBLOCK, or an error we cannot do anything about
        }

        if interesting {
            onChange()
        }
    }

    /// Returns true when the buffer contains an RTM_IFINFO message for our
    /// interface (or for an interface we cannot identify, in which case we
    /// reconcile rather than risk missing an event).
    private func scan(_ buffer: [UInt8], length: Int) -> Bool {
        var matched = false
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < length {
                var isIFInfo: Int32 = 0
                var index: UInt32 = 0
                let consumed = hawdl_route_message_parse(
                    base.advanced(by: offset),
                    length - offset,
                    &isIFInfo,
                    &index
                )
                guard consumed > 0 else { break }
                if isIFInfo != 0, matches(index: index) {
                    matched = true
                }
                offset += Int(consumed)
            }
        }
        return matched
    }

    private func matches(index: UInt32) -> Bool {
        if index == 0 { return true }
        if cachedIndex != index {
            // The index can change if the interface is torn down and recreated,
            // so re-resolve rather than trusting a stale cache.
            cachedIndex = interfaceName.withCString { if_nametoindex($0) }
        }
        // If the interface is gone we cannot resolve an index; reconcile anyway
        // so the daemon notices it came back.
        if cachedIndex == 0 { return true }
        return cachedIndex == index
    }
}
