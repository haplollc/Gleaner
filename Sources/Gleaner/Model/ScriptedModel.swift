import Foundation
import FoundationModels
import Synchronization

/// One call a `ScriptedModel` received.
public struct ScriptedCall: Sendable, Equatable {
    public enum Kind: String, Sendable { case structured, text }
    public var kind: Kind
    public var outputType: String
    public var instructions: String
    public var prompt: String
}

/// A model for tests and demos: you script the answers, it records every call.
///
/// Token counting is `ceil(characters / charsPerToken)`, so budgets are exact and predictable in tests.
/// It does not pretend to be smart; it returns whatever your closures return.
public final class ScriptedModel: SmallModel {
    public let name: String
    public let contextSize: Int
    public let charsPerToken: Double

    public typealias StructuredHandler = @Sendable (ScriptedCall) throws -> any Sendable
    public typealias TextHandler = @Sendable (ScriptedCall) throws -> String

    private let structured: StructuredHandler
    private let text: TextHandler
    private let state = Mutex(State())
    private struct State { var calls: [ScriptedCall] = []; var delay: Duration = .zero; var inflight = 0; var maxInflight = 0 }

    public init(
        name: String = "scripted",
        contextSize: Int = 4096,
        charsPerToken: Double = 4,
        structured: @escaping StructuredHandler = { _ in throw ModelFailure.other("no structured handler") },
        text: @escaping TextHandler = { _ in "" }
    ) {
        self.name = name
        self.contextSize = contextSize
        self.charsPerToken = charsPerToken
        self.structured = structured
        self.text = text
    }

    /// Every call so far, in order.
    public var calls: [ScriptedCall] { state.withLock { $0.calls } }

    /// The most calls that were ever running at the same time.
    public var maxConcurrentCalls: Int { state.withLock { $0.maxInflight } }

    /// Makes every call take this long (for deadline and cancellation tests).
    public func setDelay(_ delay: Duration) { state.withLock { $0.delay = delay } }

    public func tokenCount(of text: String) async -> Int? {
        Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    public func respond<T: Generable & Sendable>(
        _ type: T.Type, instructions: String, prompt: String, maxResponseTokens: Int?
    ) async throws -> T {
        let call = ScriptedCall(kind: .structured, outputType: String(describing: type), instructions: instructions, prompt: prompt)
        let delay = begin(call)
        defer { end() }
        if delay > .zero { try await Task.sleep(for: delay) }
        let value = try structured(call)
        guard let typed = value as? T else {
            throw ModelFailure.other("scripted handler returned \(Swift.type(of: value)), expected \(T.self)")
        }
        return typed
    }

    public func respond(instructions: String, prompt: String, maxResponseTokens: Int?) async throws -> String {
        let call = ScriptedCall(kind: .text, outputType: "String", instructions: instructions, prompt: prompt)
        let delay = begin(call)
        defer { end() }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try text(call)
    }

    private func begin(_ call: ScriptedCall) -> Duration {
        state.withLock { s in
            s.calls.append(call)
            s.inflight += 1
            s.maxInflight = max(s.maxInflight, s.inflight)
            return s.delay
        }
    }

    private func end() { state.withLock { $0.inflight -= 1 } }
}
