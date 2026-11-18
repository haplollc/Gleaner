import Foundation
import FoundationModels

/// Makes a small on-device model effective on a lot of data.
///
/// ```swift
/// let gleaner = Gleaner()                                   // Apple's on-device model
/// let result = try await gleaner.extract(Ideas.self, from: records, goal: "Find gift ideas.")
/// print(result.items, result.report)
/// ```
///
/// A `Gleaner` owns the rules every recipe shares: measure tokens, keep every call inside the window, run one
/// model request at a time, respect a deadline, split and retry on overflow or guardrail errors, cache answers.
public final class Gleaner: Sendable {
    public struct Configuration: Sendable {
        /// Tokens kept free for the model's answer when sizing prompts.
        public var outputReserve = 700
        /// The safety cushion, as a fraction of the window.
        public var marginFraction = 0.06
        /// Model requests in flight at once. The on-device model answers one at a time, so 1 is right for it.
        public var concurrency = 1
        /// The longest one call may take.
        public var callTimeout: Duration = .seconds(90)
        /// How many times a failing chunk is halved before its records are skipped.
        public var maxSplitDepth = 6
        /// Where answers are kept. `nil` turns caching off.
        public var cache: (any ResultCache)?

        public init(cache: (any ResultCache)? = MemoryCache()) { self.cache = cache }
    }

    public let model: any SmallModel
    public let configuration: Configuration
    let gate: Gate
    let measurer: Measurer

    public init(model: any SmallModel = FoundationModelsAdapter(), configuration: Configuration = Configuration()) {
        self.model = model
        self.configuration = configuration
        self.gate = Gate(permits: configuration.concurrency)
        self.measurer = Measurer(model: model)
    }

    /// Throws `GleanerError.modelUnavailable` with a reason a person can read when the model cannot run.
    public func requireAvailable() async throws {
        if case .unavailable(let reason) = await model.availability() { throw GleanerError.modelUnavailable(reason) }
    }

    // MARK: Budgets

    /// The token budget for a call with these instructions and (optionally) this structured output.
    public func budget<T: Generable & Sendable>(
        instructions: String, output: T.Type, outputReserve: Int? = nil, extraFixed: Int = 0
    ) async -> TokenBudget {
        let schema = await measurer.schemaTokens(output, model: model)
        return await makeBudget(instructions: instructions, schema: schema, outputReserve: outputReserve, extraFixed: extraFixed)
    }

    /// The token budget for a plain text call.
    public func textBudget(instructions: String, outputReserve: Int? = nil, extraFixed: Int = 0) async -> TokenBudget {
        await makeBudget(instructions: instructions, schema: 0, outputReserve: outputReserve, extraFixed: extraFixed)
    }

    private func makeBudget(instructions: String, schema: Int, outputReserve: Int?, extraFixed: Int) async -> TokenBudget {
        let ins = await measurer.count(instructions, model: model)
        let size = model.contextSize
        return TokenBudget(
            contextSize: size,
            outputReserve: outputReserve ?? configuration.outputReserve,
            margin: max(48, Int(Double(size) * configuration.marginFraction)),
            fixed: ins + schema + 16 + extraFixed
        )
    }

    /// An estimator calibrated on a sample of `records` against the real model.
    public func estimator(sampling records: [String]) async -> TokenEstimator {
        await measurer.calibrate(on: records, model: model)
    }

    // MARK: One model call

    func structured<T: Generable & Sendable>(
        _ type: T.Type, instructions: String, prompt: String, run: RunRecorder
    ) async throws -> T {
        let key = Hashing.key(model.name, "structured", String(describing: type), instructions, prompt)
        let schemaTokens = await measurer.schemaTokens(type, model: model)
        return try await perform(
            key: key, instructions: instructions, prompt: prompt, schemaTokens: schemaTokens, run: run,
            encode: { $0.generatedContent.jsonString },
            decode: { try? T(GeneratedContent(json: $0)) },
            call: { [model] in try await model.respond(type, instructions: instructions, prompt: prompt, maxResponseTokens: nil) }
        )
    }

    func text(instructions: String, prompt: String, maxTokens: Int, run: RunRecorder) async throws -> String {
        let key = Hashing.key(model.name, "text", String(maxTokens), instructions, prompt)
        return try await perform(
            key: key, instructions: instructions, prompt: prompt, schemaTokens: 0, run: run,
            encode: { $0 }, decode: { $0 },
            call: { [model] in try await model.respond(instructions: instructions, prompt: prompt, maxResponseTokens: maxTokens) }
        )
    }

    private func perform<R: Sendable>(
        key: String, instructions: String, prompt: String, schemaTokens: Int, run: RunRecorder,
        encode: (R) -> String, decode: (String) -> R?, call: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        if let cache = configuration.cache, let hit = await cache.value(for: key), let value = decode(hit) {
            run.update { $0.cacheHits += 1 }
            return value
        }
        // Count the whole prompt exactly (when the model can) and refuse before the model sees an overflow.
        let ins = await measurer.count(instructions, model: model)
        let body = await measurer.count(prompt, model: model)
        let total = ins + body + schemaTokens + 16
        let room = model.contextSize - 120   // keep at least a short answer's room
        guard total <= room else { throw GleanerError.promptTooLarge(tokens: total, budget: room) }

        try await gate.acquire()
        let result: R
        do {
            guard !run.isExpired else { throw GleanerError.deadlineReached }
            try Task.checkCancellation()
            run.update { $0.modelCalls += 1; $0.promptTokens += total; $0.biggestPrompt = max($0.biggestPrompt, total) }
            var limit = configuration.callTimeout
            if let left = run.remaining { limit = min(limit, .seconds(max(1, left))) }
            result = try await Self.withTimeout(limit, call)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        if let cache = configuration.cache { await cache.store(encode(result), for: key) }
        return result
    }

    static func withTimeout<R: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> R) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(for: limit); throw GleanerError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Measures tokens: exactly when the model can count, from a calibrated estimate when it cannot.
actor Measurer {
    private var exact: [String: Int] = [:]
    private var schemas: [String: Int] = [:]
    private var estimator = TokenEstimator()

    init(model: any SmallModel) {}

    func count(_ text: String, model: any SmallModel) async -> Int {
        if let known = exact[text] { return known }
        let n = await model.tokenCount(of: text) ?? estimator.tokens(text)
        if text.count < 4000 { exact[text] = n }
        return n
    }

    func schemaTokens<T: Generable & Sendable>(_ type: T.Type, model: any SmallModel) async -> Int {
        let key = String(describing: type)
        if let known = schemas[key] { return known }
        let n = await model.schemaTokenCount(for: type) ?? 200
        schemas[key] = n
        return n
    }

    /// Measures a spread-out sample of `records` once and keeps the resulting characters-per-token ratio,
    /// shaved 8 percent so estimates lean high. Without exact counts the default of 3.0 stands.
    func calibrate(on records: [String], model: any SmallModel) async -> TokenEstimator {
        let usable = records.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return estimator }
        let step = max(1, usable.count / 8)
        let sample = stride(from: 0, to: usable.count, by: step).prefix(8).map { usable[$0] }.joined(separator: "\n")
        if let measured = await model.tokenCount(of: sample), measured > 0 {
            let ratio = Double(sample.count) / Double(measured) * 0.92
            estimator = TokenEstimator(charsPerToken: min(5, max(1, ratio)))
        }
        return estimator
    }
}
