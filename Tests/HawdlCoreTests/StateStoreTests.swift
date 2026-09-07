import XCTest
@testable import HawdlCore

final class StateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hawdl-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> StateStore {
        StateStore(url: directory.appendingPathComponent("state.json"))
    }

    func testMissingFileLoadsAsNil() {
        XCTAssertNil(makeStore().load())
    }

    func testSaveCreatesTheDirectoryAndRoundTrips() throws {
        let store = makeStore()
        let state = PersistedState(desired: .hold, updatedAt: Date(timeIntervalSince1970: 1_757_240_625))
        try store.save(state)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(store.load(), state)
    }

    func testOverwritingAnExistingFileWorks() throws {
        let store = makeStore()
        try store.save(PersistedState(desired: .hold))
        XCTAssertEqual(store.load()?.desired, .hold)

        try store.save(PersistedState(desired: .release))
        XCTAssertEqual(store.load()?.desired, .release)
    }

    func testRepeatedSavesLeaveNoTemporaryFiles() throws {
        let store = makeStore()
        for _ in 0..<10 {
            try store.save(PersistedState(desired: .hold))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["state.json"], "found leftovers: \(contents)")
    }

    /// A truncated or hand-edited file must not stop the daemon from starting.
    func testCorruptFileLoadsAsNilInsteadOfThrowing() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
    }

    func testPersistedStateRoundTripsThroughTheSharedCodec() throws {
        let state = PersistedState(desired: .hold, updatedAt: Date(timeIntervalSince1970: 1_757_240_625))
        let data = try HawdlCodec.makeEncoder().encode(state)
        let decoded = try HawdlCodec.makeDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
