import Foundation

/// Vendored alongside ModelCatalog.swift from turbo-mlx (TurboMLX/Models/HistoryItem.swift):
/// the one external type the catalog needs. Kept identical so the client and server agree.
nonisolated enum MediaKind: String, Codable, Hashable, Sendable {
    case image
    case video
    /// A 3D object (Idol): a GLB, with a PNG still the app draws of it.
    case model3D = "model3d"
    /// A song (MiniMax-Music3) or a sound effect (MOSS-SoundEffect): a WAV, with a PNG of its waveform the app draws.
    case audio
}
