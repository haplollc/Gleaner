import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import Gleaner

@Suite("Extraction pipeline")
struct PipelineTests {
    @Test func mapReadsEveryRecordAndNoPromptOverflowsTheWindow() async throws {
        let model = echoModel()
        let g = Gleaner(model: model)
        let records = sampleRecords(300, width: 22)
        let result = try await g.extract(Ideas.self, from: records, goal: "Find things.")
        #expect(result.items.count == 300)
        #expect(result.report.chunksTotal > 3)
        #expect(result.coverage == 1)
        let maxPromptTokens = model.calls.map { ($0.instructions.count + $0.prompt.count) / 4 }.max()!
        #expect(maxPromptTokens <= 4096 - 700)           // room left for the answer
        #expect(result.report.biggestPrompt <= 4096 - 120)
        // Chunks were read in order.
        let firstRecords = model.calls.compactMap { recordTexts(in: $0.prompt).first }
        let numbers = firstRecords.compactMap { Int($0.dropFirst("record-".count).prefix { $0.isNumber }) }
        #expect(numbers == numbers.sorted())
    }

    @Test func duplicatesAcrossChunksAreMergedByNormalisedLine() async throws {
        let g = Gleaner(model: echoModel())
        let records = ["Climbing shoes", "climbing  shoe", "Coffee grinder"] + sampleRecords(3)
        let result = try await g.extract(Ideas.self, from: records, goal: "x")
        let titles = result.items.map(\.title)
        #expect(titles.filter { $0.lowercased().contains("climbing") }.count == 1)
    }

    @Test func treeReduceMergesInOrderAndEndsUnderTheTarget() async throws {
        // A small window forces several groups at the first level, then a final merge.
        let model = echoModel(contextSize: 700)
        let g = Gleaner(model: model, configuration: {
            var c = Gleaner.Configuration(); c.outputReserve = 150; return c
        }())
        let records = (0..<120).map { String(format: "r%03d tag", $0) }
        let result = try await g.extract(Ideas.self, from: records, goal: "x", options: ExtractOptions(reduceTo: 5))
        #expect(result.items.count <= 5)
        let reduceCalls = model.calls.filter { $0.instructions.hasPrefix("You merge lists") }
        #expect(reduceCalls.count >= 3)                   // several groups, then at least one more level
        // Within the first level, groups arrive in input order and do not overlap.
        let seen = reduceCalls.flatMap { $0.prompt.split(separator: "\n").filter { $0.hasPrefix("- r") && $0.hasSuffix(": seen") }.map { String($0.dropFirst(2).prefix(4)) } }
        #expect(seen.count == 120)
        #expect(seen == seen.sorted())
        #expect(Set(seen).count == seen.count)
    }

    @Test func anOverflowSplitsTheChunkAndNothingIsLost() async throws {
        let model = echoModel { call in
            if recordTexts(in: call.prompt).count > 4, !call.instructions.hasPrefix("You merge") { throw ModelFailure.contextOverflow }
        }
        let g = Gleaner(model: model)
        let result = try await g.extract(Ideas.self, from: sampleRecords(40), goal: "x")
        #expect(result.items.count == 40)
        #expect(result.report.splitRetries > 0)
        #expect(result.report.skippedRecords == 0)
    }

    @Test func aGuardrailRecordIsIsolatedBySplittingAndSkippedAlone() async throws {
        let model = echoModel { call in
            if call.prompt.contains("BADRECORD") { throw ModelFailure.guardrail }
        }
        let g = Gleaner(model: model)
        var records = sampleRecords(16)
        records[5] = "BADRECORD here"
        let result = try await g.extract(Ideas.self, from: records, goal: "x")
        #expect(result.items.count == 15)
        #expect(result.report.skippedRecords == 1)
        #expect(!result.items.contains { $0.title.contains("BADRECORD") })
    }

    @Test func aSecondRunOnTheSameInputIsServedFromTheCache() async throws {
        let model = echoModel()
        let g = Gleaner(model: model)
        let records = sampleRecords(60, width: 8)
        let first = try await g.extract(Ideas.self, from: records, goal: "x")
        let callsAfterFirst = model.calls.count
        let second = try await g.extract(Ideas.self, from: records, goal: "x")
        #expect(model.calls.count == callsAfterFirst)
        #expect(second.report.modelCalls == 0)
        #expect(second.report.cacheHits == first.report.modelCalls)
        #expect(second.items.map(\.title) == first.items.map(\.title))
        // A different goal is a different question: no stale hits.
        _ = try await g.extract(Ideas.self, from: records, goal: "y")
        #expect(model.calls.count > callsAfterFirst)
    }

