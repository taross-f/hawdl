import Foundation

/// Why we are re-evaluating the world.
public enum Trigger: String, Equatable, Sendable, CaseIterable {
    /// Take stock and enforce the current desired state, without treating
    /// anything as a flap. Used at startup, and when a client re-asserts the
    /// state the daemon is already in.
    case enforce
    /// A PF_ROUTE RTM_IFINFO message arrived.
    case interfaceEvent
    /// The periodic safety-net timer fired.
    case reconcileTick
    /// A backoff timer expired and we may try again.
    case backoffExpired
    /// A client asked for hold or release.
    case desiredChanged
    /// SIGTERM / SIGINT: hand the interface back before we exit.
    case shutdown
}

/// What to do to the interface.
public enum Action: String, Equatable, Sendable, CaseIterable {
    case none
    case bringDown
    case bringUp
}

/// The `desired x actual x trigger -> action` table.
///
/// Deliberately a pure function with no clock, no I/O and no stored state, so
/// the whole table can be enumerated in tests.
public enum StateMachine {
    public struct Input: Equatable, Sendable {
        public var desired: DesiredState
        public var observed: InterfaceState
        public var trigger: Trigger
        /// True while a backoff retry is already scheduled.
        public var backoffPending: Bool

        public init(
            desired: DesiredState,
            observed: InterfaceState,
            trigger: Trigger,
            backoffPending: Bool = false
        ) {
            self.desired = desired
            self.observed = observed
            self.trigger = trigger
            self.backoffPending = backoffPending
        }
    }

    public static func action(for input: Input) -> Action {
        // Nothing to do if awdl0 is not there, or if we could not read it.
        switch input.observed {
        case .unavailable, .unknown:
            return .none
        case .up, .down:
            break
        }

        // Leaving the machine must never leave AirDrop broken, whatever the
        // desired state was.
        if input.trigger == .shutdown {
            return input.observed == .down ? .bringUp : .none
        }

        switch input.desired {
        case .release:
            // Releasing is a one-shot hand-back: we put the interface back up
            // at the moment the user releases and then stop touching it. We
            // deliberately do not re-raise it on every tick, because awdl0
            // being down while Wi-Fi is off is normal and not ours to fix.
            if input.trigger == .desiredChanged {
                return input.observed == .down ? .bringUp : .none
            }
            return .none

        case .hold:
            guard input.observed == .up else { return .none }
            // While a retry is pending we stay out of the way, unless this is
            // the retry itself or an explicit user request.
            if input.backoffPending,
               input.trigger != .backoffExpired,
               input.trigger != .desiredChanged {
                return .none
            }
            return .bringDown
        }
    }
}
