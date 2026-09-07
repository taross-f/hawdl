import XCTest
@testable import HawdlCore

final class LineFramerTests: XCTestCase {
    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testSplitsOnNewlines() throws {
        var framer = LineFramer()
        XCTAssertEqual(strings(try framer.append(Data("a\nb\nc\n".utf8))), ["a", "b", "c"])
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testHoldsBackAPartialLine() throws {
        var framer = LineFramer()
        XCTAssertEqual(strings(try framer.append(Data("{\"cmd\":".utf8))), [])
        XCTAssertGreaterThan(framer.pendingByteCount, 0)
        XCTAssertEqual(
            strings(try framer.append(Data("\"status\"}\n".utf8))),
            ["{\"cmd\":\"status\"}"]
        )
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testReassemblesAcrossArbitraryChunkBoundaries() throws {
        var framer = LineFramer()
        let payload = "{\"cmd\":\"hold\"}\n{\"cmd\":\"release\"}\n"
        var collected: [String] = []
        for byte in Array(payload.utf8) {
            collected += strings(try framer.append(Data([byte])))
        }
        XCTAssertEqual(collected, ["{\"cmd\":\"hold\"}", "{\"cmd\":\"release\"}"])
    }

    func testStripsCarriageReturnsAndDropsEmptyLines() throws {
        var framer = LineFramer()
        XCTAssertEqual(strings(try framer.append(Data("a\r\n\n\nb\n".utf8))), ["a", "b"])
    }

    func testRejectsAnUnboundedLine() {
        var framer = LineFramer(maxLineBytes: 32)
        XCTAssertThrowsError(try framer.append(Data(repeating: UInt8(ascii: "x"), count: 64))) { error in
            XCTAssertEqual(error as? IPCError, .lineTooLong(limit: 32))
        }
        // The buffer is dropped so the framer stays usable for the next client.
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testStaysUnderTheLimitWhenLinesArriveNormally() throws {
        var framer = LineFramer(maxLineBytes: 32)
        for _ in 0..<100 {
            XCTAssertEqual(strings(try framer.append(Data("short\n".utf8))), ["short"])
        }
    }
}
