import Accelerate
import Foundation

/// One note found by a search.
public struct NoteHit: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var metadata: [String: String]
    /// The fused score (higher is better). Only comparable within one search.
    public var score: Double
    /// 1-based rank in the keyword list and in the meaning list, `nil` when it did not appear there.
    public var keywordRank: Int?
    public var semanticRank: Int?
}

/// How a search ranks.
public enum SearchMode: Sendable, Equatable {
    /// BM25 keyword ranking only.
    case keyword
    /// Embedding similarity only.
    case semantic
    /// Both, fused with reciprocal rank fusion. `semanticWeight` is the meaning list's share (0 to 1).
    case hybrid(semanticWeight: Double = 0.5)
}

/// Notes chosen for a prompt and the tokens they take.
public struct PackedContext: Sendable, Equatable {
    public var hits: [NoteHit]
    /// The numbered lines, best note first and second best last (models read the ends of a prompt best).
    public var text: String
    public var tokens: Int
}

/// A small local index of notes and facts: keyword (BM25) plus meaning (embeddings), fused, then packed into a
/// token budget. It never sends anything off the device.
///
/// ```swift
/// let index = NoteIndex()
/// await index.add(["Climbs three times a week", "Brews pour-over coffee every morning"])
/// let context = await index.pack(for: "what gear for the gym?", tokenBudget: 600)
/// ```
public actor NoteIndex {
    private struct Entry: Codable {
        var id: String
        var text: String
        var metadata: [String: String]
        var terms: [String]
        var vector: Data?
    }

    public nonisolated let embedder: any TextEmbedder
    private var entries: [Entry] = []
    private var vectors: [[Float]?] = []
    private var byID: [String: Int] = [:]
    private var postings: [String: [(doc: Int, tf: Int)]] = [:]
    private var totalLength = 0
    private let k1 = 1.2
    private let b = 0.75

    /// - Parameter embedder: defaults to Apple's sentence embedding, or the hashing fallback when the system has none.
    public init(embedder: (any TextEmbedder)? = nil) {
        self.embedder = embedder ?? SentenceEmbedder() ?? HashingEmbedder()
    }

    public var count: Int { entries.count }

    // MARK: Adding

    /// Adds notes. An existing `id` is replaced. Returns the ids in order.
    @discardableResult
    public func add(_ texts: [String], ids: [String]? = nil, metadata: [[String: String]]? = nil) async -> [String] {
        var out: [String] = []
        for (i, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let id = ids?[i] ?? Hashing.key(trimmed).prefix(16).description
            let vector = await embedder.embed(trimmed)
            insert(Entry(id: id, text: trimmed, metadata: metadata?[i] ?? [:], terms: Terms.of(trimmed), vector: vector.map(Self.data)), vector: vector)
            out.append(id)
        }
        return out
    }

    @discardableResult
    public func add(_ text: String, id: String? = nil, metadata: [String: String] = [:]) async -> String? {
        await add([text], ids: id.map { [$0] }, metadata: [metadata]).first
    }

    public func contains(id: String) -> Bool { byID[id] != nil }

    private func insert(_ entry: Entry, vector: [Float]?) {
        if let existing = byID[entry.id] {
            // Replace in place: tombstone the old postings by rebuilding on the next search.
            entries[existing] = entry
            vectors[existing] = vector
            rebuildPostings()
            return
        }
        let doc = entries.count
        entries.append(entry)
        vectors.append(vector)
        byID[entry.id] = doc
        index(doc: doc, terms: entry.terms)
    }

    private func index(doc: Int, terms: [String]) {
        totalLength += terms.count
        var tf: [String: Int] = [:]
        for t in terms { tf[t, default: 0] += 1 }
        for (t, n) in tf { postings[t, default: []].append((doc, n)) }
    }

    private func rebuildPostings() {
        postings = [:]
        totalLength = 0
        for (i, e) in entries.enumerated() { index(doc: i, terms: e.terms) }
    }

    // MARK: Searching

    public func search(_ query: String, k: Int = 10, mode: SearchMode = .hybrid()) async -> [NoteHit] {
        guard !entries.isEmpty, k > 0 else { return [] }
        let pool = max(k * 4, 30)
        var keyword: [Int] = []
        var semantic: [Int] = []
        if mode != .semantic { keyword = keywordRanking(query, limit: pool) }
        if mode != .keyword, let q = await embedder.embed(query) { semantic = semanticRanking(q, limit: pool) }

        var fused: [Int: Double] = [:]
        let weight: (Double, Double)
        switch mode {
        case .keyword: weight = (1, 0)
        case .semantic: weight = (0, 1)
        case .hybrid(let w): weight = (1 - min(1, max(0, w)), min(1, max(0, w)))
        }
        // Reciprocal rank fusion (Cormack, Clarke and Buettcher, SIGIR 2009), k = 60.
        for (rank, doc) in keyword.enumerated() { fused[doc, default: 0] += weight.0 / Double(60 + rank + 1) }
        for (rank, doc) in semantic.enumerated() { fused[doc, default: 0] += weight.1 / Double(60 + rank + 1) }

        let kr = Dictionary(uniqueKeysWithValues: keyword.enumerated().map { ($1, $0 + 1) })
        let sr = Dictionary(uniqueKeysWithValues: semantic.enumerated().map { ($1, $0 + 1) })
        return fused.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(k)
            .map { doc, score in
                let e = entries[doc]
                return NoteHit(id: e.id, text: e.text, metadata: e.metadata, score: score, keywordRank: kr[doc], semanticRank: sr[doc])
            }
    }

    private func keywordRanking(_ query: String, limit: Int) -> [Int] {
        let n = Double(entries.count)
        let avg = max(1, Double(totalLength) / n)
        var scores: [Int: Double] = [:]
        for term in Set(Terms.of(query)) {
            guard let list = postings[term] else { continue }
            let df = Double(list.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for (doc, tf) in list {
                let len = Double(entries[doc].terms.count)
                let f = Double(tf)
                scores[doc, default: 0] += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * len / avg))
            }
        }
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    private func semanticRanking(_ q: [Float], limit: Int) -> [Int] {
        var scored: [(Int, Float)] = []
        for (i, v) in vectors.enumerated() {
            guard let v, v.count == q.count else { continue }
            var dot: Float = 0
            vDSP_dotpr(q, 1, v, 1, &dot, vDSP_Length(q.count))
            scored.append((i, dot))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    // MARK: Packing

    /// Searches, drops near-duplicates, and fills `tokenBudget` with the best notes, arranged with the best at
    /// the start and the second best at the end (the middle of a long prompt is read least; Liu et al., 2023).
    public func pack(
        for query: String, tokenBudget: Int, k: Int = 20, mode: SearchMode = .hybrid(),
        estimator: TokenEstimator = TokenEstimator()
    ) async -> PackedContext {
        let hits = await search(query, k: k, mode: mode)
        let chosen = Packing.choose(hits, tokenBudget: tokenBudget, estimator: estimator)
        let ordered = Packing.edgeOrder(chosen)
        let lines = ordered.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }
        let text = lines.joined(separator: "\n")
        return PackedContext(hits: ordered, text: text, tokens: estimator.tokens(text))
    }

    // MARK: Saving

    private struct Snapshot: Codable { var embedder: String; var entries: [Entry] }

    /// The index as data you can write to disk. Vectors are saved, so loading does not re-embed.
    public func snapshot() throws -> Data {
        try JSONEncoder().encode(Snapshot(embedder: embedder.name, entries: entries))
    }

    /// Restores an index. Notes saved with a different embedder are re-embedded with this one.
    public init(snapshot: Data, embedder: (any TextEmbedder)? = nil) async throws {
        let e = embedder ?? SentenceEmbedder() ?? HashingEmbedder()
        let snap = try JSONDecoder().decode(Snapshot.self, from: snapshot)
        self.embedder = e
        for var entry in snap.entries {
            var vector: [Float]?
            if snap.embedder == e.name, let d = entry.vector { vector = Self.floats(d) } else {
                vector = await e.embed(entry.text)
                entry.vector = vector.map(Self.data)
            }
            insert(entry, vector: vector)
        }
    }

    private static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    private static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Pure packing helpers, kept separate so they are easy to test.
public enum Packing {
    /// Takes hits in rank order while they fit, skipping near-duplicates (word overlap of 85 percent or more).
    /// A hit too big for what is left is cut if at least 40 tokens remain, else skipped.
    public static func choose(_ hits: [NoteHit], tokenBudget: Int, estimator: TokenEstimator) -> [NoteHit] {
        var out: [NoteHit] = []
        var seen: [Set<String>] = []
        var used = 0
        for hit in hits {
            let words = Set(Terms.of(hit.text))
            if seen.contains(where: { jaccard($0, words) >= 0.85 }) { continue }
            var h = hit
            var cost = estimator.tokens(h.text) + Chunker.lineOverhead
            if used + cost > tokenBudget {
                let left = tokenBudget - used - Chunker.lineOverhead
                guard left >= 40 else { continue }
                h.text = estimator.truncate(h.text, toTokens: left)
                cost = estimator.tokens(h.text) + Chunker.lineOverhead
            }
            out.append(h)
            seen.append(words)
            used += cost
        }
        return out
    }

    /// Best first, second best last, the rest working inward: ranks 1, 3, 5 ... 6, 4, 2.
    public static func edgeOrder<T>(_ ranked: [T]) -> [T] {
        var front: [T] = []
        var back: [T] = []
        for (i, item) in ranked.enumerated() { if i % 2 == 0 { front.append(item) } else { back.insert(item, at: 0) } }
        return front + back
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
