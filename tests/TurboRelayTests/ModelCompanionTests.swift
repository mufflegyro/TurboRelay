import XCTest
@testable import TurboRelayCore

/// A2, server side: the client names no companion path, so the bridge resolves the family's
/// text encoder (LTX-2.3's Gemma 3 12B) from the cache the model was downloaded into.
final class ModelCompanionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(_ repo: String, _ commit: String, files: [String]) throws -> URL {
        let dir = root.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots").appendingPathComponent(commit)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    func testLTX2ResolvesThePinnedGemmaSnapshot() throws {
        let complete = try snapshot("mlx-community/gemma-3-12b-it-4bit", "86cc6a8dedbc456dd0e4af01a9d09f396f77e558",
                                    files: ["config.json", "tokenizer.json",
                                            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        let locator = ModelLocator(hub: root)
        XCTAssertEqual(locator.companionLocation(of: .ltx2)?.resolvingSymlinksInPath().path,
                       complete.resolvingSymlinksInPath().path)
    }

    func testAnIncompletePinnedSnapshotIsNotUsed() throws {
        // One shard missing: the engine would load half a text encoder and fail.
        _ = try snapshot("mlx-community/gemma-3-12b-it-4bit", "86cc6a8dedbc456dd0e4af01a9d09f396f77e558",
                         files: ["config.json", "tokenizer.json", "model-00001-of-00002.safetensors"])
        XCTAssertNil(ModelLocator(hub: root).companionLocation(of: .ltx2))
    }

    func testOlderCompleteSnapshotIsAPinnedFallback() throws {
        // Downloaded before the catalog pinned a commit, or by another tool.
        let older = try snapshot("mlx-community/gemma-3-12b-it-4bit", "aaaa1111",
                                 files: ["config.json", "tokenizer.json",
                                         "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        XCTAssertEqual(ModelLocator(hub: root).companionLocation(of: .ltx2)?.resolvingSymlinksInPath().path,
                       older.resolvingSymlinksInPath().path)
    }

    func testFamiliesWithoutACompanionResolveToNothing() {
        XCTAssertNil(ModelLocator(hub: root).companionLocation(of: .zImageTurbo))
        // LTX-2.5 carries its own text encoder.
        XCTAssertNil(ModelLocator(hub: root).companionLocation(of: .ltx25))
    }
}
