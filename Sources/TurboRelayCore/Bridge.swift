import Foundation

/// Translates between the wire protocol (network, TurboRelay/docs/remote-protocol.md) and
/// the engine protocol (turbo-engine's stdin/stdout JSON lines), over one or two engines:
///
///   wire command in → path-hostility check → family → engine → resolve model paths + upload
///   handles → rewrite `output` into the staging area → that engine's stdin
///
///   engine event out → strip file paths into handles (`file_id`) or bytes (`preview.data`)
///   → broadcast on the wire, update the job registry
///
/// The native `turbo-engine` serves the catalog; the mflux worker serves Krea 2 and
/// Qwen-Image 2.1 (`ModelFamily.mfluxFamilyNames`). `EngineRouter` owns the one-model-at-a-time
/// rule between them.
///
/// All translation per the amendments A1 (uploads), A2 (model-id resolution, bytes not
/// paths), A3 (previews), A5 (families), A8 (deliberate engine environment).
public final class Bridge: @unchecked Sendable {
    struct Job {
        var id: String
        var model: String
        var family: String
        var status: String
        var submittedAt: Date
        var fileID: String?
        var error: String?
        var engine: ModelEngine
    }

    struct StagedFile {
        var url: URL
        var mediaType: String
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var files: [String: StagedFile] = [:]
    private var fileOrder: [String] = []
    private var pathToName: [String: String] = [:]
    /// Each engine's last `ready` event, keyed by engine: `/hello` and the greeting compose
    /// the active engine's strings with the union of the families the relay can serve.
    private var readyInfo: [ModelEngine: [String: Any]] = [:]
    private var logLines: [String] = []
    private var lastLoadedName: String?
    private var activeJobs = 0
    /// The render Mac's memory in bytes, from whichever engine is ready (A4).
    private var serverMemoryBytes: Int64 = 0
    /// Content-addressed uploads each job references: released when the job ends, and
    /// unreferenced files older than an hour are evicted (spec §Uploads).
    private var uploadRefs: [String: Int] = [:]
    private var jobUploads: [String: [String]] = [:]
    private let keepAwake = KeepAwake(reason: "TurboRelay is generating for a client")
    private let resultsLimit = 20

    public let router: EngineRouter
    private let locator: ModelLocator
    private let home: URL
    /// Set by the service: sends a wire line to every connected client.
    public var broadcast: ((String) -> Void)?
    public var onChange: (() -> Void)?

    public init(home: URL, modelRoot: URL, router: EngineRouter) {
        self.home = home
        self.locator = ModelLocator(hub: modelRoot)
        self.router = router
        router.onEvent = { [weak self] engine, line in self?.engineEvent(engine, line) }
        router.onLog = { [weak self] engine, line in self?.engineLog(engine, line) }
        router.onExit = { [weak self] engine, intentional in
            self?.engineExited(engine, intentional: intentional)
        }
        router.onActiveChange = { [weak self] in self?.onChange?() }
    }

    /// An engine process died. A switch (intentional) has no jobs by construction; a crash
    /// fails that engine's jobs loudly, and its supervisor restarts with backoff.
    private func engineExited(_ engine: ModelEngine, intentional: Bool) {
        guard !intentional else {
            onChange?()
            return
        }
        lock.lock()
        let running = jobs.values.filter {
            $0.engine == engine && ($0.status == "running" || $0.status == "queued")
        }
        for job in running {
            jobs[job.id]?.status = "failed"
            jobs[job.id]?.error = "The \(engine.rawValue) engine quit unexpectedly on the render Mac; it is restarting."
        }
        activeJobs = max(0, activeJobs - running.count)
        keepAwake.isOn = activeJobs > 0
        lock.unlock()
        for job in running {
            emit(jsonLine(["event": "failed", "id": job.id,
                           "message": "The \(engine.rawValue) engine quit unexpectedly on the render Mac; it is restarting. Run the job again."]))
        }
        onChange?()
    }

    public func start() { router.start() }
    public func stop() { router.stop() }

    // MARK: - Status (menu bar, /hello)

