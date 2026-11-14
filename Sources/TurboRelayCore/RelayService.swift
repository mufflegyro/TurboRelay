import Foundation
import CryptoKit

/// Glue: config + engine supervisor + bridge + HTTP/WS listener, shared by the RelayServer
/// CLI (tests, headless use) and the TurboRelayApp menu bar app.
public final class RelayService: @unchecked Sendable {
    public let token: String
    public let port: Int
    public let stagingURL: URL
    public var onChange: (() -> Void)?

    private let home: URL
    private let config: RelayConfig
    private var bridge: Bridge?
    private var server: HTTPWebSocketServer?
    private var downloads: DownloadManager?

    public init(home: URL, config: RelayConfig) {
        self.home = home
        self.config = config
        self.token = config.token
        self.port = config.port
        self.stagingURL = config.stagingURL
    }

    public func start() throws {
        let enginePath = resolvedEnginePath()
        var environment = ProcessInfo.processInfo.environment
        // A8: deliberate environment — the engine's HF lookups land in our cache, not whatever
        // the parent shell had.
        environment["HF_HOME"] = config.modelRootURL.deletingLastPathComponent().path

        // Two engines, one pipe protocol. The native engine boots now; the mflux worker waits
        // for its first job, and is simply absent when its venv is not installed.
        let router = EngineRouter { engine in
            switch engine {
            case .turbo:
                return EngineSupervisor(name: "turbo-engine", executablePath: enginePath,
                                        arguments: ["serve"] + config.engineArgs,
                                        environment: environment)
            case .mflux:
                guard let python = self.resolvedMFluxPython(), let worker = self.resolvedMFluxWorker() else {
                    return nil
                }
                var mfluxEnvironment = environment
                // A signed bundle is read-only: never write .pyc beside worker.py, and keep
                // the log lines flowing without Python's buffering.
                mfluxEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"
                mfluxEnvironment["PYTHONUNBUFFERED"] = "1"
                return EngineSupervisor(name: "mflux", executablePath: python,
                                        arguments: [worker, "serve"],
                                        environment: mfluxEnvironment)
            }
        }

        let downloads = DownloadManager(
            hubCache: config.modelRootURL,
            baseURL: config.hubBaseURL.isEmpty ? URL(string: "https://huggingface.co")! : (URL(string: config.hubBaseURL) ?? URL(fileURLWithPath: config.hubBaseURL)),
            token: config.resolvedHFToken,
            customStore: home.appendingPathComponent("custom-models.json")
        )
        downloads.onEvent = { [weak self] modelID, status, bytes, total, message in
            guard let self else { return }
            var event: [String: Any] = [
                "event": "model_download", "model_id": modelID, "status": status,
                "bytes": Int(bytes), "total": Int(total),
            ]
            if let message { event["message"] = message }
            guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else { return }
            self.server?.broadcast(String(decoding: data, as: UTF8.self))
        }
        downloads.onChange = { [weak self] in self?.onChange?() }
        self.downloads = downloads

        let bridge = Bridge(home: home, modelRoot: config.modelRootURL, router: router)
        let server = HTTPWebSocketServer(port: UInt16(config.port), token: config.token)
        bridge.broadcast = { [weak server] line in server?.broadcast(line) }
        bridge.onChange = { [weak self] in self?.onChange?() }
        self.bridge = bridge

        server.onLog = { [weak self] line in self?.onChange?() }
        // Register/unregister must refresh the menu's client count live (the engine log
        // used to mask this by firing onLog constantly; a healthy engine is quiet).
        server.onStateChange = { [weak self] in self?.onChange?() }
        server.onRequest = { [weak self, weak bridge] request, respond in
            self?.handle(request, bridge: bridge, respond: respond)
        }
        server.onWebSocket = { [weak bridge] session in
            session.onText = { text in bridge?.wireCommand(text) }
            // A client connecting after the engine started still needs its ready event.
            if let line = bridge?.readyLine() {
                session.sendText(line)
            }
        }
        self.server = server
        try server.start()

        bridge.start()
        onChange?()
    }

    public func stop() {
        bridge?.stop()
        server?.stop()
    }

    // MARK: - Status (menu bar)

    public func statusSummary() -> String {
        guard let bridge, let server else { return "Starting…" }
        let clients = server.clientCount
        let loaded = bridge.loadedModelName()
        var state = bridge.recentLog().last.map { log in
            log.contains("engine started") ? "engine running" : "engine up"
        } ?? "engine starting"
        // A crash-looping engine (e.g. missing resource bundles) otherwise keeps saying
        // "engine running" forever — surface the restart attempts in the menu.
        let restarts = bridge.restartCount()
        if restarts > 0 {
            state += " · restarting (attempt \(restarts)) — see the engine log"
        }
        if let active = bridge.activeEngineName() {
            state += " · \(active) engine"
        }
        return "Port \(port) · \(state) · \(clients) client(s)\(loaded.map { " · \($0)" } ?? "")"
    }

    public func loadedModelName() -> String? {
        bridge?.loadedModelName()
    }

