import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// A stream socket gives no message boundaries, so both the daemon and the
/// clients need this. Kept pure and value-typed so it can be unit tested.
public struct LineFramer {
    public let maxLineBytes: Int
    private var buffer = Data()

    public init(maxLineBytes: Int = 64 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    public var pendingByteCount: Int { buffer.count }

    /// Appends `data` and returns every complete line it produced, without the
    /// trailing newline. Empty lines are dropped.
    ///
    /// - Throws: `IPCError.lineTooLong` when a peer sends `maxLineBytes` without
    ///   a newline, which is the point at which we stop buffering and hang up.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)

        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<index]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            buffer.removeSubrange(buffer.startIndex...index)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }

        if buffer.count > maxLineBytes {
            buffer.removeAll()
            throw IPCError.lineTooLong(limit: maxLineBytes)
        }

        return lines
    }
}
