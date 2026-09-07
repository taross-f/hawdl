import Darwin
import Foundation

/// Helpers around `sockaddr_un`, whose fixed-size `sun_path` tuple is awkward
/// to fill in from Swift.
public enum UnixSocket {
    /// `sun_path` is 104 bytes on Darwin, and the last one must be the NUL.
    public static let maxPathLength = MemoryLayout<sockaddr_un>.size
        - MemoryLayout<UInt8>.size   // sun_len
        - MemoryLayout<sa_family_t>.size // sun_family
        - 1

    public enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case systemCall(name: String, code: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                return "socket path is longer than \(UnixSocket.maxPathLength) bytes: \(path)"
            case .systemCall(let name, let code):
                return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else {
            throw SocketError.pathTooLong(path)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func withSockAddr<T>(
        _ addr: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                body(generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Connects a new SOCK_STREAM socket to `path`.
    public static func connect(to path: String) throws -> Int32 {
        var addr = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.systemCall(name: "socket", code: errno)
        }
        let rc = withSockAddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        guard rc == 0 else {
            let code = errno
            _ = close(fd)
            throw SocketError.systemCall(name: "connect", code: code)
        }
        suppressSIGPIPE(fd)
        return fd
    }

    /// Creates a listening socket at `path`, replacing any stale socket file.
    ///
    /// - Parameter backlog: SOMAXCONN. A short backlog makes a burst of clients
    ///   fail with ECONNREFUSED, which is indistinguishable from "the daemon is
    ///   not running" at the other end of the socket.
    public static func listen(at path: String, backlog: Int32 = 128, mode: mode_t) throws -> Int32 {
        var addr = try address(for: path)
        _ = unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.systemCall(name: "socket", code: errno)
        }

        let bound = withSockAddr(&addr) { pointer, length in
            Darwin.bind(fd, pointer, length)
        }
        guard bound == 0 else {
            let code = errno
            _ = close(fd)
            throw SocketError.systemCall(name: "bind", code: code)
        }

        // bind() applies the umask, so set the mode explicitly afterwards.
        guard chmod(path, mode) == 0 else {
            let code = errno
            _ = close(fd)
            _ = unlink(path)
            throw SocketError.systemCall(name: "chmod", code: code)
        }

        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            _ = close(fd)
            _ = unlink(path)
            throw SocketError.systemCall(name: "listen", code: code)
        }

        return fd
    }

    /// Accepts one pending connection, applying the same options as
    /// `connect(to:)`. Returns nil when nothing is pending.
    ///
    /// This exists so that the accept path and the connect path cannot drift
    /// apart: a socket that reaches the rest of the library is always
    /// non-blocking and always SIGPIPE-safe.
    public static func accept(_ listenFD: Int32) throws -> Int32? {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
                throw SocketError.systemCall(name: "accept", code: errno)
            }
            // Best effort: this fails when the peer has already hung up, which
            // is exactly the case that goes on to raise SIGPIPE on the reply.
            // The connection is still worth accepting (there may be a complete
            // request buffered in it), so the host process has to be the one
            // that disarms SIGPIPE. See the note on IPCServer.
            suppressSIGPIPE(fd)
            do {
                try setNonBlocking(fd)
            } catch {
                _ = close(fd)
                throw error
            }
            return fd
        }
    }

    /// Darwin raises SIGPIPE on a write to a socket whose peer has gone away.
    /// Setting SO_NOSIGPIPE turns that into a plain EPIPE, so neither the
    /// daemon nor a client library user has to install a signal handler to
    /// survive a peer disappearing mid-write.
    @discardableResult
    public static func suppressSIGPIPE(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    public static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw SocketError.systemCall(name: "fcntl", code: errno)
        }
    }

    public static func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        let rc = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &tv,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard rc == 0 else {
            throw SocketError.systemCall(name: "setsockopt(SO_RCVTIMEO)", code: errno)
        }
    }
}
