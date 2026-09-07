import Darwin
import Foundation
import HawdlCore

let options: DaemonOptions
do {
    options = try DaemonOptions.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("hawdld: \(error)\n\n\(DaemonOptions.usage)\n".utf8))
    exit(2)
}

if options.showHelp {
    print(DaemonOptions.usage)
    exit(0)
}

if options.showVersion {
    print("hawdld \(hawdlVersion)")
    exit(0)
}

if !options.dryRun && geteuid() != 0 {
    FileHandle.standardError.write(Data("""
    hawdld: must run as root to change \(options.interface) flags.
    Start it the intended way:  sudo brew services start hawdl
    Or try the logic without root:  hawdld --dry-run --socket /tmp/hawdl.sock --state /tmp/hawdl-state.json

    """.utf8))
    exit(1)
}

let daemon = Daemon(options: options)
do {
    try daemon.run()
} catch {
    FileHandle.standardError.write(Data("hawdld: \(error)\n".utf8))
    exit(1)
}
