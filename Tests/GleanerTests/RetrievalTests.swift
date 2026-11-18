import Foundation
import Testing
@testable import Gleaner

@Suite("Retrieval")
struct RetrievalTests {
    static let notes = [
        "Climbs at the bouldering gym three times a week and wants better climbing shoes",
        "Brews pour-over coffee every morning and owns a hand grinder",
        "Bakes sourdough on Sundays, keeps a starter named Gloria",
        "Collects vinyl records, mostly 70s jazz and soul",
        "Waters her houseplants on Fridays; fiddle leaf fig keeps dropping leaves",
        "Reads science fiction paperbacks on the train",
        "Runs trail races and needs new running socks",
        "Plays indie board games with friends every month",
    ]

    func index() async -> NoteIndex {
        let i = NoteIndex(embedder: HashingEmbedder())
        await i.add(Self.notes)
        return i
    }

    @Test func keywordSearchRanksTheMatchingNoteFirst() async {
        let hits = await index().search("climbing shoes", k: 3, mode: .keyword)
        #expect(hits.first?.text.contains("bouldering") == true)
        #expect(hits.first?.keywordRank == 1)
        #expect(hits.first?.semanticRank == nil)
    }

    @Test func pluralsAndCaseFold() async {
        let hits = await index().search("RECORD", k: 2, mode: .keyword)
        #expect(hits.first?.text.contains("vinyl") == true)
        let plural = await index().search("houseplant", k: 1, mode: .keyword)
        #expect(plural.first?.text.contains("fiddle") == true)
    }

    @Test func semanticModeUsesTheEmbedderAndFindsSpellingNeighbours() async {
        let hits = await index().search("sourdough starters", k: 2, mode: .semantic)
        #expect(hits.first?.text.contains("sourdough") == true)
        #expect(hits.first?.semanticRank == 1)
    }

    @Test func hybridFusesBothListsWithReciprocalRank() async {
        let hits = await index().search("morning coffee grinder", k: 3)
        let top = hits[0]
        #expect(top.text.contains("pour-over"))
        #expect(top.keywordRank == 1 && top.semanticRank != nil)
        // RRF with k = 60 and equal weights: 0.5/61 from each list when both rank it first.
        #expect(abs(top.score - (0.5 / 61 + 0.5 / 61)) < 1e-9 || top.semanticRank! > 1)
        // Scores never increase down the list.
        #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
    }

    @Test func idsReplaceInsteadOfDuplicating() async {
        let i = NoteIndex(embedder: HashingEmbedder())
        await i.add("likes tea", id: "n1")
        await i.add("likes coffee", id: "n1")
        #expect(await i.count == 1)
        #expect(await i.search("coffee", k: 1, mode: .keyword).first?.text == "likes coffee")
        #expect(await i.search("tea", k: 1, mode: .keyword).isEmpty)
    }

    @Test func packingStaysInsideTheBudgetAndPutsTheBestNotesAtTheEdges() async {
        let est = TokenEstimator(charsPerToken: 4)
        let idx = await index()
        let ctx = await idx.pack(for: "coffee morning climbing gym running socks", tokenBudget: 60, k: 8, mode: .keyword, estimator: est)
        let cost = ctx.hits.reduce(0) { $0 + est.tokens($1.text) + Chunker.lineOverhead }
        #expect(cost <= 60)
        #expect(ctx.hits.count >= 2)
        let ranked = await idx.search("coffee morning climbing gym running socks", k: 8, mode: .keyword)
        #expect(ctx.hits.first?.id == ranked.first?.id)          // best first
        #expect(ctx.text.hasPrefix("[1] "))
    }

    @Test func edgeOrderPlacesRanksOneAndTwoAtTheEnds() {
        #expect(Packing.edgeOrder([1, 2, 3, 4, 5, 6]) == [1, 3, 5, 6, 4, 2])
        #expect(Packing.edgeOrder([1, 2]) == [1, 2])
        #expect(Packing.edgeOrder([Int]()).isEmpty)
    }

    @Test func nearDuplicatesAreDroppedWhenPacking() {
        let hits = ["Likes climbing shoes a lot", "likes climbing shoes a lot!", "Brews coffee"].enumerated().map {
            NoteHit(id: "\($0.offset)", text: $0.element, metadata: [:], score: 1, keywordRank: nil, semanticRank: nil)
        }
        let chosen = Packing.choose(hits, tokenBudget: 500, estimator: TokenEstimator())
        #expect(chosen.map(\.id) == ["0", "2"])
    }

    @Test func aTooBigNoteIsCutOnlyWhenEnoughRoomRemains() {
        let big = NoteHit(id: "b", text: String(repeating: "word ", count: 400), metadata: [:], score: 1, keywordRank: nil, semanticRank: nil)
        let est = TokenEstimator(charsPerToken: 4)
        #expect(Packing.choose([big], tokenBudget: 100, estimator: est).first?.text.hasSuffix("…") == true)
        #expect(Packing.choose([big], tokenBudget: 30, estimator: est).isEmpty)
    }

    @Test func snapshotsRoundTripWithoutReEmbedding() async throws {
        let idx = await index()
        let data = try await idx.snapshot()
        let restored = try await NoteIndex(snapshot: data, embedder: HashingEmbedder())
        #expect(await restored.count == Self.notes.count)
        let a = await idx.search("sourdough", k: 3)
        let b = await restored.search("sourdough", k: 3)
        #expect(a.map(\.id) == b.map(\.id))
    }

    @Test func appleSentenceEmbeddingFindsMeaningNotJustSpelling() async throws {
        guard let apple = SentenceEmbedder() else { return }   // not every OS image ships it
        let i = NoteIndex(embedder: apple)
        await i.add(Self.notes)
        let hits = await i.search("something to wear on her feet for the mountain", k: 3, mode: .semantic)
        #expect(hits.contains { $0.text.contains("socks") || $0.text.contains("shoes") })
    }
}
