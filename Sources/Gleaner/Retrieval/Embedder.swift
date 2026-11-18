import Accelerate
import Foundation
import NaturalLanguage

/// Turns text into a vector so similar meanings land close together.
public protocol TextEmbedder: Sendable {
    /// Identifies the vector space. Saved indexes remember it so you never mix two spaces.
    var name: String { get }
    /// An L2-normalised vector, or `nil` when the text has no usable words.
    func embed(_ text: String) async -> [Float]?
}

func normalized(_ v: [Float]) -> [Float]? {
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    guard norm > 0 else { return nil }
    var scale = 1 / norm.squareRoot()
    var out = [Float](repeating: 0, count: v.count)
    vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
    return out
}

/// Apple's sentence embedding (`NLEmbedding.sentenceEmbedding`): 512 dimensions, on device, no download.
/// This is the default. It is fast (about a millisecond a note) and good for short notes and queries.
public struct SentenceEmbedder: TextEmbedder {
    public let language: NLLanguage
    private let box: Box
    /// NLEmbedding is not safe to call from two threads at once (it crashes), so calls take turns.
    private final class Box: @unchecked Sendable {
        let embedding: NLEmbedding
        let lock = NSLock()
        init(_ e: NLEmbedding) { embedding = e }
        func vector(for text: String) -> [Double]? { lock.withLock { embedding.vector(for: text) } }
    }

    public var name: String { "NLEmbedding.sentence.\(language.rawValue)" }

    /// `nil` when the system has no sentence embedding for `language`.
    public init?(language: NLLanguage = .english) {
        guard let e = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.language = language
        self.box = Box(e)
    }

    public func embed(_ text: String) async -> [Float]? {
        guard let v = box.vector(for: text) else { return nil }
        return normalized(v.map(Float.init))
    }
}

/// Apple's contextual (BERT style) embedding, mean-pooled over tokens.
/// Apple notes `NLEmbedding` is the better choice for plain similarity; this is here for languages and scripts it
/// does not cover, or to compare. It may need to download assets, so creating one is `async` and can throw.
public struct ContextualEmbedder: TextEmbedder {
    private let box: Box
    private final class Box: @unchecked Sendable { let embedding: NLContextualEmbedding; init(_ e: NLContextualEmbedding) { embedding = e } }
    public let language: NLLanguage

    public var name: String { "NLContextualEmbedding.\(box.embedding.modelIdentifier)" }

    public struct Unavailable: Error, Sendable { public var reason: String }

    public init(language: NLLanguage = .english) async throws {
        guard let e = NLContextualEmbedding(language: language) else { throw Unavailable(reason: "No contextual embedding for \(language.rawValue)") }
        if !e.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult = await withCheckedContinuation { c in
                e.requestAssets { r, _ in c.resume(returning: r) }
            }
            guard result == .available else { throw Unavailable(reason: "Assets are not available (\(result.rawValue))") }
        }
        try e.load()
        self.language = language
        self.box = Box(e)
    }

    public func embed(_ text: String) async -> [Float]? {
        let e = box.embedding
        let clipped = String(text.prefix(max(32, e.maximumSequenceLength * 3)))
        guard let result = try? e.embeddingResult(for: clipped, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: e.dimension)
        var n = 0.0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            for i in 0..<min(sum.count, vector.count) { sum[i] += vector[i] }
            n += 1
            return true
        }
        guard n > 0 else { return nil }
        return normalized(sum.map { Float($0 / n) })
    }
}

/// A dependency-free embedder: hashed word and character-trigram counts. It sees spelling, not meaning, so it is
/// weaker than the Apple ones, but it is deterministic and needs no assets: used in tests and as a fallback.
public struct HashingEmbedder: TextEmbedder {
    public let dimension: Int
    public var name: String { "hashing.\(dimension)" }

    public init(dimension: Int = 256) { self.dimension = max(16, dimension) }

    public func embed(_ text: String) async -> [Float]? {
        var v = [Float](repeating: 0, count: dimension)
        for term in Terms.of(text) {
            v[bucketIndex(term)] += 2
            let padded = Array("#" + term + "#")
            if padded.count >= 3 {
                for i in 0...(padded.count - 3) { v[bucketIndex(String(padded[i..<(i + 3)]))] += 1 }
            }
        }
        return normalized(v)
    }

    private func bucketIndex(_ s: String) -> Int { Self.bucket(s) % dimension }
    // FNV-1a, stable across launches (Swift's Hasher is seeded per process).
    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    private static func bucket(_ s: String) -> Int { Int(fnv(s) & 0x7fffffff) }
}
