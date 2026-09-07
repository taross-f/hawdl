import AppKit
import Combine
import Foundation
import HawdlCore
import ServiceManagement

/// Owns the connection to hawdld and republishes its state on the main thread.
///
/// The daemon is allowed to be absent: that is the normal state right after
/// `brew install`, before `sudo brew services start hawdl`. In that case the
/// app sits in a reconnect loop and tells the user what to run, rather than
/// failing.
final class MenuModel: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case connected
        case daemonMissing
        case failed(String)
    }

    @Published private(set) var status: StatusMessage?
    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var launchAtLogin: Bool = false

    private let socketPath: String
    private let reconnectDelay: TimeInterval
    /// The subscription loop blocks forever, so one-shot commands need a queue
    /// of their own or they would queue up behind it and never run.
    private let subscriptionQueue = DispatchQueue(label: "com.github.taross-f.hawdl.bar.subscribe")
    private let commandQueue = DispatchQueue(label: "com.github.taross-f.hawdl.bar.command")
    private let stopFlag = StopFlag()
    private var started = false

    init(socketPath: String = HawdlPaths.socket, reconnectDelay: TimeInterval = 3, autoStart: Bool = true) {
        self.socketPath = socketPath
        self.reconnectDelay = reconnectDelay
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if autoStart { start() }
    }

    /// Cancellation flag shared with the worker thread.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    // MARK: - Presentation

    var symbolName: String {
        guard connection == .connected, let status, status.available else {
            return "wifi.exclamationmark"
        }
        return status.desired == .hold ? "wifi.slash" : "wifi"
    }

    var stateText: String {
        switch connection {
        case .connecting:
            return "AWDL: 接続中…"
        case .daemonMissing:
            return "AWDL: hawdld が未起動"
        case .failed(let detail):
            return "AWDL: エラー (\(detail))"
        case .connected:
            guard let status else { return "AWDL: 状態不明" }
            guard status.available else { return "AWDL: awdl0 がありません" }
            let label = (status.desired == .hold) ? "停止中" : "動作中"
            return "AWDL: \(label) (\(status.flapCount) 回ブロック)"
        }
    }

    var daemonText: String {
        switch connection {
        case .connected:
            return "hawdld: 接続済み (v\(status?.daemonVersion ?? hawdlVersion))"
        case .connecting:
            return "hawdld: 接続中…"
        case .daemonMissing:
            return "hawdld: 未起動"
        case .failed(let detail):
            return "hawdld: \(detail)"
        }
    }

    var needsDaemonHelp: Bool {
        if case .connected = connection { return false }
        return true
    }

    var canToggle: Bool {
        connection == .connected && (status?.available ?? false)
    }

    var toggleTitle: String {
        (status?.desired == .hold) ? "AWDL を再開" : "AWDL を停止"
    }

    // MARK: - Actions

    func toggle() {
        send((status?.desired == .hold) ? .release : .hold)
    }

    func copyStartCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.startCommand, forType: .string)
    }

    static let startCommand = "sudo brew services start hawdl"

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("hawdl: could not update the login item: %@", "\(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func quit() {
        stopFlag.set()
        NSApplication.shared.terminate(nil)
    }

    /// Fire-and-forget on a throwaway connection, so a hold/release never
    /// blocks the UI or disturbs the long-lived subscription.
    private func send(_ command: Command) {
        let path = socketPath
        commandQueue.async {
            do {
                _ = try IPCClient.request(command, socketPath: path)
            } catch {
                NSLog("hawdl: %@ failed: %@", command.rawValue, "\(error)")
            }
        }
    }

    // MARK: - Subscription

    /// Idempotent: safe to call from `init` and from a view lifecycle hook.
    func start() {
        guard !started else { return }
        started = true
        let path = socketPath
        let delay = reconnectDelay
        let stop = stopFlag
        subscriptionQueue.async { [weak self] in
            self?.subscriptionLoop(socketPath: path, reconnectDelay: delay, stop: stop)
        }
    }

    private func subscriptionLoop(socketPath: String, reconnectDelay: TimeInterval, stop: StopFlag) {
        while !stop.isSet {
            let client = IPCClient(socketPath: socketPath)
            do {
                // A one second receive timeout lets the loop notice `stop`
                // without having to close the descriptor from another thread.
                try client.connect(readTimeout: 1)
                try client.send(Request(cmd: .subscribe))
                publish(connection: .connected)

                while !stop.isSet {
                    do {
                        publish(status: try client.receive(), connection: .connected)
                    } catch IPCClient.ClientError.timedOut {
                        continue
                    }
                }
            } catch let error as IPCClient.ClientError {
                switch error {
                case .daemonNotRunning, .connectionClosed:
                    publish(connection: .daemonMissing)
                default:
                    publish(connection: .failed(error.description))
                }
            } catch {
                publish(connection: .failed("\(error)"))
            }

            client.close()
            if stop.isSet { return }
            Thread.sleep(forTimeInterval: reconnectDelay)
        }
    }

    private func publish(status newStatus: StatusMessage? = nil, connection newConnection: Connection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let newStatus { self.status = newStatus }
            if self.connection != newConnection { self.connection = newConnection }
        }
    }
}
