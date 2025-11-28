import Foundation

extension String {
    /// Calculates the Jaccard similarity coefficient between this string and another string.
    /// Uses character bigrams for set generation.
    /// Returns a value between 0.0 (no similarity) and 1.0 (identical).
    func jaccardSimilarity(to other: String) -> Double {
        if self.isEmpty && other.isEmpty { return 1.0 }
        if self.isEmpty || other.isEmpty { return 0.0 }
        
        let s1 = self.bigrams()
        let s2 = other.bigrams()
        
        let intersection = s1.intersection(s2)
        let union = s1.union(s2)
        
        if union.isEmpty { return 0.0 }
        
        return Double(intersection.count) / Double(union.count)
    }
    
    private func bigrams() -> Set<String> {
        var bigrams = Set<String>()
        let chars = Array(self)
        if chars.count < 2 { return bigrams }
        
        for i in 0..<(chars.count - 1) {
            let bigram = String(chars[i]) + String(chars[i+1])
            bigrams.insert(bigram)
        }
        return bigrams
    }
}
