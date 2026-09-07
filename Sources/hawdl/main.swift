import Darwin
import Foundation
import HawdlCore

let usage = """
usage: hawdl <command> [options]

commands:
  status     print the current state and exit
  hold       keep \(HawdlPaths.defaultInterface) down until released
  release    stop holding and bring \(HawdlPaths.defaultInterface) back up
  watch      stream state changes until interrupted

options:
  --socket <path>   control socket (default: \(HawdlPaths.socket))
  --json            print raw protocol JSON instead of prose
  --version         print the version and exit
  --help            print this message

exit codes: 0 ok, 1 error, 2 usage, 3 hawdld unreachable
"""

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
    case unreachable = 3
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("hawdl: \(message)\n".utf8))
    exit(code.rawValue)
}

func describe(_ status: StatusMessage) -> String {
    guard status.available else {
        return "AWDL: unavailable (no \(HawdlPaths.defaultInterface) on this machine)"
    }

    let state: String
    switch (status.desired, status.actual) {
    case (.hold, .down): state = "held down"
    case (.hold, .up): state = "held down (backing off; currently up)"
    case (.release, .up): state = "released (up)"
    case (.release, .down): state = "released (down)"
    default: state = "\(status.desired.rawValue) / \(status.actual.rawValue)"
    }

    var line = "AWDL: \(state)  blocked=\(status.flapCount)"
    if let last = status.lastFlapAt {
        line += "  last=\(ISO8601DateFormatter().string(from: last))"
    }
    line += "  daemon=\(status.daemonVersion)"
    return line
}

func emit(_ status: StatusMessage, json: Bool) {
    if json, let data = try? HawdlCodec.makeEncoder().encode(status),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print(describe(status))
    }
}

// MARK: - Argument parsing

var socketPath = HawdlPaths.socket
var json = false
var command: Command?
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0

while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(ExitCode.ok.rawValue)
    case "--version", "-v":
        print("hawdl \(hawdlVersion)")
        exit(ExitCode.ok.rawValue)
    case "--json":
        json = true
    case "--socket":
        index += 1
        guard index < arguments.count else { fail("--socket requires a value", .usage) }
        socketPath = arguments[index]
    case "status", "hold", "release":
        guard command == nil else { fail("more than one command given", .usage) }
        command = Command(rawValue: argument)
    case "watch":
        guard command == nil else { fail("more than one command given", .usage) }
        command = .subscribe
    default:
        fail("unknown argument: \(argument)\n\n\(usage)", .usage)
    }
    index += 1
}

guard let resolvedCommand = command else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(ExitCode.usage.rawValue)
}

// MARK: - Run

let client = IPCClient(socketPath: socketPath)

do {
    try client.connect(readTimeout: resolvedCommand == .subscribe ? 0 : 5)
    try client.send(Request(cmd: resolvedCommand))

    if resolvedCommand == .subscribe {
        // Stream until the daemon goes away or the user interrupts us.
        while true {
            do {
                emit(try client.receive(), json: json)
            } catch IPCClient.ClientError.timedOut {
                continue
            }
        }
    } else {
        emit(try client.receive(), json: json)
    }
} catch let error as IPCClient.ClientError {
    switch error {
    case .daemonNotRunning:
        fail("""
        \(error)
        Start it with:  sudo brew services start hawdl
        """, .unreachable)
    case .connectionClosed where resolvedCommand == .subscribe:
        fail("hawdld closed the connection", .unreachable)
    default:
        fail("\(error)", .failure)
    }
} catch {
    fail("\(error)", .failure)
}

client.close()
exit(ExitCode.ok.rawValue)
