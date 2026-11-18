import CryptoKit
import Foundation

// MARK: - Errors

/// What Gleaner itself throws (model failures are `ModelFailure`).
public enum GleanerError: Error, Sendable, Equatable, LocalizedError {
    case modelUnavailable(String)
    case promptTooLarge(tokens: Int, budget: Int)
    case timedOut
    case deadlineReached

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let why): "The model is unavailable: \(why)"
        case .promptTooLarge(let t, let b): "The prompt needs \(t) tokens but only \(b) fit."
        case .timedOut: "A model call took too long."
        case .deadlineReached: "The time budget ran out."
        }
    }
}

// MARK: - Progress

/// What a recipe is doing, for a progress screen ("Reading your Google searches... 3 of 9").
public struct GleanerProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case map, reduce, notes, compact, summarize, retrieve, answer }
    public var stage: Stage
    /// The label you passed to the recipe, e.g. "Reading your Google searches".
    public var label: String
    public var completed: Int
    public var total: Int
    public var elapsed: TimeInterval

    public init(stage: Stage, label: String, completed: Int, total: Int, elapsed: TimeInterval = 0) {
        self.stage = stage; self.label = label; self.completed = completed; self.total = total; self.elapsed = elapsed
    }

    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

public typealias ProgressHandler = @Sendable (GleanerProgress) -> Void

// MARK: - Report

/// The cost of one recipe call. Print it, log it, show it in a debug screen.
public struct RunReport: Sendable, Equatable, CustomStringConvertible {
    public var modelCalls = 0
    public var cacheHits = 0
    /// Prompt tokens sent (measured when the model can count, estimated otherwise).
    public var promptTokens = 0
    public var biggestPrompt = 0
    /// Chunks the input became, and how many were read before the deadline.
    public var chunksTotal = 0
    public var chunksRead = 0
    /// Calls that were split in two after an overflow or a guardrail error.
    public var splitRetries = 0
    /// Records dropped because even alone they failed or did not fit.
    public var skippedRecords = 0
    public var failures = 0
    public var deadlineHit = false
    public var seconds: TimeInterval = 0

    public init() {}

    public var description: String {
        "calls \(modelCalls) (+\(cacheHits) cached), prompt tokens \(promptTokens), biggest prompt \(biggestPrompt), "
        + "chunks \(chunksRead)/\(chunksTotal), split retries \(splitRetries), skipped \(skippedRecords), failures \(failures), "
        + "\(deadlineHit ? "deadline hit, " : "")\(String(format: "%.1f", seconds)) s"
    }
}

/// Collects a report and sends progress. One per recipe call.
final class RunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var report = RunReport()
    private let started = Date()
    private let progressHandler: ProgressHandler?
    let deadline: Date?

    init(deadline: Duration?, progress: ProgressHandler?) {
        self.progressHandler = progress
        if let deadline {
            let c = deadline.components
            self.deadline = Date().addingTimeInterval(Double(c.seconds) + Double(c.attoseconds) / 1e18)
        } else {
            self.deadline = nil
        }
    }

    func update(_ change: (inout RunReport) -> Void) { lock.withLock { change(&report) } }
    func snapshot() -> RunReport { lock.withLock { var r = report; r.seconds = Date().timeIntervalSince(started); return r } }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    /// Seconds left, or `nil` with no deadline.
    var remaining: TimeInterval? { deadline.map { $0.timeIntervalSinceNow } }
    var isExpired: Bool { (remaining ?? 1) <= 0 }

    func progress(_ stage: GleanerProgress.Stage, _ label: String, _ done: Int, _ total: Int) {
        progressHandler?(GleanerProgress(stage: stage, label: label, completed: done, total: total, elapsed: elapsed))
    }
}

// MARK: - Gate (back-pressure)

/// A first-in-first-out semaphore. The on-device model effectively answers one request at a time,
/// so the default is one permit; more callers wait their turn instead of failing with "busy".
actor Gate {
    private var free: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(permits: Int) { free = max(1, permits) }

    func acquire() async throws {
        try Task.checkCancellation()
        if free > 0 { free -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: i).continuation.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Cache

/// Where answers are kept so a re-run on the same input costs nothing.
public protocol ResultCache: Sendable {
    func value(for key: String) async -> String?
    func store(_ value: String, for key: String) async
}

/// Keeps answers in memory for the life of the process.
public actor MemoryCache: ResultCache {
    private var values: [String: String] = [:]
    public init() {}
    public func value(for key: String) -> String? { values[key] }
    public func store(_ value: String, for key: String) { values[key] = value }
    public var count: Int { values.count }
}

/// Keeps answers as small files in a directory, so they survive relaunches.
public struct DiskCache: ResultCache {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func value(for key: String) async -> String? {
        try? String(contentsOf: directory.appendingPathComponent(key), encoding: .utf8)
    }

    public func store(_ value: String, for key: String) async {
        try? value.write(to: directory.appendingPathComponent(key), atomically: true, encoding: .utf8)
    }
}

enum Hashing {
    /// A stable SHA-256 hex digest of the parts, in order.
    static func key(_ parts: String...) -> String {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0x1F]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
