import Foundation
import NaturalLanguage

/// A group of records that fit one call.
public struct Chunk: Sendable, Equatable {
    /// Positions of the records in the original array.
    public var indices: [Int]
    public var texts: [String]
    /// Estimated tokens of the numbered lines.
    public var tokens: Int
    /// True when a record was cut to fit.
    public var truncated: Bool

    /// The records as numbered lines, the way they go into a prompt.
    public var numbered: String { Chunker.numbered(texts) }
}

/// Packs records and text into chunks that fit a token budget. Pure and deterministic.
public enum Chunker {
    /// Tokens a numbered line adds on top of its text ("12. " and a newline).
    public static let lineOverhead = 4

    public static func numbered(_ texts: [String], startingAt start: Int = 1) -> String {
        texts.enumerated().map { "\($0.offset + start). \($0.element)" }.joined(separator: "\n")
    }

    /// Greedy in-order packing: each chunk takes records until the next one would overflow `budget`.
    /// A single record larger than the budget is cut to fit and flagged, never dropped.
    public static func pack(
        _ records: [String], budget: Int, estimator: TokenEstimator, maxRecords: Int? = nil
    ) -> [Chunk] {
        guard budget > 0 else { return [] }
        var chunks: [Chunk] = []
        var current = Chunk(indices: [], texts: [], tokens: 0, truncated: false)
        func flush() {
            if !current.texts.isEmpty { chunks.append(current) }
            current = Chunk(indices: [], texts: [], tokens: 0, truncated: false)
        }
        for (i, original) in records.enumerated() {
            var text = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var cost = estimator.tokens(text) + lineOverhead
            var cut = false
            if cost > budget {
                text = estimator.truncate(text, toTokens: max(1, budget - lineOverhead))
                cost = min(budget, estimator.tokens(text) + lineOverhead)
                cut = true
            }
            if !current.texts.isEmpty, current.tokens + cost > budget || (maxRecords.map { current.texts.count >= $0 } ?? false) {
                flush()
            }
            current.indices.append(i)
            current.texts.append(text)
            current.tokens += cost
            current.truncated = current.truncated || cut
        }
        flush()
        return chunks
    }

    /// Splits a chunk's records in two halves (for split-and-retry). A one-record chunk cannot be split.
    public static func halves(of chunk: Chunk) -> [Chunk]? {
        guard chunk.texts.count > 1 else { return nil }
        let mid = chunk.texts.count / 2
        func part(_ range: Range<Int>) -> Chunk {
            let texts = Array(chunk.texts[range])
            let share = chunk.tokens * texts.count / chunk.texts.count
            return Chunk(indices: Array(chunk.indices[range]), texts: texts, tokens: share, truncated: chunk.truncated)
        }
        return [part(0..<mid), part(mid..<chunk.texts.count)]
    }

    /// Splits one long text into pieces of at most `budget` tokens along sentence boundaries,
    /// repeating the last `overlap` tokens' worth of sentences at the start of the next piece.
    public static func split(
        text: String, budget: Int, estimator: TokenEstimator, overlap: Int = 0
    ) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        // A sentence bigger than the budget is cut by words.
        var units: [String] = []
        for s in sentences {
            if estimator.tokens(s) <= budget { units.append(s); continue }
            var piece = ""
            for word in s.split(separator: " ", omittingEmptySubsequences: true) {
                let next = piece.isEmpty ? String(word) : piece + " " + word
                if estimator.tokens(next) > budget, !piece.isEmpty { units.append(piece); piece = String(word) } else { piece = next }
            }
            if !piece.isEmpty { units.append(piece) }
        }
        var pieces: [String] = []
        var window: [String] = []
        var used = 0
        for unit in units {
            let cost = estimator.tokens(unit) + 1
            if used + cost > budget, !window.isEmpty {
                pieces.append(window.joined(separator: " "))
                var kept: [String] = []
                var keptCost = 0
                for s in window.reversed() {
                    let c = estimator.tokens(s) + 1
                    if keptCost + c > overlap || keptCost + c + cost > budget { break }
                    kept.insert(s, at: 0)
                    keptCost += c
                }
                window = kept
                used = keptCost
            }
            window.append(unit)
            used += cost
        }
        if !window.isEmpty { pieces.append(window.joined(separator: " ")) }
        return pieces
    }
}
