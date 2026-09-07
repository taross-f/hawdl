import Foundation

public enum HawdlPaths {
    public static let socket = "/var/run/hawdl.sock"
    public static let supportDirectory = "/Library/Application Support/hawdl"
    public static let stateFile = supportDirectory + "/state.json"
    public static let lockFile = "/var/run/hawdld.lock"
    public static let defaultInterface = "awdl0"
}
