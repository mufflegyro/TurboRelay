import Foundation

/// Resolves a catalog model id ("mflux-community/z-image-turbo-mflux-q4") to its snapshot
/// directory in the server's Hugging Face cache — the server-side half of amendment A2
/// (the wire never carries model paths; the server resolves them from its own cache).
/// M3 vendoring of turbo-mlx's ModelCatalog adds pinned revisions and companion
/// text-encoder resolution; this resolves plain cache layout so the bridge works now.
public struct ModelLocator {
    public let hub: URL

    public init(hub: URL) { self.hub = hub }

    public func resolve(_ id: String, revision: String? = nil) -> URL? {
        let dirName = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let snapshots = hub.appendingPathComponent(dirName).appendingPathComponent("snapshots")
        // The catalog pins a commit: use exactly that snapshot when it is on disk.
        if let revision, !revision.isEmpty, revision != "main" {
            let pinned = snapshots.appendingPathComponent(revision, isDirectory: true)
            if FileManager.default.fileExists(atPath: pinned.path) { return pinned }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: .skipsHiddenFiles))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
        let dates = entries.reduce(into: [:]) { result, url in
            result[url] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        guard let newest = entries.max(by: { dates[$0] ?? .distantPast < dates[$1] ?? .distantPast }) else { return nil }
        return newest
    }

    /// The complete snapshot of a repository, the pinned commit first and the newest one after
    /// (downloaded before the catalog named a commit, or by another tool).
    private func completeSnapshot(of repo: String, preferring revision: String?,
                                  where isComplete: (URL) -> Bool) -> URL? {
        let snapshots = hub
            .appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        if let revision, !revision.isEmpty, revision != "main" {
            let pinned = snapshots.appendingPathComponent(revision, isDirectory: true)
            if isComplete(pinned) { return pinned }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles))?
            .filter { (try? $0.resourceValues(forKeys: keys))?.isDirectory == true } ?? []
        let dates = entries.reduce(into: [:]) { result, url in
            result[url] = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
        }
        return entries.filter(isComplete).max { dates[$0] ?? .distantPast < dates[$1] ?? .distantPast }
    }

    /// A family's companion checkpoint — LTX-2.3's text encoder, Gemma 3 12B — as the catalog
    /// pins it. It is downloaded with the model and shared by the family; the client never
    /// sends its path either (A2), so the bridge adds `model.text_encoder_path` from here.
    func companionLocation(of family: ModelFamily) -> URL? {
        guard let companion = family.companion else { return nil }
        return completeSnapshot(of: companion.repo, preferring: companion.revision) {
            Self.hasFiles(companion.requiredFiles, in: $0)
        }
    }

    /// Whether the model's whole snapshot is on disk and complete (mirrors turbo-mlx's
    /// `ModelLocator.isComplete`: the catalog's required files, the tokenizer, every shard an
    /// index names, and a safetensors in every component). A partial or interrupted download
    /// must not count — the client's picker reads this to show "downloaded", and a seeding
    /// here has no other completeness signal.
    func complete(of id: String, family: ModelFamily, revision: String? = nil) -> Bool {
        guard let snapshot = resolve(id, revision: revision) else { return false }
        // A family whose text encoder is a companion checkpoint is not usable without it, as
        // the client's installedLocation has it. The picker then offers Download rather than
        // Ready, and since a download fetches only missing files, that backfills the companion
        // without re-fetching the weights.
        if family.companion != nil, companionLocation(of: family) == nil { return false }
        let fm = FileManager.default
        guard Self.hasFiles(family.requiredFiles, in: snapshot) else { return false }
        if let tokenizer = family.tokenizerFile,
           !fm.fileExists(atPath: snapshot.appending(path: tokenizer).path) {
            return false
        }
        guard Self.topLevelShardsPresent(in: snapshot) else { return false }
        return family.components.allSatisfy { component in
            let directory = snapshot.appending(path: component)
            guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
            let indexes = files.filter { $0.hasSuffix(".safetensors.index.json") }
            if indexes.isEmpty {
                return files.contains { $0.hasSuffix(".safetensors") && fm.fileExists(atPath: directory.appending(path: $0).path) }
            }
            return indexes.allSatisfy { index in
                guard let data = try? Data(contentsOf: directory.appending(path: index)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let weightMap = json["weight_map"] as? [String: String], !weightMap.isEmpty
                else { return false }
                return Set(weightMap.values).allSatisfy { fm.fileExists(atPath: directory.appending(path: $0).path) }
            }
        }
    }

    /// Every shard a top-level `.safetensors.index.json` names must be on disk too (Krea 2 keeps
    /// its transformer's shards at the checkpoint's root; SenseNova's whole pack is there).
    private static func topLevelShardsPresent(in folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        for index in files where index.hasSuffix(".safetensors.index.json") {
            guard let data = try? Data(contentsOf: folder.appending(path: index)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String], !weightMap.isEmpty
            else { return false }
            guard Set(weightMap.values).allSatisfy({ fileManager.fileExists(atPath: folder.appending(path: $0).path) }) else {
                return false
            }
        }
        return true
    }

    private static func hasFiles(_ names: [String], in folder: URL) -> Bool {
        let fileManager = FileManager.default
        var listings: [String: [String]] = [:]
        return names.allSatisfy { name in
            let parts = name.split(separator: "/").map(String.init)
            let directory = parts.dropLast().reduce(folder) { $0.appending(path: $1, directoryHint: .isDirectory) }
            let files = listings[directory.path] ?? ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            listings[directory.path] = files
            let regex = HubDownloader.regex(fnmatch: parts.last ?? name)
            return files.contains { file in
                regex.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)) != nil
                    && fileManager.fileExists(atPath: directory.appending(path: file).path)
            }
        }
    }
}
