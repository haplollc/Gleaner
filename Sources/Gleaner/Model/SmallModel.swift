import Foundation
import FoundationModels

/// Whether a model can answer right now.
public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

/// What a model call can fail with, in the terms Gleaner reacts to.
///
/// Adapters map their own errors onto these so the recipes can decide:
/// split and retry on `.contextOverflow` and `.guardrail`, back off on `.busy`, give up on `.unavailable`.
public enum ModelFailure: Error, Sendable, Equatable {
    /// The prompt plus the answer did not fit the context window.
    case contextOverflow
    /// The system's safety checks refused the input or the answer.
    case guardrail
    /// The model is busy with another request, or rate limited.
    case busy
    /// The model refused to answer, or the answer could not be read as the asked-for type.
    case refused
    /// The model cannot run (not enabled, not downloaded, not eligible).
    case unavailable(String)
    /// Anything else, with its description.
    case other(String)
}

/// The small protocol Gleaner needs from a language model.
///
/// `FoundationModelsAdapter` implements it for Apple's on-device model, `ScriptedModel` for tests.
/// To plug in another model, implement the two `respond` methods and `contextSize`.
/// Everything else has a default.
public protocol SmallModel: Sendable {
    /// A stable name, used in cache keys so two models never share cached answers.
    var name: String { get }

    /// The context window, in tokens: instructions, prompt, schema and answer together.
    var contextSize: Int { get }

    func availability() async -> ModelAvailability

    /// The exact token count of `text` as the model sees it, or `nil` to let Gleaner estimate.
    func tokenCount(of text: String) async -> Int?

    /// The tokens a `Generable` type's schema adds to every call, or `nil` to let Gleaner estimate.
    func schemaTokenCount<T: Generable & Sendable>(for type: T.Type) async -> Int?

    /// One structured answer, from a fresh session (no history), with greedy sampling where the model supports it.
    func respond<T: Generable & Sendable>(
        _ type: T.Type, instructions: String, prompt: String, maxResponseTokens: Int?
    ) async throws -> T

    /// One plain text answer, from a fresh session.
    func respond(instructions: String, prompt: String, maxResponseTokens: Int?) async throws -> String
}

extension SmallModel {
    public func availability() async -> ModelAvailability { .available }
    public func tokenCount(of text: String) async -> Int? { nil }
    public func schemaTokenCount<T: Generable & Sendable>(for type: T.Type) async -> Int? { nil }
}
