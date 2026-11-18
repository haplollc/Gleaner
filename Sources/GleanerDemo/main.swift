import FoundationModels
import Foundation
import Gleaner

setvbuf(stdout, nil, _IONBF, 0)

// gleaner-demo [--posts 1200] [--searches 800] [--passes 1] [--deadline 420] [--skip-baseline] [--notes]
func argument(_ name: String, default value: Int) -> Int {
    if let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count, let v = Int(CommandLine.arguments[i + 1]) { return v }
    return value
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
func rule(_ title: String) { print("\n=== \(title) " + String(repeating: "=", count: max(3, 64 - title.count))) }
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

let model = FoundationModelsAdapter()
let availability = await model.availability()
rule("The model")
print("availability:", availability)
print("context window:", model.contextSize, "tokens")
guard availability.isAvailable else {
    print("Apple Intelligence is not available on this machine, so there is nothing real to run. Stopping.")
    exit(2)
}

let data = SampleData.make(posts: argument("--posts", default: 1200), searches: argument("--searches", default: 800))
let everything = data.all
let gleaner = Gleaner(model: model)
let goal = "Find gift ideas this person would love: specific things to buy that match what they like and search for."
let instructionsForBaseline = "You read numbered records. \(goal) Use only what the records say; copy names and details exactly. Skip anything the records do not support. If nothing fits, return an empty list."

rule("The data (invented)")
let estimator = await gleaner.estimator(sampling: everything)
let totalTokens = everything.reduce(0) { $0 + estimator.tokens($1) + 4 }
print("\(data.posts.count) liked posts + \(data.searches.count) searches = \(everything.count) records, about \(totalTokens) tokens")
print("that is about \(String(format: "%.1f", Double(totalTokens) / 4096))x the whole context window, before any instructions or answer")
print("sample:", data.posts[0], "|", data.searches[0])
print("planted interests:", SampleData.interests.map(\.name).joined(separator: ", "))

// MARK: Baseline: one prompt, truncated to fit

var baselineIdeas: [String] = []
var baselineSeconds = 0.0
var baselineTokens = 0
var baselineSeen = 0
if !flag("--skip-baseline") {
    rule("A. One prompt, truncated to fit")
    let budget = await gleaner.budget(instructions: instructionsForBaseline, output: Ideas.self)
    let first = Chunker.pack(everything, budget: budget.input, estimator: estimator).first!
    let prompt = "Records:\n\(first.numbered)\n\nTask: \(goal)"
    baselineSeen = first.texts.count
    baselineTokens = (await model.tokenCount(of: instructionsForBaseline) ?? 0) + (await model.tokenCount(of: prompt) ?? 0)
    print("fits \(baselineSeen) of \(everything.count) records (the newest \(String(format: "%.0f", 100 * Double(baselineSeen) / Double(everything.count)))%), \(baselineTokens) prompt tokens")
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let ideas = try await model.respond(Ideas.self, instructions: instructionsForBaseline, prompt: prompt, maxResponseTokens: nil)
        baselineSeconds = seconds(clock.now - start)
        baselineIdeas = ideas.items.map(\.line)
    } catch {
        baselineSeconds = seconds(clock.now - start)
        print("baseline call failed: \(error)")
    }
    print(String(format: "took %.1f s, 1 model call", baselineSeconds))
    for line in baselineIdeas { print("  -", line) }
}

// MARK: Gleaner: sections -> topics -> merge -> retrieval -> ideas

rule("B. Gleaner: read each section for topics, merge, then look up evidence per topic")
let deadline = Duration.seconds(argument("--deadline", default: 600))
let passes = argument("--passes", default: 2)
let clock = ContinuousClock()
let started = clock.now
@Sendable func show(_ p: GleanerProgress) {
    FileHandle.standardError.write(Data("  \(p.label): \(p.completed) of \(p.total)\n".utf8))
}
var calls = 0, cached = 0, promptTokens = 0, chunksRead = 0, chunksTotal = 0, splits = 0, skipped = 0
@MainActor func tally(_ r: RunReport) {
    calls += r.modelCalls; cached += r.cacheHits; promptTokens += r.promptTokens
    chunksRead += r.chunksRead; chunksTotal += r.chunksTotal; splits += r.splitRetries; skipped += r.skippedRecords
}

// Round 1: one pass per data section. Each reads every chunk and keeps at most 10 topics.
let topicGoal = "List this person's interests and hobbies, one entry per different interest, rare ones too. Ignore memes, news, weather and one-off errands."
var allTopics: [Topic] = []
let sections: [(String, [String])] = [("Reading your liked posts", data.posts), ("Reading your searches", data.searches)]
for (label, records) in sections {
    let remaining = deadline - (clock.now - started)
    let result = try await gleaner.extract(
        Topics.self, from: records, goal: topicGoal,
        options: ExtractOptions(label: label, deadline: remaining * 0.4, passes: passes, reduceTo: 10, progress: show)
    )
    print("\(label): \(result.items.count) topics. \(result.report)")
    print("   ", result.items.map(\.name).joined(separator: "; "))
    allTopics += result.items
    tally(result.report)
}
// Round 2: merge the sections' topics into one list of about 12.
let mergedTopics = try await gleaner.merge(Topics.self, allTopics, to: 12, goal: topicGoal,
                                           options: ExtractOptions(label: "Merging topics", deadline: deadline - (clock.now - started), progress: show))
