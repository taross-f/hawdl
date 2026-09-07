import Darwin
import Foundation
import HawdlCore

final class Daemon {
    private let options: DaemonOptions
    private let queue = DispatchQueue(label: "com.github.taross-f.hawdl.daemon")
    private let engine: HoldEngine
    private let store: StateStore
    private let controller: InterfaceController

    private var server: IPCServer?
    private var routeMonitor: RouteMonitor?
    private var reconcileTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1
    private var shuttingDown = false

    init(options: DaemonOptions) {
        self.options = options

        let controller: InterfaceController
        if options.dryRun {
            controller = FakeInterfaceController(name: options.interface, state: .up)
        } else {
            controller = SystemInterfaceController(name: options.interface)
        }
        self.controller = controller

        let store = StateStore(path: options.statePath)
        self.store = store

        let restored = store.load()
        self.engine = HoldEngine(
            controller: controller,
            config: HoldEngine.Config(
                interfaceName: options.interface,
                reconcileInterval: options.reconcileInterval
            ),
            desired: restored?.desired ?? .release
        )
        if let restored {
            log("restored desired state: \(restored.desired.rawValue)")
        }
    }

    // MARK: - Lifecycle

    func run() throws {
        // Writes to a socket whose peer vanished must not kill the daemon.
        _ = signal(SIGPIPE, SIG_IGN)

        try acquireLock()

        // All wiring happens on the same serial queue the handlers run on, so
        // nothing is half-initialised when the first event lands.
        try queue.sync {
            try startServer()
            startRouteMonitor()
            startReconcileTimer()
            installSignalHandlers()
            apply(engine.handle(.enforce))
        }

        log("hawdld \(hawdlVersion) watching \(options.interface) on \(options.socketPath)"
            + (options.dryRun ? " (dry run)" : ""))
        dispatchMain()
    }

    /// Puts the interface back before exiting: a dead daemon must never leave
    /// AirDrop broken.
    private func shutdown(signalName: String) {
        guard !shuttingDown else { return }
        shuttingDown = true
        log("received \(signalName), releasing \(options.interface)")

        let outcome = engine.handle(.shutdown)
        if let error = outcome.error {
            log("failed to bring \(options.interface) back up: \(error)")
        }

        retryTimer?.cancel()
        reconcileTimer?.cancel()
        routeMonitor?.stop()
        server?.stop()
        releaseLock()
        exit(0)
    }

    // MARK: - Wiring

    private func acquireLock() throws {
        guard let path = options.lockPath else { return }
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw DaemonError.startupFailed("cannot open lock file \(path): \(errnoText())")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw DaemonError.startupFailed("another hawdld is already running (lock: \(path))")
        }
        lockFD = fd
    }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        _ = close(lockFD)
        lockFD = -1
    }

    private func startServer() throws {
        let server = IPCServer(
            socketPath: options.socketPath,
            queue: queue,
            log: { [weak self] message in self?.log(message) },
            handler: { [weak self] command in
                self?.handle(command) ?? StatusMessage(desired: .release, actual: .unknown)
            }
        )
        do {
            try server.start()
        } catch {
            throw DaemonError.startupFailed("cannot listen on \(options.socketPath): \(error)")
        }
        self.server = server
    }

    private func startRouteMonitor() {
        let monitor = RouteMonitor(interfaceName: options.interface, queue: queue)
        do {
            try monitor.start { [weak self] in
                self?.trigger(.interfaceEvent)
            }
            routeMonitor = monitor
        } catch {
            // Not fatal: the reconcile timer still catches everything, just
            // with up to `reconcileInterval` of latency.
            log("PF_ROUTE monitoring unavailable, falling back to polling: \(error)")
        }
    }

    private func startReconcileTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + options.reconcileInterval,
            repeating: options.reconcileInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.trigger(.reconcileTick)
        }
        timer.resume()
        reconcileTimer = timer
    }

    private func installSignalHandlers() {
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown(signalName: name) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Event handling

    private func trigger(_ event: Trigger) {
        guard !shuttingDown else { return }
        if options.verbose { log("trigger: \(event.rawValue)") }
        apply(engine.handle(event))
    }

    private func handle(_ command: Command) -> StatusMessage {
        switch command {
        case .status, .subscribe:
            return engine.status()
        case .hold, .release:
            let desired: DesiredState = (command == .hold) ? .hold : .release
            let outcome = engine.setDesired(desired)
            persist(desired)
            log("desired state -> \(desired.rawValue)")
            apply(outcome)
            return outcome.status
        }
    }

    private func apply(_ outcome: Outcome) {
        if let error = outcome.error {
            log("interface operation failed: \(error)")
        }
        if outcome.action != .none, options.verbose {
            log("action: \(outcome.action.rawValue) -> \(outcome.status.actual.rawValue)")
        }
        if let delay = outcome.scheduleRetryAfter {
            log("\(options.interface) is flapping; backing off \(String(format: "%.0f", delay))s")
            scheduleRetry(after: delay)
        }
        if outcome.statusChanged {
            server?.broadcast(outcome.status)
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.retryTimer = nil
            self?.trigger(.backoffExpired)
        }
        timer.resume()
        retryTimer = timer
    }

    private func persist(_ desired: DesiredState) {
        do {
            try store.save(PersistedState(desired: desired))
        } catch {
            log("could not persist desired state to \(options.statePath): \(error)")
        }
    }

    // MARK: - Logging

    private let timestamps = ISO8601DateFormatter()

    private func log(_ message: String) {
        let stamp = timestamps.string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case startupFailed(String)

    var description: String {
        switch self {
        case .startupFailed(let detail): return detail
        }
    }
}
