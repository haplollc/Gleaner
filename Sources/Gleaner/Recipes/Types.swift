import Foundation
import FoundationModels

/// Something an extraction found, as one line of text. Gleaner uses the line to dedupe items and to feed them
/// back to the model when it merges lists.
public protocol LineRenderable: Sendable {
    var line: String { get }
}

/// What the model returns for one chunk: a list of items.
///
/// Make your own by marking a struct `@Generable` and adding `items`:
///
/// ```swift
/// @Generable struct Brands: BatchOutput {
///     @Guide(description: "Brands the person follows", .maximumCount(8))
///     var items: [Brand]
/// }
/// ```
public protocol BatchOutput: Generable, Sendable {
    associatedtype Item: LineRenderable
    var items: [Item] { get }
}

// MARK: - Built in shapes

/// A gift idea, or any idea with a reason.
@Generable
public struct Idea: LineRenderable {
    @Guide(description: "The thing itself, two to six words")
    public var title: String
    @Guide(description: "Why it fits, one short sentence that uses the records")
    public var why: String

    public init(title: String, why: String) { self.title = title; self.why = why }
    public var line: String { "\(title): \(why)" }
}

@Generable
public struct Ideas: BatchOutput {
    @Guide(description: "Ideas that the records support, best first", .maximumCount(6))
    public var items: [Idea]

    public init(items: [Idea]) { self.items = items }
}

/// A short fact about something in the records.
@Generable
public struct Fact: LineRenderable {
    @Guide(description: "One fact, copied or tightly paraphrased from a record")
    public var statement: String

    public init(statement: String) { self.statement = statement }
    public var line: String { statement }
}

@Generable
public struct Facts: BatchOutput {
    @Guide(description: "Facts the records state, most useful first", .maximumCount(8))
    public var items: [Fact]

    public init(items: [Fact]) { self.items = items }
}

// MARK: - Results

/// The outcome of `Gleaner.extract`.
public struct Extraction<Item: Sendable>: Sendable {
    public var items: [Item]
    public var report: RunReport
    /// Share of chunks read before the deadline (1 means everything was read).
    public var coverage: Double { report.chunksTotal > 0 ? Double(report.chunksRead) / Double(report.chunksTotal) : 1 }
}

public struct Summary: Sendable {
    public var text: String
    /// How many rounds of summarising it took (1 means one call).
    public var levels: Int
    public var report: RunReport
}

public struct Notes: Sendable {
    public var text: String
    /// The notes after each chunk, so you can show them growing or debug a drift.
    public var trail: [String]
    public var compactions: Int
    public var report: RunReport
}

public struct Answer: Sendable {
    public var text: String
    /// The notes that were put in front of the model.
    public var sources: [NoteHit]
    public var report: RunReport
}

// MARK: - Options

public struct ExtractOptions: Sendable {
    /// Shown in progress updates, e.g. "Reading your Google searches".
    public var label = "Reading"
    /// Total time allowed. Reading stops early when it runs low and the rest is merged; `report.deadlineHit` says so.
    public var deadline: Duration?
    /// Rounds of reading. Later rounds are told what was already found and read the data with shifted chunk
    /// boundaries, so they look for what the first round missed.
    public var passes = 1
    /// Merge the pooled items down to about this many with a tree reduce. `nil` keeps every unique item.
    public var reduceTo: Int?
    public var maxRecordsPerChunk: Int?
    public var progress: ProgressHandler?

    public init(label: String = "Reading", deadline: Duration? = nil, passes: Int = 1, reduceTo: Int? = nil,
                maxRecordsPerChunk: Int? = nil, progress: ProgressHandler? = nil) {
        self.label = label; self.deadline = deadline; self.passes = passes; self.reduceTo = reduceTo
        self.maxRecordsPerChunk = maxRecordsPerChunk; self.progress = progress
    }
}

public struct SummarizeOptions: Sendable {
    public var label = "Summarizing"
    public var deadline: Duration?
    /// The size of the final summary, in tokens.
    public var targetTokens = 250
    /// The size of each intermediate summary, in tokens.
    public var chunkSummaryTokens = 160
    public var progress: ProgressHandler?

    public init(label: String = "Summarizing", deadline: Duration? = nil, targetTokens: Int = 250,
                chunkSummaryTokens: Int = 160, progress: ProgressHandler? = nil) {
        self.label = label; self.deadline = deadline; self.targetTokens = targetTokens
        self.chunkSummaryTokens = chunkSummaryTokens; self.progress = progress
    }
}

public struct NotesOptions: Sendable {
    public var label = "Reading"
    public var deadline: Duration?
    /// The most tokens the running notes may take. They are compacted when they grow past this.
    public var noteTokens = 450
    public var progress: ProgressHandler?

    public init(label: String = "Reading", deadline: Duration? = nil, noteTokens: Int = 450, progress: ProgressHandler? = nil) {
        self.label = label; self.deadline = deadline; self.noteTokens = noteTokens; self.progress = progress
    }
}

public struct AskOptions: Sendable {
    public var label = "Looking things up"
    public var deadline: Duration?
    /// How many notes to retrieve before packing.
    public var k = 20
    public var mode: SearchMode = .hybrid()
    /// The most tokens the answer may take.
    public var answerTokens = 300
    public var progress: ProgressHandler?

    public init(label: String = "Looking things up", deadline: Duration? = nil, k: Int = 20, mode: SearchMode = .hybrid(),
                answerTokens: Int = 300, progress: ProgressHandler? = nil) {
        self.label = label; self.deadline = deadline; self.k = k; self.mode = mode
        self.answerTokens = answerTokens; self.progress = progress
    }
}
