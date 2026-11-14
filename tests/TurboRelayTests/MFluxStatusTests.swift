import XCTest
@testable import TurboRelayCore

/// Decision 2: a relay with the worker script but no venv says "mflux not installed" in the
/// menu and reports it from /models — and does not install anything at launch.
final class MFluxStatusTests: XCTestCase {
    func testMenuAndModelsReportMFluxMissing() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TurboRelayTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // TurboRelay
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mflux-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let config = RelayConfig(
            port: Self.freePort(),
            token: String(repeating: "ef", count: 16),
            enginePath: "/usr/bin/true",
            modelRoot: home.appendingPathComponent("hfhub").path,
            hfToken: "",
            hubBaseURL: "",
            engineArgs: [],
            mfluxPython: "",
            mfluxWorker: packageRoot.appendingPathComponent("mflux-worker/worker.py").path,
            mfluxRequirements: packageRoot.appendingPathComponent("mflux-worker/requirements.txt").path
        )
        let service = RelayService(home: home, config: config)
        try service.start()
        defer { service.stop() }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(service.statusSummary().contains("mflux not installed"), service.statusSummary())

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/models")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let mflux = object?["mflux"] as? [String: Any]
        XCTAssertEqual(mflux?["state"] as? String, "missing", String(describing: mflux))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("mflux-venv").path),
                       "launch must not install the venv")
    }

    private static func freePort() -> Int {
        for port in 7910...7930 {
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
        return 7920
    }
}
