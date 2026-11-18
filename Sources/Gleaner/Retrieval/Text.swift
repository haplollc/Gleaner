import Foundation

/// Tokenising for keyword search: lowercase words, a few stop words dropped, plurals folded.
enum Terms {
    static let stop: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "he", "her", "his", "i",
        "in", "is", "it", "its", "of", "on", "or", "she", "so", "that", "the", "their", "they", "this", "to", "was",
        "were", "will", "with", "you", "your", "my", "me", "we", "our", "do", "does", "did", "what", "which", "who",
    ]

    static func of(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let w = fold(word)
            if !stop.contains(w), w.count > 1 || w.first?.isNumber == true { out.append(w) }
            word = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { word.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// "shoes" and "shoe", "batteries" and "battery" meet in the middle. Crude on purpose.
    static func fold(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 4, w.hasSuffix("es"), w.dropLast(2).last.map({ "sxz".contains($0) }) == true || w.hasSuffix("ches") || w.hasSuffix("shes") { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }
}
