import Foundation

/// What the user wants: keep awdl0 down, or leave it alone.
public enum DesiredState: String, Codable, Equatable, Sendable {
    case hold
    case release
}

/// What awdl0 is actually doing right now.
public enum InterfaceState: String, Codable, Equatable, Sendable {
    /// IFF_UP is set.
    case up
    /// IFF_UP is clear.
    case down
    /// The interface does not exist on this machine (VM, stripped hardware, ...).
    case unavailable
    /// The interface exists but we could not read its flags.
    case unknown
}

/// Requests a client may send to the daemon.
public enum Command: String, Codable, Equatable, Sendable {
    case status
    case hold
    case release
    /// Keep the connection open and receive a status push on every change.
    case subscribe
}

public struct Request: Codable, Equatable, Sendable {
    public var cmd: Command

    public init(cmd: Command) {
        self.cmd = cmd
    }
}

/// The daemon's reply to every request, and the payload pushed to subscribers.
public struct StatusMessage: Codable, Equatable, Sendable {
    public var desired: DesiredState
    public var actual: InterfaceState
    public var available: Bool
    public var flapCount: Int
    public var lastFlapAt: Date?
    public var daemonVersion: String

    /// Derives `available` from `actual` so the two can never disagree.
    public init(
        desired: DesiredState,
        actual: InterfaceState,
        flapCount: Int = 0,
        lastFlapAt: Date? = nil,
        daemonVersion: String = hawdlVersion
    ) {
        self.desired = desired
        self.actual = actual
        self.available = (actual != .unavailable)
        self.flapCount = flapCount
        self.lastFlapAt = lastFlapAt
        self.daemonVersion = daemonVersion
    }
}

/// Anything that went wrong while framing or parsing an IPC message.
public enum IPCError: Error, Equatable, CustomStringConvertible {
    case lineTooLong(limit: Int)
    case malformedMessage(String)

    public var description: String {
        switch self {
        case .lineTooLong(let limit):
            return "IPC line exceeded \(limit) bytes without a newline"
        case .malformedMessage(let detail):
            return "malformed IPC message: \(detail)"
        }
    }
}

/// Newline-delimited JSON codec shared by the daemon and every client.
///
/// Both sides must use the same date strategy or `lastFlapAt` round-trips
/// wrong, so the encoder and decoder live here together.
public enum HawdlCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `value` as a single JSON object terminated by "\n".
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Decodes one line produced by `encodeLine` (the trailing "\n" is optional).
    public static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        var payload = data
        while payload.last == 0x0A || payload.last == 0x0D {
            payload.removeLast()
        }
        guard !payload.isEmpty else {
            throw IPCError.malformedMessage("empty line")
        }
        do {
            return try makeDecoder().decode(type, from: payload)
        } catch {
            throw IPCError.malformedMessage("\(error)")
        }
    }
}
