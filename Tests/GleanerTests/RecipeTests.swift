import Foundation
import FoundationModels
import Testing
@testable import Gleaner

@Suite("Other recipes")
struct RecipeTests {
    @Test func summarizeRunsInLevelsUntilOneCallCanTakeTheRest() async throws {
        let model = ScriptedModel(text: { call in
            // Every summary is short, so each level shrinks.
            call.instructions.contains("one summary") ? "FINAL" : "gist"
        })
        let g = Gleaner(model: model)
        let records = (0..<400).map { "post \($0) " + String(repeating: "about many things ", count: 5) }
        let summary = try await g.summarize(records)
        #expect(summary.text == "FINAL")
        #expect(summary.levels >= 2)
        #expect(model.calls.filter { $0.instructions.contains("one summary") }.count == 1)   // exactly one root
        #expect(summary.report.biggestPrompt < 4096)
    }

    @Test func runningNotesCarryForwardAndCompactWhenTheyGrow() async throws {
        let step = Mutex2()
        let model = ScriptedModel(text: { call in
            if call.instructions.hasPrefix("You shorten notes") { return "short notes" }
            let n = step.next()
            return "notes after step \(n): " + String(repeating: "detail ", count: 400)   // too long on purpose
        })
        let g = Gleaner(model: model)
        let records = (0..<120).map { "record \($0) " + String(repeating: "stuff ", count: 20) }
        let notes = try await g.runningNotes(records, goal: "find patterns", options: NotesOptions(noteTokens: 200))
        #expect(notes.compactions == notes.report.chunksRead)
        #expect(notes.text == "short notes")
        #expect(notes.trail.count == notes.report.chunksRead)
        // Each step's prompt carried the previous (compacted) notes.
        let stepCalls = model.calls.filter { !$0.instructions.hasPrefix("You shorten") }
        #expect(stepCalls.first?.prompt.contains("(none yet)") == true)
        #expect(stepCalls.dropFirst().allSatisfy { $0.prompt.contains("short notes") })
    }

    @Test func notesThatWillNotShrinkAreCutHardSoTheyNeverCrowdOutData() async throws {
        let model = ScriptedModel(text: { _ in String(repeating: "long ", count: 600) })
        let g = Gleaner(model: model)
        let notes = try await g.runningNotes((0..<60).map { "r\($0) " + String(repeating: "x ", count: 80) }, goal: "g", options: NotesOptions(noteTokens: 150))
        #expect(TokenEstimator().tokens(notes.text) <= 200)
    }

    @Test func askRetrievesPacksAndAnswersOnce() async throws {
        let model = ScriptedModel(text: { call in call.prompt.contains("[1]") ? "answered" : "no notes" })
        let g = Gleaner(model: model)
        let index = NoteIndex(embedder: HashingEmbedder())
        await index.add(RetrievalTests.notes)
        let answer = try await g.ask("what coffee gear?", over: index)
        #expect(answer.text == "answered")
        #expect(model.calls.count == 1)
        #expect(model.calls[0].prompt.contains("pour-over"))
        #expect(!model.calls[0].prompt.contains("sourdough") || answer.sources.contains { $0.text.contains("sourdough") })
        #expect(answer.report.biggestPrompt < 1500)
    }

    @Test func aGuardrailOnAnAnswerSurfacesAsAModelFailure() async {
        let model = ScriptedModel(text: { _ in throw ModelFailure.guardrail })
        let g = Gleaner(model: model)
        let index = NoteIndex(embedder: HashingEmbedder())
        await index.add("anything")
        await #expect(throws: ModelFailure.guardrail) { _ = try await g.ask("q", over: index) }
    }

    @Test func appleErrorsAreMappedByCaseName() {
        enum Fake: Error { case exceededContextWindowSize(Int), guardrailViolation, rateLimited, concurrentRequests, decodingFailure }
        #expect(FoundationModelsAdapter.classify(Fake.exceededContextWindowSize(5000)) as? ModelFailure == .contextOverflow)
        #expect(FoundationModelsAdapter.classify(Fake.guardrailViolation) as? ModelFailure == .guardrail)
        #expect(FoundationModelsAdapter.classify(Fake.concurrentRequests) as? ModelFailure == .busy)
        #expect(FoundationModelsAdapter.classify(Fake.decodingFailure) as? ModelFailure == .refused)
        #expect(FoundationModelsAdapter.classify(CancellationError()) is CancellationError)
    }
}

/// A tiny thread-safe counter for scripted handlers.
final class Mutex2: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
