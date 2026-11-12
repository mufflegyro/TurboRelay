import XCTest
@testable import TurboRelayCore

/// The menu bar's client count and status line must react to sessions registering and
/// unregistering — register/unregister fires server.onStateChange, and RelayService must
/// forward it to onChange. This regression exists because a healthy engine is quiet: while
/// the engine logged constantly, onLog masked the missing wiring and the menu showed a
/// frozen "0 client(s)" while a client was fully connected.
final class MenuClientCountTests: XCTestCase {

    func testClientCountRefreshesMenu() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = RelayConfig(
            port: Self.freePort(),
            token: String(repeating: "ef", count: 16),
            enginePath: "/usr/bin/true",
            modelRoot: home.appendingPathComponent("hfhub").path,
            hfToken: "",
            hubBaseURL: "",
            engineArgs: []
        )
        try (try? JSONSerialization.data(withJSONObject: [
            "port": config.port, "token": config.token, "engine_path": config.enginePath,
            "model_root": config.modelRoot, "engine_args": [],
        ]))?.write(to: home.appendingPathComponent("config.json"))

        let service = RelayService(home: home, config: config)
        let counter = MenuCounter()
        service.onChange = { counter.bump() }
        try service.start()
        defer { service.stop() }

        // 1. The service started: onChange fired, hello answers.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(counter.count, 0)
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/hello")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let hello = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(hello["app"] as? String, "turbo-relay 0.1")

        // 2. A real WebSocket session registers, the count goes to 1, and unregistering
        //    drops it back to 0 — all through the onChange → menu refresh chain.
        let before = counter.count
        let ws = WebSocketProbe(url: URL(string: "http://127.0.0.1:\(config.port)/engine")!,
                                token: config.token)
        try await waitUntil(5.0, "1 client(s)") { service.statusSummary().contains("1 client(s)") }
        ws.cancel()
        try await waitUntil(5.0, "0 client(s) after disconnect") {
            service.statusSummary().contains("0 client(s)")
        }
        XCTAssertGreaterThan(counter.count, before)
    }

    private func waitUntil(_ seconds: TimeInterval, _ what: String, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let ok = await cond()
        XCTAssertTrue(ok, "timed out waiting for \(what)")
    }

    private static func freePort() -> Int {
        for port in 7870...7890 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
                withUnsafePointer(to: ptr) { p in
                    Darwin.bind(fd, UnsafeRawPointer(p).assumingMemoryBound(to: sockaddr.self),
                                socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { return port }
        }
        return 7888
    }
}

private final class MenuCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func bump() { lock.lock(); value += 1; lock.unlock() }
}

/// Minimal WebSocket client just to open a session (no frames needed).
private final class WebSocketProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var task: URLSessionWebSocketTask!
    init(url: URL, token: String) {
        super.init()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task.resume()
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol: String?) {}
}
