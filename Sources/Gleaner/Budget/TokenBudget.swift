import Foundation

/// How a context window is spent on one call.
///
/// ```
/// | instructions | schema | input (what you chunk to) | safety margin | room for the answer |
/// ```
public struct TokenBudget: Sendable, Equatable {
    public var contextSize: Int
    /// Tokens kept free for the model's answer.
    public var outputReserve: Int
    /// A small cushion so an estimate that is a little off never overflows the window.
    public var margin: Int
    /// Tokens already spent before any data goes in: instructions, schema, framing.
    public var fixed: Int

    public init(contextSize: Int, outputReserve: Int, margin: Int, fixed: Int) {
        self.contextSize = contextSize
        self.outputReserve = outputReserve
        self.margin = margin
        self.fixed = fixed
    }

    /// Tokens left for the data in the prompt.
    public var input: Int { max(0, contextSize - outputReserve - margin - fixed) }

    /// True when `inputTokens` of data fits.
    public func fits(_ inputTokens: Int) -> Bool { inputTokens <= input }

    /// The same budget with a different amount already spent.
    public func spending(_ extra: Int) -> TokenBudget {
        var copy = self
        copy.fixed += extra
        return copy
    }
}

/// A fast, synchronous token estimate, calibrated against the real model when it can count.
public struct TokenEstimator: Sendable, Equatable {
    /// Characters per token. Apple says 3 to 4 for English; the default leans low so chunks never overflow.
    public var charsPerToken: Double

    public init(charsPerToken: Double = 3.0) {
        self.charsPerToken = max(0.5, charsPerToken)
    }

    public func tokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    /// `text` cut to about `limit` tokens, on a word boundary, with an ellipsis when something was cut.
    public func truncate(_ text: String, toTokens limit: Int) -> String {
        guard tokens(text) > limit else { return text }
        let keep = max(1, Int(Double(limit) * charsPerToken) - 1)
        var cut = String(text.prefix(keep))
        if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: cut.startIndex, to: space) > keep / 2 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }
}
