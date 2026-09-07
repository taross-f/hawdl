import Foundation

/// The bit of state that has to survive a reboot: what the user asked for.
public struct PersistedState: Codable, Equatable, Sendable {
    public var desired: DesiredState
    public var updatedAt: Date

    public init(desired: DesiredState, updatedAt: Date = Date()) {
        self.desired = desired
        self.updatedAt = updatedAt
    }
}

/// Reads and writes `/Library/Application Support/hawdl/state.json`.
///
/// Writes are atomic (write to a sibling temporary, then rename), so a crash
/// mid-write cannot leave a half-written document that brings the daemon back
/// up in the wrong mode.
public struct StateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(path: String = HawdlPaths.stateFile) {
        self.init(url: URL(fileURLWithPath: path))
    }

    /// Returns nil when the file is missing or unreadable. A corrupt state file
    /// is not worth refusing to start over: we fall back to the default.
    public func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? HawdlCodec.makeDecoder().decode(PersistedState.self, from: data)
    }

    public func save(_ state: PersistedState) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }

        let data = try HawdlCodec.makeEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }
}
