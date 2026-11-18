import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence) as a `SmallModel`.
///
/// Every call opens a fresh `LanguageModelSession`, so no history ever eats the 4,096-token window.
/// Sampling is greedy: the same input gives the same answer, which also makes the cache honest.
public struct FoundationModelsAdapter: SmallModel {
    private let base: SystemLanguageModel

    /// - Parameter useCase: `.general` for writing and reasoning, `.contentTagging` for classification and extraction.
    public init(useCase: SystemLanguageModel.UseCase = .general) {
        self.base = useCase == .general ? .default : SystemLanguageModel(useCase: useCase)
    }

    public var name: String { "apple.systemlanguagemodel" }

    /// 4,096 on every OS release so far. Read from the model on iOS/macOS 26.4+, fixed on 26.0 to 26.3.
    public var contextSize: Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            let n = base.contextSize
            // A hosted test process can report 0; the real window is still 4,096.
            return n > 0 ? n : 4096
        }
        return 4096
    }

    public func availability() async -> ModelAvailability {
        switch base.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(reason: "This device can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: return .unavailable(reason: "Apple Intelligence is off in Settings")
            case .modelNotReady: return .unavailable(reason: "Apple Intelligence is still downloading its model")
            @unknown default: return .unavailable(reason: "Apple Intelligence is not available")
            }
        }
    }

    public func tokenCount(of text: String) async -> Int? {
        guard #available(iOS 26.4, macOS 26.4, *) else { return nil }
        return try? await base.tokenCount(for: Prompt(text))
    }

    public func schemaTokenCount<T: Generable & Sendable>(for type: T.Type) async -> Int? {
        guard #available(iOS 26.4, macOS 26.4, *) else { return nil }
        return try? await base.tokenCount(for: T.generationSchema)
    }

    public func respond<T: Generable & Sendable>(
        _ type: T.Type, instructions: String, prompt: String, maxResponseTokens: Int?
    ) async throws -> T {
        let session = LanguageModelSession(model: base, instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxResponseTokens)
        do {
            return try await session.respond(to: prompt, generating: type, options: options).content
        } catch {
            throw Self.classify(error)
        }
    }

    public func respond(instructions: String, prompt: String, maxResponseTokens: Int?) async throws -> String {
        let session = LanguageModelSession(model: base, instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxResponseTokens)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch {
            throw Self.classify(error)
        }
    }

    /// Maps Apple's errors to `ModelFailure`.
    ///
    /// It reads the case name instead of matching the enum, because the error type changed between the
    /// OS 26 SDK (`LanguageModelSession.GenerationError`) and the OS 27 SDK (`LanguageModelError`).
    static func classify(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let text = String(describing: error)
        let label = Mirror(reflecting: error).children.first?.label ?? text
        func has(_ words: String...) -> Bool { words.contains { label.contains($0) || text.contains($0) } }
        if has("exceededContextWindowSize", "contextSizeExceeded") { return ModelFailure.contextOverflow }
        if has("guardrailViolation") || text.contains("unsafe content") { return ModelFailure.guardrail }
        if has("rateLimited", "concurrentRequests") { return ModelFailure.busy }
        if has("refusal", "decodingFailure") { return ModelFailure.refused }
        if has("assetsUnavailable") { return ModelFailure.unavailable("The model's assets are unavailable") }
        return ModelFailure.other(text)
    }
}
