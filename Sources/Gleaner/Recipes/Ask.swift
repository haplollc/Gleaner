import Foundation
import FoundationModels

extension Gleaner {
    /// Answers a question from a `NoteIndex`: retrieve with BM25 plus embeddings, pack the best notes into what
    /// the window has left, and ask once. Cheap, because only a handful of notes ever reach the model.
    public func ask(_ question: String, over index: NoteIndex, options: AskOptions = AskOptions()) async throws -> Answer {
        try await requireAvailable()
        let run = RunRecorder(deadline: options.deadline, progress: options.progress)
        let instructions = Self.askInstructions
        let budget = await textBudget(instructions: instructions, outputReserve: options.answerTokens + 40,
                                      extraFixed: await measurer.count(question, model: model) + 24)
        let estimator = TokenEstimator()
        run.progress(.retrieve, options.label, 0, 2)
        let context = await index.pack(for: question, tokenBudget: budget.input, k: options.k, mode: options.mode, estimator: estimator)
        run.progress(.answer, options.label, 1, 2)
        let prompt = "Notes:\n\(context.text)\n\nQuestion: \(question)"
        let text = try await self.text(instructions: instructions, prompt: prompt, maxTokens: options.answerTokens + 40, run: run)
        run.progress(.answer, options.label, 2, 2)
        return Answer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sources: context.hits, report: run.snapshot())
    }

    /// The same, but the answer is a `Generable` type you define.
    public func ask<T: Generable & Sendable>(
        _ question: String, as type: T.Type, over index: NoteIndex, options: AskOptions = AskOptions()
    ) async throws -> (answer: T, sources: [NoteHit], report: RunReport) {
        try await requireAvailable()
        let run = RunRecorder(deadline: options.deadline, progress: options.progress)
        let instructions = Self.askInstructions
        let budget = await self.budget(instructions: instructions, output: type, outputReserve: options.answerTokens + 40,
                                       extraFixed: await measurer.count(question, model: model) + 24)
        let context = await index.pack(for: question, tokenBudget: budget.input, k: options.k, mode: options.mode)
        let prompt = "Notes:\n\(context.text)\n\nQuestion: \(question)"
        let answer = try await structured(type, instructions: instructions, prompt: prompt, run: run)
        return (answer, context.hits, run.snapshot())
    }

    static let askInstructions = "You answer a question using only the numbered notes you are given. Cite what you use by note number, like [2]. If the notes do not say, answer that you do not know."
}
