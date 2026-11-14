import Foundation

/// Owns model downloads on the server: the catalog's per-model state (not-downloaded /
/// downloading / downloaded / failed), one download at a time, byte progress, a disk-space
/// pre-check with a readable refusal, keep-awake while work runs, and resume of interrupted
/// transfers (the vendored HubDownloader keeps the partial bytes). M3 of
/// TurboRelay/docs/remote-protocol.md: downloads must be flawless before generation.
/// With `quality`, downloads a family's Quality-mode files on top of the base model (LTX-2's
/// dev transformer) — M4's remote-Quality support.
public final class DownloadManager: @unchecked Sendable {
    public enum State: Equatable {
        case notDownloaded
        case downloading(bytes: Int64, total: Int64)
        case downloaded
        case failed(String)
    }

    struct Entry {
        var descriptor: ModelDescriptor
        var companion: ModelFamily.Companion?
        var state: State = .notDownloaded
        /// Whether the family has a Quality mode's files at all (LTX-2: the dev transformer).
        var familyHasQualityFiles: Bool = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]   // keyed by model id (the repo)
    /// Per-model Quality-mode download state, for families with `qualityFiles` (LTX-2).
    private var qualityStates: [String: String] = [:]
    private var runningTask: Task<Void, Never>?
    private var runningID: String?
    private let keepAwake = KeepAwake(reason: "TurboRelay is downloading a model")

    private let hubCache: URL
    private let locator: ModelLocator
    private let baseURL: URL
    private let token: String?
    /// Where descriptors of client-added (non-built-in) models are kept across restarts.
    private let customStore: URL?
    /// Set by the service: every state change and progress tick lands on the wire.
    public var onEvent: ((_ modelID: String, _ status: String, _ bytes: Int64, _ total: Int64, _ message: String?) -> Void)?
    public var onChange: (() -> Void)?

    /// Injected for tests; nil in production (the volume's real free space decides).
    var freeSpaceOverride: Int64?

    public init(hubCache: URL, baseURL: URL = URL(string: "https://huggingface.co")!, token: String?,
                customStore: URL? = nil) {
        self.hubCache = hubCache
        self.locator = ModelLocator(hub: hubCache)
        self.baseURL = baseURL
        self.token = token
        self.customStore = customStore
        for descriptor in ModelCatalog.builtIn where descriptor.repo != nil {
            entries[descriptor.id] = Entry(descriptor: descriptor, companion: descriptor.family.companion,
                                           familyHasQualityFiles: !descriptor.family.qualityFiles.isEmpty)
        }
        // Models added by hand on the client (a custom repository): the relay keeps the
        // descriptors it was asked to download, so they survive a restart and stay in
        // /models — the client's picker keys off that listing.
        for descriptor in Self.loadCustom(customStore) where entries[descriptor.id] == nil {
            entries[descriptor.id] = Entry(descriptor: descriptor, companion: descriptor.family.companion,
                                           familyHasQualityFiles: !descriptor.family.qualityFiles.isEmpty)
        }
        // A model already fully downloaded on this server (a previous session, or the
        // user's own cache) must not report "not downloaded": the client's picker keys off
        // this state. The completeness check needs every file the catalog wants, so a
        // partial or interrupted download stays "not downloaded" (a re-download resumes).
        for entry in entries.values {
            let descriptor = entry.descriptor
            if locator.complete(of: descriptor.id, family: descriptor.family, revision: descriptor.revision ?? "main") {
                entries[descriptor.id]?.state = .downloaded
            }
        }
    }

    /// Registers a model the built-in catalog does not ship (the client sent its descriptor
    /// with the download request). Returns the id; a known model keeps its own descriptor.
    @discardableResult
    func register(_ descriptor: ModelDescriptor) -> String {
        lock.lock()
        defer { lock.unlock() }
        if entries[descriptor.id] == nil {
            entries[descriptor.id] = Entry(descriptor: descriptor, companion: descriptor.family.companion,
                                           familyHasQualityFiles: !descriptor.family.qualityFiles.isEmpty)
            if locator.complete(of: descriptor.id, family: descriptor.family,
                                revision: descriptor.revision ?? "main") {
                entries[descriptor.id]?.state = .downloaded
            }
            Self.saveCustom(customStore, descriptors: entries.values.filter { !$0.descriptor.isBuiltIn }.map(\.descriptor))
        }
        return descriptor.id
    }

    // MARK: Custom descriptors (client-added models)

    private static func loadCustom(_ url: URL?) -> [ModelDescriptor] {
        guard let url, let data = try? Data(contentsOf: url),
              let descriptors = try? JSONDecoder().decode([ModelDescriptor].self, from: data)
        else { return [] }
        return descriptors.filter { $0.repo != nil }
    }