    /// Lookup order per plan M2: config → bundled turbo-engine → bundled StubEngine.
    private func resolvedEnginePath() -> String {
        if !config.enginePath.isEmpty, FileManager.default.isExecutableFile(atPath: config.enginePath) {
            return config.enginePath
        }
        for name in ["turbo-engine", "StubEngine"] {
            if let url = Bundle.main.url(forAuxiliaryExecutable: name),
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
        return config.enginePath
    }

    /// The mflux venv's Python: configured, else the relay's lazily installed venv.
    private func resolvedMFluxPython() -> String? {
        let path = config.mfluxPython.isEmpty
            ? home.appendingPathComponent("mflux-venv/bin/python").path
            : (config.mfluxPython as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The worker script: configured, else the one build.sh puts in the bundle's Resources.
    private func resolvedMFluxWorker() -> String? {
        let path: String
        if !config.mfluxWorker.isEmpty {
            path = (config.mfluxWorker as NSString).expandingTildeInPath
        } else if let bundled = Bundle.main.url(forResource: "worker", withExtension: "py") {
            path = bundled.path
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - HTTP routing

    private func handle(_ request: HTTPRequest, bridge: Bridge?, respond: @escaping (HTTPResponse) -> Void) {
        guard let bridge else {
            respond(.error(503, "starting"))
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/hello"):
            var hello = bridge.helloFields()
            hello["downloads"] = downloads?.helloDownloads() ?? [:]
            respond(.json(hello))
        case ("GET", "/jobs"):
            respond(.json(["jobs": bridge.jobList()]))
        case ("GET", "/log"):
            respond(.json(["lines": bridge.recentLog()]))
        case ("GET", "/models"):
            respond(.json([
                "models": downloads?.modelsView() ?? [],
                "catalog_version": ModelCatalog.version,
            ]))
        case ("POST", let path) where path.hasPrefix("/models/") && path.hasSuffix("/download/cancel"):
            let id = String(path.dropFirst("/models/".count).dropLast("/download/cancel".count))
            downloads?.cancel(id.removingPercentEncoding ?? id)
            respond(.json(["cancelled": true]))
        case ("POST", let path) where path.hasPrefix("/models/") && path.hasSuffix("/download/quality"):
            let qualityID = String(path.dropFirst("/models/".count).dropLast("/download/quality".count))
                .removingPercentEncoding ?? ""
            if let problem = downloads?.start(qualityID, quality: true) {
                respond(.error(409, problem))
            } else {
                respond(.json(["started": true, "id": qualityID, "quality": true]))
            }
        case ("POST", let path) where path.hasPrefix("/models/") && path.hasSuffix("/download"):
            let id = String(path.dropFirst("/models/".count).dropLast("/download".count)).removingPercentEncoding ?? ""
            // A model the built-in catalog does not ship (the client added it by hand): the
            // request carries its descriptor, so the relay can download it too. Registering is
            // idempotent; a built-in id keeps the catalog's own descriptor.
            if let descriptor = (try? JSONDecoder().decode(ModelDescriptor.self, from: request.body)),
               descriptor.id == id || descriptor.repo == id {
                downloads?.register(descriptor)
            }
            if let problem = downloads?.start(id) {
                respond(.error(409, problem))
            } else {
                respond(.json(["started": true, "id": id]))
            }
        case ("POST", "/upload/probe"):
            uploadProbe(request, respond: respond)
        case ("PUT", let path) where path.hasPrefix("/upload/"):
            uploadPut(request, hex: String(path.dropFirst("/upload/".count)), respond: respond)
        case ("GET", let path) where path.hasPrefix("/files/"):
            fetchFile(String(path.dropFirst("/files/".count)), bridge: bridge, respond: respond)
        default:
            respond(.error(404, "no such endpoint"))
        }
    }

    private func uploadProbe(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let hex = object["sha256"] as? String, Self.isHex64(hex) else {
            respond(.error(400, "probe needs {\"sha256\": \"<64-hex>\", \"size\": n}"))
            return
        }
        let exists = FileManager.default.fileExists(atPath: uploadURL(hex).path)
        respond(.json(["exists": exists, "id": hex]))
    }

    private func uploadPut(_ request: HTTPRequest, hex: String, respond: @escaping (HTTPResponse) -> Void) {
        guard Self.isHex64(hex) else {
            respond(.error(400, "the upload id must be a 64-hex sha256"))
            return
        }
        let digest = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
        guard digest == hex else {
            respond(.json(["error": "sha256 mismatch: the bytes that arrived hash to \(digest.prefix(12))…"], status: 409))
            return
        }
        let destination = uploadURL(hex)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try request.body.write(to: destination, options: .atomic)
        } catch {
            respond(.error(500, "could not store the upload: \(error.localizedDescription)"))
            return
        }
        respond(.json(["id": hex]))
    }

    private func fetchFile(_ fileID: String, bridge: Bridge, respond: @escaping (HTTPResponse) -> Void) {
        guard let staged = bridge.stagedFile(fileID) else {
            respond(.error(404, "no such file; it may have been evicted (the server keeps the last 20 results)"))
            return
        }
        do {
            respond(.file(try Data(contentsOf: staged.url), mediaType: staged.mediaType))
        } catch {
            respond(.error(500, "could not read the staged file"))
        }
    }

    private func uploadURL(_ hex: String) -> URL {
        config.uploadsURL.appendingPathComponent(String(hex.prefix(2))).appendingPathComponent(hex)
    }

    static func isHex64(_ string: String) -> Bool {
        string.count == 64 && string.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
