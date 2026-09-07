import CHawdlSys
import Darwin
import Foundation

/// Talks to the kernel with SIOCGIFFLAGS / SIOCSIFFLAGS.
///
/// We deliberately do not shell out to `ifconfig`: a subprocess per event is
/// both slow and fragile to parse, and the flap loop can fire many times a
/// second while AirDrop is opening.
public final class SystemInterfaceController: InterfaceController {
    public let name: String
    private var fd: Int32 = -1
    private let upMask: Int16

    public init(name: String = "awdl0") {
        self.name = name
        self.upMask = Int16(hawdl_iff_up_mask())
    }

    deinit {
        if fd >= 0 { _ = close(fd) }
    }

    /// A control socket, opened lazily and kept for the process lifetime.
    private func controlSocket() throws -> Int32 {
        if fd >= 0 { return fd }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else {
            throw InterfaceError.systemCall(name: "socket", code: errno)
        }
        fd = s
        return s
    }

    private func readFlags() throws -> Int16 {
        let s = try controlSocket()
        var flags: Int16 = 0
        let rc = name.withCString { cname in
            hawdl_if_get_flags(s, cname, &flags)
        }
        guard rc == 0 else {
            throw Self.mapErrno(errno, call: "SIOCGIFFLAGS")
        }
        return flags
    }

    public func isUp() throws -> Bool {
        (try readFlags() & upMask) != 0
    }

    public func setUp(_ up: Bool) throws {
        let current = try readFlags()
        let target = up ? (current | upMask) : (current & ~upMask)
        if target == current { return }

        let s = try controlSocket()
        let rc = name.withCString { cname in
            hawdl_if_set_flags(s, cname, target)
        }
        guard rc == 0 else {
            throw Self.mapErrno(errno, call: "SIOCSIFFLAGS")
        }
    }

    private static func mapErrno(_ code: Int32, call: String) -> InterfaceError {
        switch code {
        case ENXIO, ENODEV, EADDRNOTAVAIL, ENOENT:
            return .notFound
        case EPERM, EACCES:
            return .permissionDenied
        default:
            return .systemCall(name: call, code: code)
        }
    }
}
