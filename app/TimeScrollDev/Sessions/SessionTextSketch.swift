import Foundation

/// A compact content fingerprint of one screen's text, used to tell whether nearby captures show
/// the same work. Words are lowercased and hashed; the sketch keeps the `capacity` smallest distinct
/// hashes (a bottom-k sample). Sampling by hash value is consistent: a word sampled from one screen
/// is sampled from every other screen that contains it, so overlapping screens share sketch entries.
enum SessionTextSketch {
  static let capacity = 64
  static let minTokenLength = 3
  static let maxTokenLength = 40

  /// Sorted ascending, at most `capacity` entries; empty when the text has no usable words.
  static func make(from text: String) -> [UInt32] {
    var hashes: [UInt32] = []
    hashes.reserveCapacity(256)
    forEachToken(in: text) { hash, _ in hashes.append(hash) }
    guard !hashes.isEmpty else { return [] }
    hashes.sort()
    var sketch: [UInt32] = []
    sketch.reserveCapacity(min(capacity, hashes.count))
    for hash in hashes where sketch.last != hash {
      sketch.append(hash)
      if sketch.count == capacity { break }
    }
    return sketch
  }

  static func encode(_ sketch: [UInt32]) -> Data {
    var data = Data(capacity: sketch.count * 4)
    for hash in sketch {
      var littleEndian = hash.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  static func decode(_ bytes: UnsafeRawBufferPointer) -> [UInt32] {
    let count = bytes.count / 4
    var sketch = [UInt32](repeating: 0, count: count)
    for index in 0..<count {
      sketch[index] = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
    }
    return sketch
  }

  static func decode(_ data: Data) -> [UInt32] {
    data.withUnsafeBytes { decode($0) }
  }

  /// Calls `body` with each word's hash and its range in `text`. Words are runs of letters and
  /// digits, 3–40 characters, at most 30% digits (drops times, counters and ids). Runs of CJK
  /// characters, written without spaces, yield overlapping two-character words instead.
  static func forEachToken(in text: String, _ body: (UInt32, Range<String.Index>) -> Void) {
    var hasher = TokenHasher()
    var start: String.Index?
    var previousCJK: (index: String.Index, scalar: Unicode.Scalar)?
    let scalars = text.unicodeScalars
    var index = scalars.startIndex

    func flush(at end: String.Index) {
      if let tokenStart = start, hasher.isAcceptable {
        body(hasher.value, tokenStart..<end)
      }
      start = nil
      hasher = TokenHasher()
    }

    while index < scalars.endIndex {
      let scalar = scalars[index]
      let next = scalars.index(after: index)
      if isCJK(scalar) {
        flush(at: index)
        if let previous = previousCJK {
          var pair = TokenHasher()
          pair.add(previous.scalar)
          pair.add(scalar)
          body(pair.value, previous.index..<next)
        }
        previousCJK = (index, scalar)
      } else {
        previousCJK = nil
        if isWordScalar(scalar) {
          if start == nil { start = index }
          hasher.add(scalar)
        } else {
          flush(at: index)
        }
      }
      index = next
    }
    flush(at: scalars.endIndex)
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.isASCII {
      let v = scalar.value
      return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }
    return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, // Hiragana, Katakana
         0x3400...0x4DBF, // CJK Extension A
         0x4E00...0x9FFF, // CJK Unified Ideographs
         0xAC00...0xD7AF, // Hangul syllables
         0xF900...0xFAFF: // CJK Compatibility Ideographs
      return true
    default:
      return false
    }
  }
}

/// FNV-1a over the lowercased UTF-8 of one word, built a scalar at a time.
private struct TokenHasher {
  private(set) var value: UInt32 = 2_166_136_261
  private var length = 0
  private var digits = 0

  var isAcceptable: Bool {
    length >= SessionTextSketch.minTokenLength
      && length <= SessionTextSketch.maxTokenLength
      && digits * 10 <= length * 3
  }

  mutating func add(_ scalar: Unicode.Scalar) {
    length += 1
    if scalar.isASCII {
      var v = UInt8(scalar.value)
      if v >= 0x30 && v <= 0x39 { digits += 1 }
      if v >= 0x41 && v <= 0x5A { v += 0x20 }
      mix(v)
      return
    }
    if scalar.properties.numericType != nil { digits += 1 }
    for lowered in scalar.properties.lowercaseMapping.unicodeScalars {
      for byte in UTF8.encode(lowered)! { mix(byte) }
    }
  }

  private mutating func mix(_ byte: UInt8) {
    value ^= UInt32(byte)
    value = value &* 16_777_619
  }
}
