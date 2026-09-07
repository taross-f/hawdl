import XCTest
@testable import HawdlCore

final class ProtocolTests: XCTestCase {
    // Whole seconds: the wire format is second-resolution ISO 8601.
    private let flapDate = Date(timeIntervalSince1970: 1_757_240_625)

    func testStatusMessageRoundTrips() throws {
        let original = StatusMessage(
            desired: .hold,
            actual: .down,
            flapCount: 12,
            lastFlapAt: flapDate,
            daemonVersion: "0.1.0"
        )
        let line = try HawdlCodec.encodeLine(original)
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))

        let decoded = try HawdlCodec.decodeLine(StatusMessage.self, from: line)
        XCTAssertEqual(decoded, original)
    }

    func testStatusMessageRoundTripsWithoutAFlapTimestamp() throws {
        let original = StatusMessage(desired: .release, actual: .up)
        let decoded = try HawdlCodec.decodeLine(
            StatusMessage.self,
            from: try HawdlCodec.encodeLine(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.lastFlapAt)
    }

    func testEveryRequestRoundTrips() throws {
        for command in [Command.status, .hold, .release, .subscribe] {
            let decoded = try HawdlCodec.decodeLine(
                Request.self,
                from: try HawdlCodec.encodeLine(Request(cmd: command))
            )
            XCTAssertEqual(decoded.cmd, command)
        }
    }

    func testEveryStateCombinationRoundTrips() throws {
        for desired in [DesiredState.hold, .release] {
            for actual in [InterfaceState.up, .down, .unavailable, .unknown] {
                let original = StatusMessage(
                    desired: desired,
                    actual: actual,
                    flapCount: 3,
                    lastFlapAt: flapDate
                )
                let decoded = try HawdlCodec.decodeLine(
                    StatusMessage.self,
                    from: try HawdlCodec.encodeLine(original)
                )
                XCTAssertEqual(decoded, original, "\(desired) / \(actual)")
            }
        }
    }

    /// The wire format is documented in the README; keep it honest.
    func testWireFormatMatchesTheDocumentedShape() throws {
        let status = StatusMessage(
            desired: .hold,
            actual: .down,
            flapCount: 12,
            lastFlapAt: flapDate,
            daemonVersion: "0.1.0"
        )
        let text = String(decoding: try HawdlCodec.encodeLine(status), as: UTF8.self)

        XCTAssertTrue(text.contains("\"desired\":\"hold\""), text)
        XCTAssertTrue(text.contains("\"actual\":\"down\""), text)
        XCTAssertTrue(text.contains("\"available\":true"), text)
        XCTAssertTrue(text.contains("\"flapCount\":12"), text)
        XCTAssertTrue(text.contains("\"daemonVersion\":\"0.1.0\""), text)
        XCTAssertTrue(text.contains("\"lastFlapAt\":\"2025-09-07T10:23:45Z\""), text)
        XCTAssertTrue(text.hasSuffix("}\n"), text)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "one message must be exactly one line")
    }

    /// Swift's synthesized encoder omits nil optionals rather than writing
    /// null, and the README documents the wire format, so pin it.
    func testMissingFlapTimestampIsOmittedNotNull() throws {
        let text = String(
            decoding: try HawdlCodec.encodeLine(StatusMessage(desired: .release, actual: .up)),
            as: UTF8.self
        )
        XCTAssertFalse(text.contains("lastFlapAt"), text)
        XCTAssertFalse(text.contains("null"), text)
    }

    func testRequestWireFormat() throws {
        let text = String(decoding: try HawdlCodec.encodeLine(Request(cmd: .subscribe)), as: UTF8.self)
        XCTAssertEqual(text, "{\"cmd\":\"subscribe\"}\n")
    }

    func testAvailableAlwaysAgreesWithActual() {
        XCTAssertFalse(StatusMessage(desired: .hold, actual: .unavailable).available)
        for actual in [InterfaceState.up, .down, .unknown] {
            XCTAssertTrue(StatusMessage(desired: .hold, actual: actual).available)
        }
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        XCTAssertThrowsError(try HawdlCodec.decodeLine(Request.self, from: Data("not json\n".utf8)))
        XCTAssertThrowsError(try HawdlCodec.decodeLine(Request.self, from: Data("\n".utf8)))
        XCTAssertThrowsError(try HawdlCodec.decodeLine(Request.self, from: Data("{}\n".utf8)))
        XCTAssertThrowsError(
            try HawdlCodec.decodeLine(Request.self, from: Data("{\"cmd\":\"reboot\"}\n".utf8))
        )
    }

    func testTrailingCarriageReturnIsTolerated() throws {
        let decoded = try HawdlCodec.decodeLine(Request.self, from: Data("{\"cmd\":\"hold\"}\r\n".utf8))
        XCTAssertEqual(decoded.cmd, .hold)
    }
}
