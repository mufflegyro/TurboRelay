import Foundation
import Security

/// Where TurboRelay keeps its config, pairing token and staging area. `TURBORELAY_HOME`
/// overrides the location (the conformance and e2e tests set it to a temp dir), the way
/// turbo-mlx's `TURBO_MLX_HOME` works.
public enum RelayHome {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["TURBORELAY_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TurboRelay", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectories() -> URL {
        let root = root
        for sub in ["", "staging/results", "staging/uploads", "logs"] where !sub.isEmpty || true {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }
}

public struct RelayConfig {
    public var port: Int
    public var token: String
    /// Explicit engine binary; empty = bundle lookup (turbo-engine, then StubEngine).
    public var enginePath: String
    /// The Hugging Face hub directory models resolve against; empty = `~/.cache/huggingface/hub`.
    public var modelRoot: String
    /// A Hugging Face token for gated repositories (FLUX 3); empty = none. A8: the server's
    /// own token, injected into the vendored downloader — never a client-side static.
    public var hfToken: String
    /// The hub's base URL; empty = huggingface.co. The e2e tests point it at a local mock.
    public var hubBaseURL: String
    /// Extra arguments after `serve` (e.g. the stub's `--delay-ready-ms` in tests).
    public var engineArgs: [String]

    public static func load(home: URL) -> RelayConfig {
        let file = home.appendingPathComponent("config.json")
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var config = RelayConfig(
            port: (object["port"] as? Int) ?? 7700,
            token: object["token"] as? String ?? "",
            enginePath: object["engine_path"] as? String ?? "",
            modelRoot: object["model_root"] as? String ?? "",
            hfToken: object["hf_token"] as? String ?? "",
            hubBaseURL: object["hub_base_url"] as? String ?? "",
            engineArgs: object["engine_args"] as? [String] ?? []
        )
        if config.token.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            config.token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "port": config.port, "token": config.token,
            "engine_path": config.enginePath, "model_root": config.modelRoot,
            "hf_token": config.hfToken, "hub_base_url": config.hubBaseURL,
            "engine_args": config.engineArgs,
        ], options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return config
    }

    public var modelRootURL: URL {
        modelRoot.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            : URL(fileURLWithPath: (modelRoot as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var stagingURL: URL { RelayHome.root.appendingPathComponent("staging", isDirectory: true) }
    public var resultsURL: URL { stagingURL.appendingPathComponent("results", isDirectory: true) }
    public var uploadsURL: URL { stagingURL.appendingPathComponent("uploads", isDirectory: true) }
}