tally(mergedTopics.report)
print("merged topics (\(mergedTopics.items.count)):", mergedTopics.items.map(\.name).joined(separator: "; "))

// Round 3: a local index of every record, then one small lookup + one small call per topic.
let t0 = clock.now
let index = NoteIndex()
await index.add(everything)
let indexSeconds = seconds(clock.now - t0)
print(String(format: "indexed %d unique records with %@ in %.1f s", await index.count, index.embedder.name, indexSeconds))
let giftInstructions = "You suggest gifts. Using only the numbered notes, suggest up to 2 specific things to buy for this interest. Each must be a product or experience, never a post title or a search."
var gleanerIdeas: [String] = []
for (i, topic) in mergedTopics.items.enumerated() {
    guard !(deadline - (clock.now - started) < .seconds(5)) else { break }
    show(GleanerProgress(stage: .answer, label: "Finding gifts for \(topic.name)", completed: i, total: mergedTopics.items.count, elapsed: 0))
    let found = try await gleaner.ask("Gift ideas for someone into \(topic.name)", as: Ideas.self, over: index, instructions: giftInstructions,
                                      options: AskOptions(deadline: .seconds(60), k: 14))
    tally(found.report)
    gleanerIdeas += found.answer.items.prefix(2).map(\.line)
}
let gleanerSeconds = seconds(clock.now - started)
print(String(format: "\ntotal %.1f s (index %.1f s), %d model calls, %d prompt tokens, %d/%d chunks read, %d split retries, %d skipped records", gleanerSeconds, indexSeconds, calls, promptTokens, chunksRead, chunksTotal, splits, skipped))
for line in gleanerIdeas { print("  -", line) }

// MARK: Second run: cache

rule("C. The same topic pass again (cache)")
let again = clock.now
let cachedRun = try await gleaner.extract(Topics.self, from: data.posts, goal: topicGoal,
                                          options: ExtractOptions(label: "Reading your liked posts", deadline: .seconds(60), passes: passes, reduceTo: 10))
print(String(format: "liked posts again: %.2f s, %d model calls, %d answers from cache", seconds(clock.now - again), cachedRun.report.modelCalls, cachedRun.report.cacheHits))

// MARK: Retrieval: ask over the raw records

rule("D. Ask questions over all \(everything.count) records (retrieval, no map step)")
for question in ["What does she do with film or cameras?", "Which birds or bird gear has she looked at?", "What should I get her for her birthday under $60?"] {
    let t = clock.now
    let answer = try await gleaner.ask(question, over: index)
    print("\nQ: \(question)")
    print("A: \(answer.text)")
    print(String(format: "   %.1f s, prompt tokens %d, %d notes packed", seconds(clock.now - t), answer.report.promptTokens, answer.sources.count))
}

// MARK: Optional running notes

if flag("--notes") {
    rule("E. Running notes over the newest 300 records")
    let notes = try await gleaner.runningNotes(Array(data.posts.prefix(300)), goal: "Note this person's interests, with the specifics.",
                                               options: NotesOptions(label: "Reading", deadline: .seconds(120), progress: show))
    print(notes.text)
    print(notes.report, "compactions:", notes.compactions)
}

// MARK: Score

rule("Scorecard (what each approach noticed, out of \(SampleData.interests.count) planted interests)")
func row(_ name: String, _ ideas: [String], _ secs: Double, _ calls: Int, _ tokens: Int, _ seen: String) {
    let covered = SampleData.covered(by: ideas)
    print("\(name)")
    print(String(format: "  interests noticed: %d/%d   grounded ideas: %.0f%%   ideas: %d   %.1f s   %d calls   %d prompt tokens   records read: %@",
                 covered.count, SampleData.interests.count, 100 * SampleData.grounded(ideas), ideas.count, secs, calls, tokens, seen))
    let missed = Set(SampleData.interests.map(\.name)).subtracting(covered)
    print("  missed: \(missed.isEmpty ? "none" : missed.sorted().joined(separator: ", "))")
}
if !baselineIdeas.isEmpty { row("A. One prompt, truncated", baselineIdeas, baselineSeconds, 1, baselineTokens, "\(baselineSeen)/\(everything.count)") }
row("B. Gleaner", gleanerIdeas, gleanerSeconds, calls, promptTokens, "\(everything.count)/\(everything.count) (\(chunksRead)/\(chunksTotal) chunks)")
