import Foundation

private struct MobileCLIPBytePair: Hashable {
    let a: String
    let b: String

    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }

    init(tuple: [String]) {
        self.a = tuple[0]
        self.b = tuple[1]
    }
}

final class MobileCLIPTokenizer {
    private let bpeRanks: [MobileCLIPBytePair: Int]
    private let encoder: [String: Int]
    private let decoder: [Int: String]
    private let byteEncoder: [UInt8: String]
    private let byteDecoder: [String: UInt8]
    let contextLength: Int

    init(tokenizerDirectoryURL: URL, contextLength: Int) throws {
        self.contextLength = contextLength

        let mergesURL = tokenizerDirectoryURL.appendingPathComponent("clip-merges.txt")
        let mergesText = try String(contentsOf: mergesURL)
        let mergeLines = mergesText.split(separator: "\n").map(String.init)
        var ranks: [MobileCLIPBytePair: Int] = [:]
        for index in 1..<mergeLines.count {
            let tuple = mergeLines[index].split(separator: " ").map(String.init)
            guard tuple.count == 2 else { continue }
            ranks[MobileCLIPBytePair(tuple: tuple)] = index - 1
        }
        bpeRanks = ranks

        let vocabURL = tokenizerDirectoryURL.appendingPathComponent("clip-vocab.json")
        let vocabData = try Data(contentsOf: vocabURL)
        encoder = try JSONDecoder().decode([String: Int].self, from: vocabData)
        decoder = Dictionary(uniqueKeysWithValues: encoder.map { ($1, $0) })

        byteEncoder = Self.makeByteEncoder()
        byteDecoder = Dictionary(uniqueKeysWithValues: byteEncoder.map { ($1, $0) })
    }

    func encodeFull(text: String) -> [Int32] {
        let startToken = Int32(encoder["<|startoftext|>"] ?? 49406)
        let endToken = Int32(encoder["<|endoftext|>"] ?? 49407)
        let usableCount = max(0, contextLength - 2)
        let tokenIDs = encode(text: text).prefix(usableCount)

        var full = Array(repeating: Int32(0), count: contextLength)
        guard !full.isEmpty else { return full }
        full[0] = startToken
        for (index, token) in tokenIDs.enumerated() {
            full[index + 1] = Int32(token)
        }
        let endIndex = min(tokenIDs.count + 1, max(0, contextLength - 1))
        full[endIndex] = endToken
        return full
    }

    func tokenCount(text: String) -> Int {
        encode(text: text).count
    }

    private func encode(text: String) -> [Int] {
        tokenize(text: text).compactMap { encoder[$0] }
    }

    private func tokenize(text: String) -> [String] {
        var tokens: [String] = []
        for token in byteEncode(text: text.lowercased()) {
            tokens.append(contentsOf: bpe(token: token).split(separator: " ").map(String.init))
        }
        return tokens
    }

    private func byteEncode(text: String) -> [String] {
        let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let token = String(text[swiftRange])
            return token.utf8.map { byteEncoder[$0] ?? "" }.joined()
        }
    }

    private func bpe(token: String) -> String {
        if token.count <= 1 {
            return token + "</w>"
        }

        var word = Array(token).map(String.init)
        let last = (word.last ?? "") + "</w>"
        word.removeLast()
        word.append(last)
        var pairs = Array(getPairs(word: word))
        if pairs.isEmpty {
            return token + "</w>"
        }

        while true {
            let rankedPairs = pairs.compactMap { pair in
                bpeRanks[pair].map { (pair, $0) }
            }
            guard let best = rankedPairs.min(by: { $0.1 < $1.1 })?.0 else { break }
            let first = best.a
            let second = best.b
            var merged: [String] = []
            var index = 0
            while index < word.count {
                if let nextIndex = word[index...].firstIndex(of: first) {
                    merged.append(contentsOf: word[index..<nextIndex])
                    index = nextIndex
                } else {
                    merged.append(contentsOf: word[index..<word.count])
                    break
                }

                if index < word.count - 1, word[index] == first, word[index + 1] == second {
                    merged.append(first + second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
            if word.count == 1 {
                break
            }
            pairs = Array(getPairs(word: word))
        }
        return word.joined(separator: " ")
    }

    private func getPairs(word: [String]) -> Set<MobileCLIPBytePair> {
        guard word.count > 1 else { return [] }
        var pairs = Set<MobileCLIPBytePair>()
        for index in 0..<(word.count - 1) {
            pairs.insert(MobileCLIPBytePair(word[index], word[index + 1]))
        }
        return pairs
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        var bytes: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for value in 0...255 where !bytes.contains(value) {
            bytes.append(value)
            scalars.append(256 + extra)
            extra += 1
        }

        var mapping: [UInt8: String] = [:]
        for (index, value) in bytes.enumerated() {
            let scalarValue = scalars[index]
            guard let scalar = UnicodeScalar(scalarValue) else { continue }
            mapping[UInt8(value)] = String(scalar)
        }
        return mapping
    }
}