    /// The ready event the wire sees: the active engine's own strings and memory, with the
    /// union of every served family (the native engine's and the mflux worker's).
    private func composedReady() -> [String: Any]? {
        lock.lock()
        let active = router.activeEngine()
        let infos = readyInfo
        lock.unlock()
        guard active != nil || !infos.isEmpty else { return nil }

        var ready = active.flatMap { infos[$0] } ?? [:]
        ready["event"] = "ready"
        ready["families"] = servedFamilies(infos)
        if ready["engine"] == nil { ready["engine"] = "starting" }
        if ready["memory"] == nil { ready["memory"] = Int(ProcessInfo.processInfo.physicalMemory) }
        return ready
    }

    private func servedFamilies(_ infos: [ModelEngine: [String: Any]]) -> [String] {
        var families = Set<String>()
        for info in infos.values {
            if let list = info["families"] as? [String] { families.formUnion(list) }
        }
        // The worker's ready is only seen once it has started; its families are known from
        // the moment the venv exists, so the handshake does not change after the first job.
        if router.isAvailable(.mflux) { families.formUnion(ModelFamily.mfluxFamilyNames) }
        return families.sorted()
    }

    public func helloFields() -> [String: Any] {
        var hello: [String: Any] = [
            "protocol_version": 1,
            "app": "turbo-relay 0.1",
            "downloads": [String: String](), // M3
            // The catalog is the same before and after an engine is ready: the client can
            // compare it from the first handshake (spec §Handshake).
            "catalog_version": ModelCatalog.version,
        ]
        if let ready = composedReady() {
            for key in ["engine", "mlx", "device", "memory", "families"] where ready[key] != nil {
                hello[key == "memory" ? "memory_bytes" : key] = ready[key]
            }
        } else {
            hello["engine"] = "starting"
            hello["families"] = [String]()
            hello["memory_bytes"] = Int(ProcessInfo.processInfo.physicalMemory)
        }
        return hello
    }

    /// How many times an engine has restarted in its lifetime — the menu surfaces a crash-loop
    /// instead of a forever-"running" engine (the bundled metallib bug did that).
    public func restartCount() -> Int {
        max(router.restartAttempts(.turbo), router.restartAttempts(.mflux))
    }

    public func readyLine() -> String? {
        composedReady().map(jsonLine)
    }

    /// "turbo" or "mflux": which engine holds the model (the menu's status line).
    public func activeEngineName() -> String? {
        router.activeEngine()?.rawValue
    }

    public func jobList() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.sorted { $0.submittedAt < $1.submittedAt }.map { job in
            var entry: [String: Any] = [
                "id": job.id, "status": job.status, "model": job.model,
                "family": job.family, "engine": job.engine.rawValue,
                "submitted_at": ISO8601DateFormatter().string(from: job.submittedAt),
            ]
            if let fileID = job.fileID { entry["file_id"] = fileID }
            if let error = job.error { entry["error"] = error }
            return entry
        }
    }

