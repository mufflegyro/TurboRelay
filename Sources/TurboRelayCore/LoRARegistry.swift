import Foundation

/// The LoRAs the relay has seen, kept as a small library so another client can import one
/// (docs/remote-protocol.md §LoRAs). Uploads are content-addressed: the library hardlinks the
/// bytes under `loras/<sha256>.safetensors`, so the entry outlives the staging upload the job
/// used and the render Mac never holds a second copy on the same volume.
public final class LoRARegistry: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public var name: String
        public var bytes: Int64
        public var family: String?
        public var addedAt: Date
    }

    private let home: URL
    private let library: URL
    private let store: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(home: URL) {
        self.home = home
        library = home.appendingPathComponent("loras", isDirectory: true)
        store = home.appendingPathComponent("loras.json")
        entries = Self.load(store)
        // A file removed by hand drops its entry rather than leaving a dead listing.
        entries = entries.filter {
            FileManager.default.fileExists(atPath: library.appendingPathComponent("\($0.key).safetensors").path)
        }
        backfillStaging()
    }

    /// Registers an upload a job used: the staging upload may be swept, the library keeps the
    /// bytes. A later job with the real filename replaces a bare-hash one; the family is a hint
    /// for the client's list (the client reads the file's own keys when it imports it).
    public func register(id: String, name: String, family: String?, upload: URL) {
        guard Self.isHex64(id) else { return }
        let clean = Self.safeName(name, id: id)
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = destination(id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.linkItem(at: upload, to: destination)
            } catch {
                try? FileManager.default.copyItem(at: upload, to: destination)
            }
        }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if var entry = entries[id] {
            if entry.name.hasPrefix(id), !clean.hasPrefix(id) { entry.name = clean }
            if entry.family == nil { entry.family = family }
            entry.bytes = bytes
            entries[id] = entry
        } else {
            entries[id] = Entry(id: id, name: clean, bytes: bytes, family: family, addedAt: Date())
        }
        save()
    }

    /// Every library entry, newest first.
    public func list() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { $0.addedAt > $1.addedAt }
    }

    public func view() -> [[String: Any]] {
        list().map { entry in
            var object: [String: Any] = [
                "id": entry.id,
                "name": entry.name,
                "bytes": entry.bytes,
                "added_at": entry.addedAt.timeIntervalSince1970,
            ]
            if let family = entry.family { object["family"] = family }
            return object
        }
    }

    /// The library file for a listed id, nil for an id the library does not have (or whose file
    /// has been removed).
    public func fileURL(_ id: String) -> URL? {
        guard Self.isHex64(id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard entries[id] != nil else { return nil }
        let url = destination(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The name a client sees, safe as a file name on import: the last path component, no control
    /// characters, not hidden, and always `.safetensors`.
    private static func safeName(_ raw: String, id: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.components(separatedBy: CharacterSet.controlCharacters).joined()
        if name.isEmpty || name == "." || name == ".." { name = id }
        if name.hasPrefix(".") { name = "LoRA-" + String(name.dropFirst()) }
        let stem = (name as NSString).deletingPathExtension
        let suffix = ".safetensors"
        let room = max(1, 180 - suffix.count)
        return String(stem.prefix(room)).trimmingCharacters(in: .whitespaces) + suffix
    }

    private func destination(_ id: String) -> URL {
        library.appendingPathComponent("\(id).safetensors")
    }

    /// Uploads a job used before this library existed are still under `staging/loras` as
    /// `<sha256>-<name>.safetensors` symlinks (while the staging blob survives): adopt them, so
    /// the LoRA a client just used is listed without another job.
    private func backfillStaging() {
        let dir = home.appendingPathComponent("staging/loras", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "safetensors" {
            let base = file.lastPathComponent
            guard let dash = base.firstIndex(of: "-") else { continue }
            let id = String(base[..<dash])
            guard Self.isHex64(id) else { continue }
            let name = String(base[base.index(after: dash)...])
            let resolved = file.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            register(id: id, name: name, family: nil, upload: resolved)
        }
    }

    private static func isHex64(_ string: String) -> Bool {
        string.count == 64 && string.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func load(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        let list = entries.values.sorted { $0.addedAt < $1.addedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: store, options: .atomic)
    }
}
