import Foundation
import HawdlCore

struct DaemonOptions {
    var interface = HawdlPaths.defaultInterface
    var socketPath = HawdlPaths.socket
    var statePath = HawdlPaths.stateFile
    var lockPath: String? = HawdlPaths.lockFile
    var reconcileInterval: TimeInterval = 30
    /// Use a fake interface instead of touching the kernel, so the daemon can
    /// be exercised end to end without root.
    var dryRun = false
    var verbose = false
    var showVersion = false
    var showHelp = false

    static let usage = """
    usage: hawdld [options]

      --interface <name>     interface to hold down (default: \(HawdlPaths.defaultInterface))
      --socket <path>        control socket (default: \(HawdlPaths.socket))
      --state <path>         desired-state file (default: \(HawdlPaths.stateFile))
      --no-lock              skip the single-instance lock file
      --reconcile <seconds>  safety-net reconcile interval (default: 30)
      --dry-run              use a simulated interface; no root required
      --verbose              log every trigger
      --version              print the version and exit
      --help                 print this message

    hawdld normally runs as a LaunchDaemon. See `brew services start hawdl`.
    """

    enum ParseError: Error, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case badValue(String, String)

        var description: String {
            switch self {
            case .unknownOption(let option): return "unknown option: \(option)"
            case .missingValue(let option): return "\(option) requires a value"
            case .badValue(let option, let value): return "invalid value for \(option): \(value)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> DaemonOptions {
        var options = DaemonOptions()
        var index = 0
        let args = Array(arguments.dropFirst())

        func value(for option: String) throws -> String {
            index += 1
            guard index < args.count else { throw ParseError.missingValue(option) }
            return args[index]
        }

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--interface": options.interface = try value(for: argument)
            case "--socket": options.socketPath = try value(for: argument)
            case "--state": options.statePath = try value(for: argument)
            case "--no-lock": options.lockPath = nil
            case "--reconcile":
                let raw = try value(for: argument)
                guard let seconds = TimeInterval(raw), seconds > 0 else {
                    throw ParseError.badValue(argument, raw)
                }
                options.reconcileInterval = seconds
            case "--dry-run": options.dryRun = true
            case "--verbose": options.verbose = true
            case "--version", "-v": options.showVersion = true
            case "--help", "-h": options.showHelp = true
            default: throw ParseError.unknownOption(argument)
            }
            index += 1
        }

        // A dry run is meant to be startable by a normal user, so keep it away
        // from the root-owned defaults unless they were asked for explicitly.
        if options.dryRun, options.lockPath == HawdlPaths.lockFile {
            options.lockPath = nil
        }

        return options
    }
}