    public func recentLog() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logLines
    }

    func stagedFile(_ id: String) -> StagedFile? {
        lock.lock()
        defer { lock.unlock() }
        return files[id]
    }

    public func loadedModelName() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastLoadedName
    }

    // MARK: - Wire commands (client → server → engine)

    public func wireCommand(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let cmd = object["cmd"] as? String else {
            sendLog("invalid wire command: \(text.prefix(200))")
            return
        }
        // Path-hostility defense in depth: RelayLint governs the wire, the bridge refuses
        // violations here too, so a misbehaving client cannot smuggle client paths in.
        if let violation = Self.hostilityViolation(object) {
            fail(jobID: object["id"] as? String, message: "rejected by path-hostility rules: \(violation)")
            return
        }
        switch cmd {
        case "generate": translateGenerate(object)
        case "load": translateLoad(object)
        case "cancel":
            guard let id = object["id"] as? String else {
                sendLog("cancel without id")
                return
            }
            if router.cancel(jobID: id) {
                // It waited for an engine switch and never reached one: the bridge reports
                // the cancellation itself, as the engine would have.
                finishJob(id, status: "cancelled", error: nil)
                emit(jsonLine(["event": "cancelled", "id": id]))
            } else if let engine = jobEngine(id) {
                router.send(text, to: engine)
            } else {
                router.sendToActive(text)
            }
        case "unload": router.sendToActive(text)
        case "shutdown": sendLog("shutdown is reserved to the server")
        default: sendLog("unknown wire command: \(cmd)")
        }
    }

    static func hostilityViolation(_ object: [String: Any]) -> String? {
        guard let cmd = object["cmd"] as? String else { return "command without cmd" }
        guard cmd == "generate" || cmd == "load" else { return nil }
        guard let model = object["model"] as? [String: Any] else { return "model is required" }
        if model["path"] != nil { return "model.path" }
        if model["text_encoder_path"] != nil { return "model.text_encoder_path" }
        if (model["name"] as? String)?.isEmpty != false { return "model.name (the catalog id) is required" }
        if cmd == "generate" {
            guard let params = object["params"] as? [String: Any] else { return "params is required" }
            if params["output"] != nil { return "params.output" }
            for key in ["image", "last_image"] {
                if params[key] is String { return "params.\(key) must be an upload handle" }
            }
            if let images = params["images"] as? [Any], images.contains(where: { $0 is String }) {
                return "params.images[] must be upload handles"
            }
            if let loras = params["loras"] as? [Any] {
                for lora in loras {
                    guard let spec = lora as? [String: Any], spec["upload"] is String else {
                        return "params.loras[] must be upload handles"
                    }
                }
            }
        }
        return nil
    }

    private func translateGenerate(_ object: [String: Any]) {
        guard let jobID = object["id"] as? String, !jobID.isEmpty else {
            sendLog("generate without id")
            return
        }
        guard var model = deepCopy(object["model"]) as? [String: Any],
              let name = model["name"] as? String else {
            fail(jobID: jobID, message: "generate.model.name is required")
            return
        }
        let family = model["family"] as? String ?? ""
        let engine = ModelFamily.engine(forFamily: family)
        if engine == .mflux, !router.isAvailable(.mflux) {
            fail(jobID: jobID, message: "\(family) needs the mflux engine, which is not installed on the render Mac. Install the relay's mflux environment first.")
            return
        }
        // The catalog pins a revision; the locator falls back to whatever snapshot is on disk
        // (a model downloaded by hand or by other tools still runs).
        let revision = ModelCatalog.builtIn.first { $0.id == name }?.revision
        guard var params = deepCopy(object["params"]) as? [String: Any] else {
            fail(jobID: jobID, message: "generate.params is required")
            return
        }
        guard let resolved = locator.resolve(name, revision: revision) else {
            fail(jobID: jobID, message: "Model \(name) is not downloaded on this server; download it first (GET /models).")
            return
        }
        model["path"] = resolved.path

        // The upload handles the client sent (A1), from the original command: each is
        // retained for this job and released when the job ends.
        let originalParams = deepCopy(object["params"]) as? [String: Any] ?? [:]
        var handleHashes: [String] = []
        for key in ["image", "last_image"] {
            if let hex = (originalParams[key] as? [String: Any])?["upload"] as? String { handleHashes.append(hex) }
        }
        if let images = originalParams["images"] as? [[String: Any]] {
            for image in images {
                if let hex = image["upload"] as? String { handleHashes.append(hex) }
            }
        }
        if let loras = originalParams["loras"] as? [[String: Any]] {
            for lora in loras {
                if let hex = lora["upload"] as? String { handleHashes.append(hex) }
            }
        }

        params["output"] = home.appendingPathComponent("staging/results/result-\(jobID)\(Self.fileExtension(forFamily: family))").path

        for key in ["image", "last_image"] {
            if let handle = params[key] as? [String: Any] {
                guard let path = uploadPath(for: handle) else {
                    fail(jobID: jobID, message: "an uploaded file is missing; upload it again (params.\(key))")
                    return
                }
                params[key] = path
            }
        }
        if let images = params["images"] as? [[String: Any]] {
            var paths: [String] = []
            for image in images {
                guard let path = uploadPath(for: image) else {
                    fail(jobID: jobID, message: "an uploaded file is missing; upload it again (params.images)")
                    return
                }
                paths.append(path)
            }
            params["images"] = paths
        }
        if let loras = params["loras"] as? [[String: Any]] {
            var translated: [[String: Any]] = []
            for lora in loras {
                guard let hex = lora["upload"] as? String, let uploadPath = uploadPath(for: lora) else {
                    fail(jobID: jobID, message: "an uploaded LoRA is missing; upload it again (params.loras)")
                    return
                }
                // Stage the LoRA under a name ending in .safetensors: the engine's LoRA loader
                // selects the format by path extension (A1 uploads are content-addressed by a
                // bare-hex filename, which the engine rejects as "Unknown extension"). The
                // client sends the original filename; we symlink the staged blob to it.
                let name = (lora["name"] as? String) ?? (hex + ".safetensors")
                let staged = stageLora(hex: hex, name: name, uploadPath: uploadPath)
                translated.append(["path": staged, "scale": lora["scale"] ?? 1])
            }
            params["loras"] = translated
        }

        guard var command = deepCopy(object) as? [String: Any] else { return }
        command["model"] = model
        command["params"] = params

        // The authoritative memory backstop (spec §Error model, amendment A4): the client's
        // gate is advisory — this server refuses a job whose estimated peak does not fit its
        // own memory, so a stale client can never take the render Mac down. A staged LoRA's
        // matrices sit beside the model, as large as its file.
        let serverGigabytes = Double(serverMemoryBytes) / Double(1 << 30)
        var loraGigabytes = 0.0
        let catalogDescriptor = ModelCatalog.builtIn.first { $0.id == name }
        if let catalogDescriptor, catalogDescriptor.family.takesLoRAs {
            for hash in handleHashes {
                loraGigabytes += stagedUploadGigabytes(hex: hash)
            }
        }
        if let catalogDescriptor,
           let peak = MemoryEstimate.peak(model: catalogDescriptor,
                                          size: PixelSize(width: (params["width"] as? Int) ?? 512,
                                                          height: (params["height"] as? Int) ?? 512),
                                          frames: params["frames"] as? Int,
                                          // Save memory rides on the model object (the client's
                                          // `modelObject`), not on params; params keeps the old
                                          // spelling for older clients.
                                          lowMemory: (model["low_ram"] as? Bool) ?? (params["low_ram"] as? Bool) ?? false,
                                          memory: serverGigabytes) {
            let needed = peak + loraGigabytes
            let free = MemoryEstimate.available(memory: serverGigabytes)
            if needed > free {
                fail(jobID: jobID, message: "Needs about \(Int(needed.rounded(.up))) GB of memory, more than the render Mac can give (\(Int(serverGigabytes.rounded())) GB installed). Try Save memory or a smaller size.")
                return
            }
        }

        lock.lock()
        pathToName[resolved.path] = name
        jobs[jobID] = Job(id: jobID, model: name, family: family, status: "running", submittedAt: Date(), fileID: nil, error: nil, engine: engine)
        jobUploads[jobID] = handleHashes
        for hash in handleHashes { uploadRefs[hash, default: 0] += 1 }
        activeJobs += 1
        keepAwake.isOn = activeJobs > 0
        lock.unlock()
        onChange?()

        router.send(jsonLine(command), to: engine, startsJob: true, jobID: jobID)
    }

    private func translateLoad(_ object: [String: Any]) {
        guard var model = deepCopy(object["model"]) as? [String: Any],
              let name = model["name"] as? String else {
            sendLog("load.model.name is required")
            return
        }
        let family = model["family"] as? String ?? ""
        let engine = ModelFamily.engine(forFamily: family)
        if engine == .mflux, !router.isAvailable(.mflux) {
            sendLog("\(family) needs the mflux engine, which is not installed on the render Mac")
            return
        }
        guard let resolved = locator.resolve(name, revision: ModelCatalog.builtIn.first { $0.id == name }?.revision) else {
            sendLog("Model \(name) is not downloaded on this server; download it first (GET /models).")
            return
        }
        model["path"] = resolved.path
        guard var command = deepCopy(object) as? [String: Any] else { return }
        command["model"] = model
        lock.lock()
        pathToName[resolved.path] = name
        lock.unlock()
        router.send(jsonLine(command), to: engine)
    }

    // MARK: - Engine events (engine → wire)

    private func engineEvent(_ engine: ModelEngine, _ line: String) {
        guard let dict = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let event = dict["event"] as? String else {
            engineLog(engine, line)
            return
        }
        var wire = dict
        switch event {
        case "ready":
            lock.lock()
            readyInfo[engine] = dict
            serverMemoryBytes = dict["memory"] as? Int64 ?? 0
            lock.unlock()
            // A client that connected before an engine finished booting got no greeting (or
            // the previous engine's): broadcast the composed ready, not merely cache it.
            wire = composedReady() ?? dict
            onChange?()
        case "model_loaded":
            if let path = wire["path"] as? String {
                wire.removeValue(forKey: "path")
                lock.lock()
                let name = pathToName[path]
                lastLoadedName = name ?? path.split(separator: "/").last.map(String.init)
                lock.unlock()
                if let name { wire["name"] = name }
                onChange?()
            }
        case "preview":
            if let path = wire["path"] as? String {
                wire.removeValue(forKey: "path")
                let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                if !data.isEmpty, data.count <= 1_048_576 {
                    wire["data"] = data.base64EncodedString() // A3: inline bytes
                } else if !data.isEmpty {
                    wire["file_id"] = stageResultFile(at: URL(fileURLWithPath: path), mediaType: "image/png")
                }
            }
        case "done":
            let jobID = dict["id"] as? String ?? ""
            lock.lock()
            let job = jobs[jobID]
            lock.unlock()
            let family = job?.family ?? ""
            // The engine that ran the job travels with the result, for the client's history
            // badge (the relay's own jobs registry carries it too).
            if let job { wire["engine"] = job.engine.rawValue }
            if let path = wire["path"] as? String {
                wire.removeValue(forKey: "path")
                let mediaType = Self.mediaType(forFamily: family)
                wire["file_id"] = stageResultFile(at: URL(fileURLWithPath: path), mediaType: mediaType)
                wire["media_type"] = mediaType
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                wire["size"] = (attributes?[.size] as? Int) ?? 0
            }
            if let poster = wire["poster"] as? String {
                wire.removeValue(forKey: "poster")
                wire["poster_file_id"] = stageResultFile(at: URL(fileURLWithPath: poster), mediaType: "image/png")
            }
            finishJob(jobID, status: "done", error: nil, fileID: wire["file_id"] as? String)
        case "failed":
            finishJob(dict["id"] as? String, status: "failed", error: dict["message"] as? String)
        case "cancelled":
            finishJob(dict["id"] as? String, status: "cancelled", error: nil)
        default:
            break // phase, progress, unloaded, load_failed pass through
        }
        emit(jsonLine(wire))
    }

    private func engineLog(_ engine: ModelEngine, _ line: String) {
        appendLog(line)
    }

    private func appendLog(_ line: String) {
        lock.lock()
        logLines.append(line)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        lock.unlock()
        emit(jsonLine(["event": "log", "message": line]))
    }

    private func sendLog(_ message: String) {
        appendLog("[relay] " + message)
    }

    // MARK: - Staging

    /// Symlinks a content-addressed LoRA upload under a `.safetensors` name (the engine picks
    /// the format off the path extension). Returns the path to hand to the engine.
    private func stageLora(hex: String, name: String, uploadPath: String) -> String {
        let dir = home.appendingPathComponent("staging/loras", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Ensure the name ends in .safetensors; a same-named file from another job reuses it
        // (content-addressed, so the bytes are identical).
        var stagedName = name
        if !stagedName.lowercased().hasSuffix(".safetensors") {
            stagedName = (stagedName as NSString).deletingPathExtension + ".safetensors"
        }
        let destination = dir.appendingPathComponent("\(hex)-\(stagedName)")
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            try? fm.createSymbolicLink(at: destination, withDestinationURL: URL(fileURLWithPath: uploadPath))
        }
        return destination.path
    }

    /// Moves an engine-written file under the results area and registers it under a fresh
    /// opaque `file_id`; keeps the last `resultsLimit` staged (spec §Files and staging).
    private func stageResultFile(at url: URL, mediaType: String) -> String {
        let fileID = "r-" + UUID().uuidString
        let destination = home.appendingPathComponent("staging/results/\(fileID)\(Self.pathExtension(forMediaType: mediaType))")
        try? FileManager.default.moveItem(at: url, to: destination)
        lock.lock()
        files[fileID] = StagedFile(url: destination, mediaType: mediaType)
        fileOrder.append(fileID)
        while fileOrder.count > resultsLimit {
            let evicted = fileOrder.removeFirst()
            if let staged = files.removeValue(forKey: evicted) {
                try? FileManager.default.removeItem(at: staged.url)
                for (jobID, job) in jobs where job.fileID == evicted {
                    jobs[jobID]?.fileID = nil
                    jobs[jobID]?.error = "evicted: the server keeps the last \(resultsLimit) results"
                }
            }
        }
        lock.unlock()
        return fileID
    }

    private func uploadPath(for handle: [String: Any]) -> String? {
        guard let hex = handle["upload"] as? String, hex.count >= 2 else { return nil }
        let path = home.appendingPathComponent("staging/uploads/\(hex.prefix(2))/\(hex)")
        return FileManager.default.fileExists(atPath: path.path) ? path.path : nil
    }

    /// A staged upload's size in GB, for the server-side memory backstop (a staged LoRA's
    /// matrices sit in memory beside the model, as large as its file).
    private func stagedUploadGigabytes(hex: String) -> Double {
        guard let path = uploadPath(for: ["upload": hex]) else { return 0 }
        let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Double(size) / 1_000_000_000
    }

    // MARK: - Helpers

    private func updateJob(_ id: String?, _ mutate: (inout Job) -> Void) {
        guard let id else { return }
        lock.lock()
        if jobs[id] != nil { mutate(&jobs[id]!) }
        lock.unlock()
    }

    /// A job left the engine (done, failed, cancelled): update the registry, release its
    /// upload references, sweep unreferenced uploads, and release keep-awake when nothing is
    /// running.
    private func finishJob(_ id: String?, status: String, error: String?, fileID: String? = nil) {
        guard let id else { return }
        var engine: ModelEngine?
        var wasActive = false
        lock.lock()
        if var job = jobs[id] {
            wasActive = job.status == "running" || job.status == "queued"
            job.status = status
            job.error = error
            if let fileID { job.fileID = fileID }
            jobs[id] = job
            engine = job.engine
            if wasActive {
                activeJobs = max(0, activeJobs - 1)
                keepAwake.isOn = activeJobs > 0
            }
            let hashes = jobUploads[id] ?? []
            jobUploads[id] = nil
            for hash in hashes { uploadRefs[hash, default: 1] -= 1 }
        }
        lock.unlock()
        if wasActive, let engine { router.noteJobFinished(engine) }
        sweepUploads()
        onChange?()
    }

    private func jobEngine(_ id: String) -> ModelEngine? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]?.engine
    }

    /// Deletes content-addressed uploads nothing references anymore and that have been on
    /// disk for over an hour (spec §Uploads: "eviction only when nothing references the hash").
    private func sweepUploads() {
        let uploads = home.appendingPathComponent("staging/uploads", isDirectory: true)
        let hourAgo = Date().addingTimeInterval(-3600)
        lock.lock()
        let referenced = Set(uploadRefs.keys)
        lock.unlock()
        guard let buckets = try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        for bucket in buckets {
            guard let files = try? FileManager.default.contentsOfDirectory(at: bucket, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { continue }
            for file in files {
                let hex = file.lastPathComponent
                if referenced.contains(hex) { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < hourAgo {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private func jobFamily(_ id: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]?.family ?? ""
    }

    private func fail(jobID: String?, message: String) {
        if let jobID, !jobID.isEmpty {
            updateJob(jobID) { $0.status = "failed"; $0.error = message }
            emit(jsonLine(["event": "failed", "id": jobID, "message": message]))
        } else {
            sendLog(message)
        }
        onChange?()
    }

    private func emit(_ line: String) {
        broadcast?(line)
    }

    private func deepCopy(_ value: Any?) -> Any? {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let copy = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return copy
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func mediaType(forFamily family: String) -> String {
        switch family {
        case "ltx-2", "ltx-2.5": return "video/mp4"
        case "minimax-music3", "moss-soundeffect": return "audio/wav"
        case "idol": return "model/gltf-binary"
        default: return "image/png"
        }
    }

    static func fileExtension(forFamily family: String) -> String {
        switch mediaType(forFamily: family) {
        case "video/mp4": return ".mp4"
        case "audio/wav": return ".wav"
        case "model/gltf-binary": return ".glb"
        default: return ".png"
        }
    }

    static func pathExtension(forMediaType mediaType: String) -> String {
        switch mediaType {
        case "video/mp4": return ".mp4"
        case "audio/wav": return ".wav"
        case "model/gltf-binary": return ".glb"
        default: return ".png"
        }
    }
}
