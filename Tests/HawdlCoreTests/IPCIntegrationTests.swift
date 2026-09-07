import Darwin
import XCTest
@testable import HawdlCore

/// Drives the real IPCServer over a real Unix domain socket with the real
/// IPCClient. No root and no awdl0 required, so CI covers the wire too and not
/// just the message types.
final class IPCIntegrationTests: XCTestCase {
    private var socketPath = ""
    private var server: IPCServer!
    private let queue = DispatchQueue(label: "hawdl.tests.ipc")

    /// The library sets SO_NOSIGPIPE on every socket it owns, but xctest is a
    /// host process that has not disarmed SIGPIPE, and a stray one kills the
    /// whole run with no failure message. hawdld does the same thing in run().
    override class func setUp() {
        _ = signal(SIGPIPE, SIG_IGN)
    }

    override func setUpWithError() throws {
        // Unix socket paths are capped at ~104 bytes, so keep this short.
        socketPath = "/tmp/hawdl-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDownWithError() throws {
        if let server {
            queue.sync { server.stop() }
        }
        server = nil
        unlink(socketPath)
    }

    private func startServer(
        handler: @escaping (Command) -> StatusMessage
    ) throws {
        let server = IPCServer(
            socketPath: socketPath,
            queue: queue,
            handler: handler
        )
        try queue.sync { try server.start() }
        self.server = server
    }

    private func makeStatus(
        _ desired: DesiredState = .hold,
        _ actual: InterfaceState = .down,
        flapCount: Int = 0
    ) -> StatusMessage {
        StatusMessage(desired: desired, actual: actual, flapCount: flapCount)
    }

    func testStatusRequestGetsAReply() throws {
        try startServer { _ in self.makeStatus(.hold, .down, flapCount: 7) }

        let reply = try IPCClient.request(.status, socketPath: socketPath, timeout: 5)
        XCTAssertEqual(reply.desired, .hold)
        XCTAssertEqual(reply.actual, .down)
        XCTAssertEqual(reply.flapCount, 7)
        XCTAssertTrue(reply.available)
        XCTAssertEqual(reply.daemonVersion, hawdlVersion)
    }

    func testEveryCommandReachesTheHandler() throws {
        let received = Locked<[Command]>([])
        try startServer { command in
            received.mutate { $0.append(command) }
            return self.makeStatus(command == .hold ? .hold : .release)
        }

        for command in [Command.status, .hold, .release, .subscribe] {
            _ = try IPCClient.request(command, socketPath: socketPath, timeout: 5)
        }
        XCTAssertEqual(received.value, [.status, .hold, .release, .subscribe])
    }

    func testSubscribersReceivePushedUpdates() throws {
        try startServer { _ in self.makeStatus(.hold, .down, flapCount: 0) }

        let client = IPCClient(socketPath: socketPath)
        try client.connect(readTimeout: 5)
        defer { client.close() }
        try client.send(Request(cmd: .subscribe))

        // First line is the reply to `subscribe` itself.
        XCTAssertEqual(try client.receive().flapCount, 0)

        for count in 1...5 {
            queue.async { self.server.broadcast(self.makeStatus(.hold, .down, flapCount: count)) }
            XCTAssertEqual(try client.receive().flapCount, count)
        }
    }

    func testNonSubscribersAreNotPushedTo() throws {
        try startServer { _ in self.makeStatus() }

        let client = IPCClient(socketPath: socketPath)
        try client.connect(readTimeout: 1)
        defer { client.close() }
        try client.send(Request(cmd: .status))
        _ = try client.receive()

        queue.async { self.server.broadcast(self.makeStatus(.release, .up, flapCount: 99)) }
        XCTAssertThrowsError(try client.receive()) { error in
            XCTAssertEqual(error as? IPCClient.ClientError, .timedOut)
        }
    }

