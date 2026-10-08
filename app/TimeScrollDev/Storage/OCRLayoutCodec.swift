import Foundation
import CoreGraphics

/// Packs a snapshot's OCR lines (text + normalized bounding box) into one LZFSE-compressed blob,
/// replacing one database row per recognized line.
enum OCRLayoutCodec {
    private static let magic: [UInt8] = Array("OL1".utf8)

    static func encode(_ lines: [OCRLine]) -> Data? {
        guard !lines.isEmpty else { return nil }
        var raw = Data(magic)
        append(UInt32(lines.count), to: &raw)
        for line in lines {
            append(Float32(line.box.origin.x).bitPattern, to: &raw)
            append(Float32(line.box.origin.y).bitPattern, to: &raw)
            append(Float32(line.box.size.width).bitPattern, to: &raw)
            append(Float32(line.box.size.height).bitPattern, to: &raw)
            let text = Data(line.text.utf8)
            append(UInt32(text.count), to: &raw)
            raw.append(text)
        }
        return try? (raw as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ blob: Data) -> [DB.OCRBoxRow] {
        guard let raw = try? (blob as NSData).decompressed(using: .lzfse) as Data,
              raw.starts(with: magic) else { return [] }
        var reader = Reader(data: raw, offset: magic.count)
        guard let count = reader.uint32() else { return [] }
        var rows: [DB.OCRBoxRow] = []
        rows.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let x = reader.float(), let y = reader.float(), let w = reader.float(), let h = reader.float(),
                  let length = reader.uint32(), let text = reader.string(length: Int(length)) else { break }
            rows.append(DB.OCRBoxRow(text: text, rect: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))))
        }
        return rows
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .enumerated()
                .reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
            offset += 4
            return value
        }

        mutating func float() -> Float32? {
            uint32().map(Float32.init(bitPattern:))
        }

        mutating func string(length: Int) -> String? {
            guard length >= 0, offset + length <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += length
            return String(data: data[start ..< start + length], encoding: .utf8)
        }
    }
}
