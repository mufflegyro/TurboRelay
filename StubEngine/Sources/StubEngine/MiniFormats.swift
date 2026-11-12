import Foundation

/// Minimal but well-formed media files for the stub's non-image outputs: a tiny MP4, a
/// proper RIFF/WAVE, and a GLB container. Magic bytes and box/chunk structure are real, so
/// the wire tests can assert the formats the bridge declares in `done.media_type`.

enum MiniFormats {
    // MARK: - MP4 (H.264-ish container: ftyp + mdat, no playable tracks)

    static func writeMP4(seed: Int, frames: Int, to url: URL) {
        var payload = Data()
        // ftyp box: major brand "isom", minor version, compatible brands.
        appendBox(&payload, type: "ftyp", body: Data("isom".utf8) + Data([0, 0, 2, 0]) + Data("isomiso2avc1mp41".utf8))
        // mdat: the "frames" as deterministic bytes.
        var media = Data()
        for frame in 0..<max(frames, 1) {
            media.append(contentsOf: (0..<64).map { UInt8((seed &+ frame &* 13 &+ $0) & 0xFF) })
        }
        appendBox(&payload, type: "mdat", body: media)
        try? payload.write(to: url)
    }

    static func isMP4(_ data: Data) -> Bool {
        data.count > 12 && data.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    // MARK: - WAV (RIFF/WAVE, 16-bit mono PCM)

    static func writeWAV(seed: Int, seconds: Double, sampleRate: Int = 8000, to url: URL) {
        let sampleCount = max(Int(Double(sampleRate) * seconds), sampleRate / 10)
        var samples = Data()
        for index in 0..<sampleCount {
            let value = Int16(truncatingIfNeeded: (seed &+ index) &* 257)
            samples.append(Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]))
        }
        var out = Data("RIFF".utf8)
        appendLE32(&out, 36 + 8 + samples.count)
        out.append(Data("WAVE".utf8))
        // fmt chunk
        out.append(Data("fmt ".utf8))
        appendLE32(&out, 16)
        appendLE16(&out, 1)             // PCM
        appendLE16(&out, 1)             // mono
        appendLE32(&out, sampleRate)
        appendLE32(&out, sampleRate * 2) // byte rate
        appendLE16(&out, 2)             // block align
        appendLE16(&out, 16)            // bits per sample
        // data chunk
        out.append(Data("data".utf8))
        appendLE32(&out, samples.count)
        out.append(samples)
        try? out.write(to: url)
    }

    static func isWAV(_ data: Data) -> Bool {
        data.count > 44 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WAVE".utf8)
    }

    // MARK: - GLB (glTF binary container)

    static func writeGLB(seed: Int, gaussians: Int, to url: URL) {
        var json = "{\"asset\":{\"version\":\"2.0\"},\"extras\":{\"gaussians\":\(gaussians),\"seed\":\(seed)}}"
        while json.count % 4 != 0 { json += " " }
        let jsonBytes = Data(json.utf8)
        var out = Data("glTF".utf8)
        appendLE32(&out, 2) // version
        appendLE32(&out, 12 + 8 + jsonBytes.count)
        // JSON chunk
        appendLE32(&out, jsonBytes.count)
        out.append(Data("JSON".utf8))
        out.append(jsonBytes)
        try? out.write(to: url)
    }

    static func isGLB(_ data: Data) -> Bool {
        data.prefix(4) == Data("glTF".utf8)
    }

    // MARK: - Pieces

    private static func appendLE32(_ data: inout Data, _ value: Int) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendLE16(_ data: inout Data, _ value: Int) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendBox(_ data: inout Data, type: String, body: Data) {
        appendLE32(&data, body.count + 8)
        data.append(Data(type.utf8))
        data.append(body)
    }
}