    @Test func diskCacheSurvivesANewGleaner() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gleaner-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let records = sampleRecords(30, width: 8)
        let m1 = echoModel()
        _ = try await Gleaner(model: m1, configuration: .init(cache: DiskCache(directory: dir))).extract(Ideas.self, from: records, goal: "x")
        let m2 = echoModel()
        let again = try await Gleaner(model: m2, configuration: .init(cache: DiskCache(directory: dir))).extract(Ideas.self, from: records, goal: "x")
        #expect(m2.calls.isEmpty)
        #expect(again.items.count == 30)
    }

    @Test func laterPassesToldWhatWasAlreadyFound() async throws {
        let model = echoModel()
        let g = Gleaner(model: model)
        _ = try await g.extract(Ideas.self, from: sampleRecords(80, width: 6), goal: "x", options: ExtractOptions(passes: 2))
        let pass2 = model.calls.filter { $0.prompt.contains("Already found") }
        #expect(!pass2.isEmpty)
        #expect(pass2.allSatisfy { $0.prompt.contains("record-") })
        #expect(model.calls.first?.prompt.contains("Already found") == false)
    }

    @Test func theDeadlineStopsReadingAndSaysSo() async throws {
        let model = echoModel()
        model.setDelay(.milliseconds(150))
        let g = Gleaner(model: model)
        let result = try await g.extract(Ideas.self, from: sampleRecords(800, width: 20), goal: "x",
                                         options: ExtractOptions(deadline: .milliseconds(500)))
        #expect(result.report.deadlineHit)
        #expect(result.coverage < 1)
        #expect(result.items.count > 0)
        #expect(result.report.seconds < 3)
    }

    @Test func cancellingTheTaskStopsTheRun() async throws {
        let model = echoModel()
        model.setDelay(.milliseconds(100))
        let g = Gleaner(model: model)
        let task = Task { try await g.extract(Ideas.self, from: sampleRecords(200, width: 20), goal: "x") }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(model.calls.count < 8)
    }

    @Test func requestsAreSerialisedByDefault() async throws {
        let model = echoModel()
        model.setDelay(.milliseconds(20))
        let g = Gleaner(model: model)
        async let a = g.extract(Ideas.self, from: sampleRecords(60, width: 8), goal: "a")
        async let b = g.extract(Ideas.self, from: sampleRecords(60, width: 8), goal: "b")
        _ = try await (a, b)
        #expect(model.maxConcurrentCalls == 1)

        let wide = echoModel()
        wide.setDelay(.milliseconds(20))
        var c = Gleaner.Configuration(); c.concurrency = 3
        let g3 = Gleaner(model: wide, configuration: c)
        _ = try await g3.extract(Ideas.self, from: sampleRecords(600, width: 20), goal: "a")
        #expect(wide.maxConcurrentCalls > 1 && wide.maxConcurrentCalls <= 3)
    }

    @Test func progressCountsUpAndCarriesTheLabel() async throws {
        let events = Mutex<[GleanerProgress]>([])
        let g = Gleaner(model: echoModel())
        _ = try await g.extract(Ideas.self, from: sampleRecords(120, width: 8), goal: "x",
                                options: ExtractOptions(label: "Reading your searches", progress: { p in events.withLock { $0.append(p) } }))
        let seen = events.withLock { $0 }
        #expect(seen.allSatisfy { $0.label == "Reading your searches" })
        let done = seen.map(\.completed)
        #expect(done == done.sorted())
        #expect(seen.last?.fraction == 1)
    }

    @Test func anUnavailableModelFailsFastWithAReason() async {
        struct Off: SmallModel {
            let name = "off"; let contextSize = 4096
            func availability() async -> ModelAvailability { .unavailable(reason: "Apple Intelligence is off in Settings") }
            func respond<T>(_ type: T.Type, instructions: String, prompt: String, maxResponseTokens: Int?) async throws -> T where T: Generable & Sendable { throw ModelFailure.unavailable("off") }
            func respond(instructions: String, prompt: String, maxResponseTokens: Int?) async throws -> String { "" }
        }
        await #expect(throws: GleanerError.modelUnavailable("Apple Intelligence is off in Settings")) {
            _ = try await Gleaner(model: Off()).extract(Ideas.self, from: ["x"], goal: "x")
        }
    }
}
