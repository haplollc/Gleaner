import Foundation
import FoundationModels
import Testing
@testable import Gleaner

/// Runs against the real on-device model. Opt in: `GLEANER_LIVE=1 swift test --filter Live`.
/// Skipped (not faked) when the variable is unset or Apple Intelligence is unavailable.
@Suite("Live model", .enabled(if: ProcessInfo.processInfo.environment["GLEANER_LIVE"] == "1"))
struct LiveModelTests {
    @Test func theRealWindowAndTokenCountAreWhatTheDocsSay() async throws {
        let model = FoundationModelsAdapter()
        guard await model.availability().isAvailable else { Issue.record("Apple Intelligence unavailable here"); return }
        #expect(model.contextSize == 4096)
        let n = await model.tokenCount(of: "Hello there, this is a test.")
        #expect((n ?? 0) > 0)
    }

    @Test func extractsRealIdeasFromAFewRecords() async throws {
        let model = FoundationModelsAdapter()
        guard await model.availability().isAvailable else { Issue.record("Apple Intelligence unavailable here"); return }
        let records = [
            "Liked a post about bouldering shoes", "Searched: best chalk bag for climbing", "Liked a post about climbing gym day passes",
            "Searched: how to season a cast iron pan", "Liked a post about pour-over coffee ratios",
        ]
        let result = try await Gleaner(model: model).extract(Ideas.self, from: records, goal: "Find gift ideas this person would love.")
        #expect(!result.items.isEmpty)
        print("LIVE:", result.items.map(\.line), result.report)
    }
}
