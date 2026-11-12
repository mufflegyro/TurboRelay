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

    /// Whether the model's whole snapshot is on disk and complete (mirrors turbo-mlx's
    /// `ModelLocator.isComplete`: the catalog's required files, the tokenizer, and a
    /// safetensors in every component). A partial or interrupted download must not count —
    /// the client's picker reads this to show "downloaded", and a seeding here has no other
    /// completeness signal.
    func complete(of id: String, family: ModelFamily, revision: String? = nil) -> Bool {
        guard let snapshot = resolve(id, revision: revision) else { return false }
        let fm = FileManager.default
        guard Self.hasFiles(family.requiredFiles, in: snapshot) else { return false }
        if let tokenizer = family.tokenizerFile,
           !fm.fileExists(atPath: snapshot.appending(path: tokenizer).path) {
            return false
        }
        return family.components.allSatisfy { component in
            let directory = snapshot.appending(path: component)
            guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
            return files.contains { $0.hasSuffix(".safetensors") && fm.fileExists(atPath: directory.appending(path: $0).path) }
        }
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
