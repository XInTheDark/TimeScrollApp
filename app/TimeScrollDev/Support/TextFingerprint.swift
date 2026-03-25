import Foundation

struct TextFingerprint: Sendable, Hashable {
    let simHash: UInt64
    let normalizedCharacterCount: Int
    let normalizedLineCount: Int
    let normalizedTokenCount: Int

    static func make(from text: String) -> TextFingerprint {
        var accum = [Int](repeating: 0, count: 64)
        var charCount = 0
        var lineCount = 0
        var tokenCount = 0

        text.enumerateLines { rawLine, _ in
            let normalizedLine = normalizeSurface(line: rawLine)
            guard !normalizedLine.isEmpty else { return }

            lineCount += 1
            charCount += normalizedLine.count
            addFeature(hash: fnv1a64(normalizedLine),
                       weight: min(3, max(1, normalizedLine.count / 48 + 1)),
                       accum: &accum)

            let lexicalLine = normalizeLexical(line: rawLine)
            guard !lexicalLine.isEmpty else { return }

            let tokens = lexicalLine.split(separator: " ").map(String.init)
            tokenCount += tokens.count

            for token in tokens {
                addFeature(hash: fnv1a64(token),
                           weight: min(4, max(2, token.count / 12 + 2)),
                           accum: &accum)
            }

            if tokens.count > 1 {
                for index in 0..<(tokens.count - 1) {
                    addFeature(hash: fnv1a64(tokens[index] + "\u{1F}" + tokens[index + 1]),
                               weight: 3,
                               accum: &accum)
                }
            }

            let compactLexical = lexicalLine.replacingOccurrences(of: " ", with: "_")
            for gram in characterGrams(from: compactLexical) {
                addFeature(hash: fnv1a64(gram), weight: 1, accum: &accum)
            }
        }

        if lineCount == 0 {
            let normalizedLine = normalizeSurface(line: text)
            guard !normalizedLine.isEmpty else {
                return TextFingerprint(simHash: 0,
                                       normalizedCharacterCount: 0,
                                       normalizedLineCount: 0,
                                       normalizedTokenCount: 0)
            }
            charCount = normalizedLine.count
            lineCount = 1

            addFeature(hash: fnv1a64(normalizedLine), weight: 1, accum: &accum)
            let lexicalLine = normalizeLexical(line: text)
            if !lexicalLine.isEmpty {
                let tokens = lexicalLine.split(separator: " ").map(String.init)
                tokenCount = tokens.count
                for token in tokens {
                    addFeature(hash: fnv1a64(token), weight: 3, accum: &accum)
                }
                if tokens.count > 1 {
                    for index in 0..<(tokens.count - 1) {
                        addFeature(hash: fnv1a64(tokens[index] + "\u{1F}" + tokens[index + 1]),
                                   weight: 3,
                                   accum: &accum)
                    }
                }
                let compactLexical = lexicalLine.replacingOccurrences(of: " ", with: "_")
                for gram in characterGrams(from: compactLexical) {
                    addFeature(hash: fnv1a64(gram), weight: 1, accum: &accum)
                }
            }
        }

        var simHash: UInt64 = 0
        for bit in 0..<64 where accum[bit] >= 0 {
            simHash |= UInt64(1) << UInt64(bit)
        }
        return TextFingerprint(simHash: simHash,
                               normalizedCharacterCount: charCount,
                               normalizedLineCount: lineCount,
                               normalizedTokenCount: tokenCount)
    }

    func isNearDuplicate(of other: TextFingerprint) -> Bool {
        if normalizedCharacterCount == 0 && other.normalizedCharacterCount == 0 {
            return true
        }

        let maxChars = max(normalizedCharacterCount, other.normalizedCharacterCount)
        let charDelta = abs(normalizedCharacterCount - other.normalizedCharacterCount)
        let charLimit = max(120, Int(Double(maxChars) * 0.08))

        let maxLines = max(normalizedLineCount, other.normalizedLineCount)
        let lineDelta = abs(normalizedLineCount - other.normalizedLineCount)
        let lineLimit = max(2, Int(Double(maxLines) * 0.10))

        let maxTokens = max(normalizedTokenCount, other.normalizedTokenCount)
        let tokenDelta = abs(normalizedTokenCount - other.normalizedTokenCount)
        let tokenLimit = max(3, Int(Double(maxTokens) * 0.15))

        return charDelta <= charLimit
            && lineDelta <= lineLimit
            && tokenDelta <= tokenLimit
            && hammingDistance(to: other) <= 8
    }

    func hammingDistance(to other: TextFingerprint) -> Int {
        (simHash ^ other.simHash).nonzeroBitCount
    }
}

private extension TextFingerprint {
    static func normalizeSurface(line: String) -> String {
        let scalars = line.unicodeScalars.map { scalar -> UnicodeScalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : scalar
        }
        return String(String.UnicodeScalarView(scalars))
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeLexical(line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func characterGrams(from string: String) -> [String] {
        guard !string.isEmpty else { return [] }
        if string.count <= 4 {
            return [string]
        }

        let characters = Array(string)
        let step: Int
        switch characters.count {
        case ..<96:
            step = 1
        case ..<256:
            step = 2
        default:
            step = 4
        }

        var grams: [String] = []
        grams.reserveCapacity(min(64, max(1, (characters.count - 3) / step)))
        var index = 0
        while index + 4 <= characters.count {
            grams.append(String(characters[index..<(index + 4)]))
            if grams.count >= 64 { break }
            index += step
        }
        if let last = grams.last, last == String(characters.suffix(4)) {
            return grams
        }
        grams.append(String(characters.suffix(4)))
        return grams
    }

    static func addFeature(hash: UInt64, weight: Int, accum: inout [Int]) {
        for bit in 0..<64 {
            let bitMask = UInt64(1) << UInt64(bit)
            accum[bit] += (hash & bitMask) == 0 ? -weight : weight
        }
    }

    static func fnv1a64(_ string: String) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }
}
