import Foundation

/// Vendored alongside ModelCatalog.swift and MemoryEstimate.swift from turbo-mlx
/// (TurboMLX/Models/GenerationSettings.swift): the one other type the memory estimate needs.
nonisolated struct PixelSize: Hashable, Codable, Sendable {
    var width: Int
    var height: Int

    var megapixels: Double { Double(width * height) / 1_000_000 }
}
