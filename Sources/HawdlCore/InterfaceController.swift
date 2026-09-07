import Darwin
import Foundation

public enum InterfaceError: Error, Equatable, CustomStringConvertible {
    /// The interface does not exist on this machine.
    case notFound
    /// Not running as root.
    case permissionDenied
    case systemCall(name: String, code: Int32)

    public var description: String {
        switch self {
        case .notFound:
            return "interface not found"
        case .permissionDenied:
            return "permission denied (hawdld must run as root)"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// The one privileged operation the daemon needs, behind a protocol so the
/// engine can be tested without root and without a real awdl0.
public protocol InterfaceController: AnyObject {
    var name: String { get }
    func isUp() throws -> Bool
    func setUp(_ up: Bool) throws
}

/// In-memory stand-in used by the tests and by `hawdld --dry-run`.
public final class FakeInterfaceController: InterfaceController, @unchecked Sendable {
    public let name: String

    /// Current state, writable so a test can simulate the OS re-raising awdl0.
    public var state: InterfaceState

    /// Thrown by the next call to `isUp()`, then cleared.
    public var isUpError: InterfaceError?

    /// Thrown by the next call to `setUp(_:)`, then cleared.
    public var setUpError: InterfaceError?

    public private(set) var setUpCallCount = 0
    public private(set) var bringDownCallCount = 0
    public private(set) var bringUpCallCount = 0

    /// Called after every successful `setUp`, so a test can model the OS
    /// immediately putting the interface back.
    public var afterSetUp: ((Bool) -> Void)?

    public init(name: String = "awdl0", state: InterfaceState = .up) {
        self.name = name
        self.state = state
    }

    public func isUp() throws -> Bool {
        if let error = isUpError {
            isUpError = nil
            throw error
        }
        switch state {
        case .up: return true
        case .down: return false
        case .unavailable: throw InterfaceError.notFound
        case .unknown: throw InterfaceError.systemCall(name: "SIOCGIFFLAGS", code: EINVAL)
        }
    }

    public func setUp(_ up: Bool) throws {
        if let error = setUpError {
            setUpError = nil
            throw error
        }
        if state == .unavailable {
            throw InterfaceError.notFound
        }
        setUpCallCount += 1
        if up {
            bringUpCallCount += 1
        } else {
            bringDownCallCount += 1
        }
        state = up ? .up : .down
        afterSetUp?(up)
    }
}
