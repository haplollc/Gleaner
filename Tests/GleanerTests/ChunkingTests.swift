import Testing
@testable import Gleaner

@Suite("Budget and chunking")
struct ChunkingTests {
    let estimator = TokenEstimator(charsPerToken: 4)

    @Test func budgetSubtractsEverythingSpentBeforeTheData() {
        let b = TokenBudget(contextSize: 4096, outputReserve: 700, margin: 245, fixed: 300)
        #expect(b.input == 4096 - 700 - 245 - 300)
        #expect(b.spending(100).input == b.input - 100)
        #expect(b.fits(b.input) && !b.fits(b.input + 1))
        #expect(TokenBudget(contextSize: 100, outputReserve: 200, margin: 0, fixed: 0).input == 0)
    }

    @Test func gleanerBudgetUsesMeasuredInstructionsAndSchema() async {
        let model = ScriptedModel(charsPerToken: 4)
        let g = Gleaner(model: model)
        let instructions = String(repeating: "x", count: 400)   // 100 tokens
        let b = await g.budget(instructions: instructions, output: Ideas.self)
        #expect(b.contextSize == 4096)
        #expect(b.fixed >= 100 + 16)
        #expect(b.input < 4096 - b.outputReserve - 100)
    }

    @Test func everyChunkFitsAndOrderIsKept() {
        let records = (0..<500).map { "post number \($0) about \(String(repeating: "climbing ", count: $0 % 9 + 1))" }
        let chunks = Chunker.pack(records, budget: 600, estimator: estimator)
        #expect(chunks.allSatisfy { $0.tokens <= 600 })
        #expect(chunks.flatMap(\.indices) == Array(0..<500))
        #expect(chunks.count > 1)
        for c in chunks { #expect(c.tokens == c.texts.reduce(0) { $0 + estimator.tokens($1) + Chunker.lineOverhead }) }
    }

    @Test func aRecordLargerThanTheBudgetIsCutNotDropped() {
        let huge = String(repeating: "word ", count: 2000)
        let chunks = Chunker.pack(["small", huge, "tail"], budget: 200, estimator: estimator)
        #expect(chunks.flatMap(\.indices) == [0, 1, 2])
        #expect(chunks.contains { $0.truncated })
        #expect(chunks.allSatisfy { $0.tokens <= 200 })
    }

    @Test func maxRecordsCapsAChunk() {
        let chunks = Chunker.pack(sampleRecords(25), budget: 4000, estimator: estimator, maxRecords: 10)
        #expect(chunks.map(\.texts.count) == [10, 10, 5])
    }

    @Test func blankRecordsAreSkipped() {
        let chunks = Chunker.pack(["a", "  ", "", "b"], budget: 100, estimator: estimator)
        #expect(chunks.flatMap(\.indices) == [0, 3])
    }

    @Test func halvesSplitInOrderAndStopAtOne() {
        let chunk = Chunker.pack(sampleRecords(5), budget: 4000, estimator: estimator)[0]
        let halves = Chunker.halves(of: chunk)!
        #expect(halves.map(\.indices) == [[0, 1], [2, 3, 4]])
        #expect(Chunker.halves(of: halves[0])!.count == 2)
        #expect(Chunker.halves(of: Chunker.halves(of: halves[0])![0]) == nil)
    }

    @Test func longTextSplitsOnSentencesWithOverlap() {
        let text = (1...40).map { "This is sentence number \($0) of the long text." }.joined(separator: " ")
        let pieces = Chunker.split(text: text, budget: 80, estimator: estimator, overlap: 25)
        #expect(pieces.count > 3)
        #expect(pieces.allSatisfy { estimator.tokens($0) <= 80 })
        // Overlap: the last sentence of a piece starts the next one.
        let lastOfFirst = pieces[0].components(separatedBy: ". ").last!.trimmingCharacters(in: .punctuationCharacters)
        #expect(pieces[1].contains(lastOfFirst))
    }

    @Test func estimatorTruncatesOnAWordBoundary() {
        let cut = estimator.truncate(String(repeating: "alpha ", count: 100), toTokens: 10)
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= 41)
        #expect(!cut.dropLast().hasSuffix("alph"))
    }
}