    private static func saveCustom(_ url: URL?, descriptors: [ModelDescriptor]) {
        guard let url, let data = try? JSONEncoder().encode(descriptors) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - /models

    public func modelsView() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        // Built-ins in catalog order, then any client-added models (sorted by id) after.
        let builtIns = ModelCatalog.builtIn.compactMap { entries[$0.id] }
        let custom = entries.values
            .filter { !$0.descriptor.isBuiltIn }
            .sorted { $0.descriptor.id < $1.descriptor.id }
        return (builtIns + custom).compactMap { entry in
            let descriptor = entry.descriptor
            var view: [String: Any] = [
                "id": descriptor.id,
                "family": descriptor.family.rawValue,
                "name": descriptor.name,
                "min_ram_gb": descriptor.recommendedMemoryGB ?? 0,
                "download_gb": Double(descriptor.sizeBytes ?? 0) / 1_000_000_000,
                "media": descriptor.family.media.rawValue,
                "engine": descriptor.family.engine.rawValue,
            ]
            switch entry.state {
            case .notDownloaded:
                view["state"] = "not-downloaded"
            case .downloading(let bytes, let total):
                view["state"] = "downloading"
                view["bytes_done"] = bytes
                view["bytes_total"] = total
            case .downloaded:
                view["state"] = "downloaded"
            case .failed(let message):
                view["state"] = "failed"
                view["error"] = message
            }
            if entry.familyHasQualityFiles {
                view["quality_state"] = qualityStates[descriptor.id] ?? "not-downloaded"
            }
            return view
        }
    }

    public func state(_ id: String) -> State {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.state ?? .notDownloaded
    }

    public func isDownloaded(_ id: String) -> Bool {
        if case .downloaded = state(id) { return true }
        return false
    }