    func testSeveralSubscribersAllGetTheSameUpdate() throws {
        try startServer { _ in self.makeStatus() }

        var clients: [IPCClient] = []
        for _ in 0..<4 {
            let client = IPCClient(socketPath: socketPath)
            try client.connect(readTimeout: 5)
            try client.send(Request(cmd: .subscribe))
            _ = try client.receive()
            clients.append(client)
        }
        defer { clients.forEach { $0.close() } }

        queue.async { self.server.broadcast(self.makeStatus(.release, .up, flapCount: 42)) }
        for client in clients {
            XCTAssertEqual(try client.receive().flapCount, 42)
        }
    }

    func testPipelinedRequestsAllGetAnswered() throws {
        try startServer { _ in self.makeStatus() }

        let client = IPCClient(socketPath: socketPath)
        try client.connect(readTimeout: 5)
        defer { client.close() }

        for _ in 0..<10 {
            try client.send(Request(cmd: .status))
        }
        for _ in 0..<10 {
            XCTAssertEqual(try client.receive().desired, .hold)
        }
    }

    func testGarbageDoesNotKillTheServer() throws {
        try startServer { _ in self.makeStatus() }

        let raw = try UnixSocket.connect(to: socketPath)
        _ = "not json at all\n{\"cmd\":\"nonsense\"}\n".withCString { pointer in
            write(raw, pointer, strlen(pointer))
        }
        _ = "{\"cmd\":\"status\"}\n".withCString { pointer in
            write(raw, pointer, strlen(pointer))
        }

        var buffer = [UInt8](repeating: 0, count: 1024)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(raw, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let count = read(raw, &buffer, buffer.count)
        close(raw)

        XCTAssertGreaterThan(count, 0, "the server should have answered the valid request")
        let decoded = try HawdlCodec.decodeLine(
            StatusMessage.self,
            from: Data(buffer[0..<max(count, 0)])
        )
        XCTAssertEqual(decoded.desired, .hold)
    }

    func testConnectingWithNoDaemonReportsItCleanly() {
        let client = IPCClient(socketPath: "/tmp/hawdl-definitely-not-here-\(UUID().uuidString).sock")
        XCTAssertThrowsError(try client.connect()) { error in
            guard case IPCClient.ClientError.daemonNotRunning = error else {
                return XCTFail("expected daemonNotRunning, got \(error)")
            }
        }
    }

    /// If this regresses, a peer disappearing mid-write kills the host process
    /// instead of returning EPIPE.
    func testConnectedSocketsHaveSIGPIPESuppressed() throws {
        try startServer { _ in self.makeStatus() }

        let fd = try UnixSocket.connect(to: socketPath)
        defer { _ = close(fd) }

        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let rc = getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length)
        XCTAssertEqual(rc, 0, "getsockopt(SO_NOSIGPIPE) failed: \(String(cString: strerror(errno)))")
        XCTAssertNotEqual(value, 0, "SO_NOSIGPIPE is not set on a connected socket")
    }

    func testTheSocketIsWorldWritable() throws {
        try startServer { _ in self.makeStatus() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o666,
                       "documented in the README as a security trade-off")
    }

    func testStoppingTheServerRemovesTheSocketFile() throws {
        try startServer { _ in self.makeStatus() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        queue.sync { server.stop() }
        server = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testAClientThatGoesAwayDoesNotBreakTheServer() throws {
        try startServer { _ in self.makeStatus() }

        for _ in 0..<20 {
            let client = IPCClient(socketPath: socketPath)
            try client.connect(readTimeout: 5)
            try client.send(Request(cmd: .subscribe))
            client.close()
        }

        // Give the server a moment to reap them, then broadcast into the void.
        queue.sync { self.server.broadcast(self.makeStatus()) }

        let survivor = try IPCClient.request(.status, socketPath: socketPath, timeout: 5)
        XCTAssertEqual(survivor.desired, .hold)
    }
}

/// Minimal lock box so a test can read state the server queue writes.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
