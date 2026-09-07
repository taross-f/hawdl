import Foundation

/// Everything the daemon must do in response to one trigger.
public struct Outcome: Equatable, Sendable {
    /// What the state machine decided.
    public var action: Action
    /// Non-nil when the caller must re-trigger `.backoffExpired` after this
    /// many seconds.
    public var scheduleRetryAfter: TimeInterval?
    /// True when the status differs from the last one the engine reported,
    /// i.e. when subscribers should be pushed to.
    public var statusChanged: Bool
    public var status: StatusMessage
    /// Set when the interface operation failed. Logged, not fatal.
    public var error: String?
}

/// Ties the state machine, the flap controller and an `InterfaceController`
/// together. Owns no timers and no sockets: the daemon drives it with triggers
/// and acts on the returned `Outcome`, which keeps the whole thing testable
/// with a fake clock and a fake interface.
public final class HoldEngine {
    public struct Config: Equatable, Sendable {
        public var interfaceName: String
        public var flapWindow: TimeInterval
        public var flapThreshold: Int
        public var backoffBase: TimeInterval
        public var backoffCap: TimeInterval
        public var reconcileInterval: TimeInterval

        public init(
            interfaceName: String = "awdl0",
            flapWindow: TimeInterval = 10,
            flapThreshold: Int = 5,
            backoffBase: TimeInterval = 1,
            backoffCap: TimeInterval = 30,
            reconcileInterval: TimeInterval = 30
        ) {
            self.interfaceName = interfaceName
            self.flapWindow = flapWindow
            self.flapThreshold = flapThreshold
            self.backoffBase = backoffBase
            self.backoffCap = backoffCap
            self.reconcileInterval = reconcileInterval
        }

        public static let `default` = Config()
    }

    private let controller: InterfaceController
    private let now: () -> Date
    public let config: Config

    private var flaps: FlapController
    private var lastObserved: InterfaceState = .unknown
    private var lastReported: StatusMessage?

    public private(set) var desired: DesiredState
    public private(set) var observed: InterfaceState = .unknown
    public private(set) var flapCount: Int = 0
    public private(set) var lastFlapAt: Date?
    public private(set) var backoffPending = false

    public init(
        controller: InterfaceController,
        config: Config = .default,
        desired: DesiredState = .release,
        now: @escaping () -> Date = Date.init
    ) {
        self.controller = controller
        self.config = config
        self.desired = desired
        self.now = now
        self.flaps = FlapController(
            window: config.flapWindow,
            threshold: config.flapThreshold,
            base: config.backoffBase,
            cap: config.backoffCap
        )
    }

    /// Current status without touching the interface.
    public func status() -> StatusMessage {
        StatusMessage(
            desired: desired,
            actual: observed,
            flapCount: flapCount,
            lastFlapAt: lastFlapAt,
            daemonVersion: hawdlVersion
        )
    }

    @discardableResult
    public func setDesired(_ newValue: DesiredState) -> Outcome {
        // Re-asserting the state we are already in must not reset the backoff:
        // the control socket is world-writable, so a client spamming `hold`
        // would otherwise be a way to make the daemon fight the OS flat out.
        guard newValue != desired else { return handle(.enforce) }

        desired = newValue
        // A deliberate switch is not a flap storm; forget the old one so the
        // user's next hold reacts immediately.
        flaps.reset()
        backoffPending = false
        return handle(.desiredChanged)
    }

    public func handle(_ trigger: Trigger) -> Outcome {
        let state = readState()
        let transitionedToUp = (state == .up && lastObserved != .up)
        lastObserved = state
        observed = state

        var retryAfter: TimeInterval?

        // Only an unsolicited up counts as a flap. Bringing the interface down
        // because the user just asked us to is not the OS fighting back.
        if desired == .hold,
           state == .up,
           transitionedToUp,
           trigger == .interfaceEvent || trigger == .reconcileTick {
            flapCount += 1
            lastFlapAt = now()
            if let delay = flaps.record(at: now()) {
                backoffPending = true
                retryAfter = delay
            }
        }

        if trigger == .backoffExpired {
            backoffPending = false
        }

        let action = StateMachine.action(
            for: .init(
                desired: desired,
                observed: state,
                trigger: trigger,
                backoffPending: backoffPending
            )
        )

        var error: String?
        switch action {
        case .none:
            break
        case .bringDown:
            error = apply(up: false)
        case .bringUp:
            error = apply(up: true)
        }

        let snapshot = status()
        let changed = (lastReported != snapshot)
        lastReported = snapshot

        return Outcome(
            action: action,
            scheduleRetryAfter: retryAfter,
            statusChanged: changed,
            status: snapshot,
            error: error
        )
    }

    private func apply(up: Bool) -> String? {
        do {
            try controller.setUp(up)
            // Record what we just asked for, so the next unsolicited change is
            // seen as a transition rather than as more of the same.
            lastObserved = up ? .up : .down
            observed = lastObserved
            return nil
        } catch let error as InterfaceError {
            if error == .notFound {
                lastObserved = .unavailable
                observed = .unavailable
            }
            return error.description
        } catch {
            return "\(error)"
        }
    }

    private func readState() -> InterfaceState {
        do {
            return try controller.isUp() ? .up : .down
        } catch InterfaceError.notFound {
            return .unavailable
        } catch {
            return .unknown
        }
    }
}