    func descriptor(_ id: String) -> ModelDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.descriptor
    }

    /// `downloads` for the hello handshake.
    public func helloDownloads() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var downloads: [String: String] = [:]
        for (id, entry) in entries {
            switch entry.state {
            case .notDownloaded: continue
            case .downloading: downloads[id] = "downloading"
            case .downloaded: downloads[id] = "downloaded"
            case .failed: downloads[id] = "failed"
            }
        }
        return downloads
    }

    // MARK: - Commands

    /// Downloads a model (or, with `quality`, the Quality mode's files of an already
    /// downloaded LTX-2 model — the dev transformer, M4's remote-Quality support).
    public func start(_ id: String, quality: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else {
            return "no such model in the catalog"
        }
        if runningID != nil {
            return "a download is already running; cancel it first"
        }
        if quality {
            guard entry.familyHasQualityFiles else {
                return "this model has no Quality mode"
            }
            if qualityStates[id] == "downloaded" {
                return nil // already there: idempotent
            }
            guard case .downloaded = entry.state else {
                return "download the model itself before its Quality files"
            }
        } else {
            if case .downloaded = entry.state { return nil }
            if case .downloading = entry.state { return nil }
        }
        let descriptor = entry.descriptor
        keepAwake.isOn = true
        runningID = id
        runningTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(descriptor: descriptor, quality: quality)
        }
        return nil
    }

    public func cancel(_ id: String) {
        lock.lock()
        let isRunning = runningID == id
        lock.unlock()
        guard isRunning else { return }
        runningTask?.cancel()
    }

    // MARK: - The download itself

    private func run(descriptor: ModelDescriptor, quality: Bool) async {
        if quality {
            await runQualityFiles(descriptor: descriptor)
        } else {
            await runBase(descriptor: descriptor)
        }
    }

    /// The base model download: the family's `downloadPatterns`, with the companion
    /// checkpoint for the families that have one, into the Hugging Face cache.
    private func runBase(descriptor: ModelDescriptor) async {
        let id = descriptor.id
        guard let repo = descriptor.repo else {
            setFailed(id: id, message: "\(id) is not a Hugging Face model.")
            return
        }
        let downloader = HubDownloader(repo: repo, hubCache: hubCache, revision: descriptor.revision ?? "main",
                                       baseURL: baseURL, token: token)
        do {
            let listing = try await downloader.list(matching: descriptor.family.downloadPatterns)
            try checkDiskSpace(missing: downloader.bytesMissing(from: listing))
            let snapshot = try await downloader.download(listing) { [weak self] bytes in
                self?.report(id, bytes, listing.totalBytes)
            }
            if let companion = descriptor.family.companion {
                let companionRepo = companion.repo
                let companionDownloader = HubDownloader(repo: companionRepo, hubCache: hubCache,
                                                        revision: companion.revision ?? "main",
                                                        baseURL: baseURL, token: token)
                let companionListing = try await companionDownloader.list(matching: companion.patterns)
                try checkDiskSpace(missing: companionDownloader.bytesMissing(from: companionListing))
                _ = try await companionDownloader.download(companionListing) { [weak self] bytes in
                    self?.report(id, listing.totalBytes + bytes, listing.totalBytes + companionListing.totalBytes)
                }
            }
            finish(id, status: "downloaded", total: listing.totalBytes)
        } catch is CancellationError {
            cancelled(id)
        } catch {
            if Task.isCancelled {
                cancelled(id)
            } else {
                setFailed(id: id, message: error.localizedDescription)
            }
        }
    }

    /// The Quality-mode files (LTX-2's dev transformer) download on top of a model that is
    /// already there, into the same cache; their state is tracked beside the base's.
    private func runQualityFiles(descriptor: ModelDescriptor) async {
        let id = descriptor.id
        guard let repo = descriptor.repo else {
            failDownload(id: id, message: "\(id) is not a Hugging Face model.")
            return
        }
        let downloader = HubDownloader(repo: repo, hubCache: hubCache, revision: descriptor.revision ?? "main",
                                       baseURL: baseURL, token: token)
        do {
            let listing = try await downloader.list(matching: descriptor.family.qualityFiles)
            try checkDiskSpace(missing: downloader.bytesMissing(from: listing))
            qualityStates[id] = "downloading"
            onEvent?(id, "downloading", 0, listing.totalBytes, nil)
            onChange?()
            _ = try await downloader.download(listing) { [weak self] bytes in
                self?.report(id, bytes, listing.totalBytes)
            }
            lock.lock()
            qualityStates[id] = "downloaded"
            lock.unlock()
            onEvent?(id, "downloaded", listing.totalBytes, listing.totalBytes, nil)
            onChange?()
        } catch is CancellationError {
            qualityStates[id] = "not-downloaded"
            onEvent?(id, "cancelled", 0, 0, nil)
            onChange?()
        } catch {
            if Task.isCancelled {
                qualityStates[id] = "not-downloaded"
                onEvent?(id, "cancelled", 0, 0, nil)
            } else {
                qualityStates[id] = "failed"
                onEvent?(id, "failed", 0, 0, error.localizedDescription)
            }
            onChange?()
        }
        keepAwake.isOn = false
    }

    // MARK: - Shared pieces

    private func checkDiskSpace(missing: Int64) throws {
        if let free = freeSpaceOverride {
            if missing > free {
                throw RelayDiskError(message: "Not enough disk space: the download needs \(Self.gigabytes(missing)) GB free, and the server reports \(Self.gigabytes(free)) GB.")
            }
            return
        }
        let values = try? hubCache.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let free = values?.volumeAvailableCapacity, missing > Int64(free) {
            throw RelayDiskError(message: "Not enough disk space: the download needs \(Self.gigabytes(missing)) GB free, and the volume has \(Self.gigabytes(Int64(free))) GB. Free up space or move the cache (Settings → Models on the client).")
        }
    }

    private func cancelled(_ id: String) {
        lock.lock()
        entries[id]?.state = .notDownloaded
        runningID = nil
        runningTask = nil
        lock.unlock()
        keepAwake.isOn = false
        onEvent?(id, "cancelled", 0, 0, nil)
        onChange?()
    }

    private func setFailed(id: String, message: String) {
        lock.lock()
        entries[id]?.state = .failed(message)
        runningID = nil
        runningTask = nil
        lock.unlock()
        keepAwake.isOn = false
        onEvent?(id, "failed", 0, 0, message)
        onChange?()
    }

    private func failDownload(id: String, message: String) {
        lock.lock()
        qualityStates[id] = "failed"
        runningID = nil
        runningTask = nil
        lock.unlock()
        keepAwake.isOn = false
        onEvent?(id, "failed", 0, 0, message)
        onChange?()
    }

    private func finish(_ id: String, status: String, total: Int64) {
        lock.lock()
        entries[id]?.state = .downloaded
        runningID = nil
        runningTask = nil
        lock.unlock()
        keepAwake.isOn = false
        onEvent?(id, status, total, total, nil)
        onChange?()
    }

    private func report(_ id: String, _ bytes: Int64, _ total: Int64) {
        lock.lock()
        entries[id]?.state = .downloading(bytes: bytes, total: total)
        lock.unlock()
        onEvent?(id, "downloading", bytes, total, nil)
        onChange?()
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }
}

/// A refused download: the disk cannot hold what is still missing (spec §Error model).
/// A refused download: the disk cannot hold what is still missing (spec §Error model).
struct RelayDiskError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

