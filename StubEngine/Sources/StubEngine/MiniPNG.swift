import Foundation

// A minimal PNG writer: 8-bit grayscale, no dependencies, deterministic output. The stub
// engine's previews and results are tiny pictures of a pattern derived from the seed and
// step, so conformance runs never download a model and never differ between machines.

enum MiniPNG {
    static func write(width: Int, height: Int, seed: Int, step: Int, to url: URL) {
        var raw = Data()
        raw.reserveCapacity(height * (1 + width))
        for y in 0..<height {
            raw.append(0) // filter type: none
            for x in 0..<width {
                let value = (seed &+ step &* 97 &+ x &* 31 &+ y &* 17) & 0xFF
                raw.append(UInt8(value))
            }
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        appendBE32(&ihdr, width)
        appendBE32(&ihdr, height)
        ihdr.append(contentsOf: [8, 0, 0, 0, 0]) // 8-bit grayscale, no compression/filter/interlace customizations
        append(&png, type: "IHDR", data: ihdr)
        append(&png, type: "IDAT", data: zlibStored(raw))
        append(&png, type: "IEND", data: Data())
        try? png.write(to: url)
    }

    // MARK: - Pieces

    private static func append(_ png: inout Data, type: String, data: Data) {
        let typeData = Data(type.utf8)
        appendBE32(&png, data.count)
        png.append(typeData)
        png.append(data)
        appendBE32(&png, Int(crc32(typeData + data)))
    }

    private static func appendBE32(_ data: inout Data, _ value: Int) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// zlib stream of `raw` using stored (uncompressed) deflate blocks.
    private static func zlibStored(_ raw: Data) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        while offset < raw.count {
            let length = min(65535, raw.count - offset)
            let isLast = offset + length >= raw.count
            out.append(isLast ? 0x01 : 0x00)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(raw.subdata(in: offset..<(offset + length)))
            offset += length
        }
        appendBE32(&out, Int(adler32(raw)))
        return out
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
