import Foundation
import FoundationModels

extension Gleaner {
    /// Pulls structured items out of a big pile of records that does not fit the window.
    ///
    /// 1. Measure the budget (window minus instructions, schema, answer room and a margin).
    /// 2. Pack the records into chunks that fit it.
    /// 3. Map: read each chunk with a fresh session; on overflow or a guardrail error, halve the chunk and retry.
    /// 4. Dedupe, then tree-reduce when `options.reduceTo` is set.
    /// 5. Optionally repeat with shifted chunks, telling the model what it already found (`options.passes`).
    public func extract<B: BatchOutput>(
        _ batch: B.Type, from records: [String], goal: String, options: ExtractOptions = ExtractOptions()
    ) async throws -> Extraction<B.Item> {
        try await requireAvailable()
        let run = RunRecorder(deadline: options.deadline, progress: options.progress)
        let instructions = Self.extractInstructions(goal)
        let estimator = await estimator(sampling: records)
        let budget = await budget(instructions: instructions, output: batch)

        var pool: [B.Item] = []
        var seen = Set<String>()
        func absorb(_ items: [B.Item]) {
            for item in items where seen.insert(Self.key(item.line)).inserted { pool.append(item) }
        }

        let passes = max(1, options.passes)
        var chunksTotal = 0
        var chunksRead = 0
        for pass in 0..<passes {
            if pass > 0, run.isExpired { break }
            // Later passes shift the chunk boundaries by half a chunk and say what is already known.
            var rotated = records
            if pass > 0, !records.isEmpty {
                let first = Chunker.pack(records, budget: budget.input, estimator: estimator, maxRecords: options.maxRecordsPerChunk).first?.texts.count ?? 1
                let shift = (first / 2) * pass % max(1, records.count)
                rotated = Array(records[shift...] + records[..<shift])
            }
            let known = pass == 0 ? "" : Self.knownList(pool, budgetTokens: budget.input / 4, estimator: estimator)
            let perChunk = budget.spending(estimator.tokens(known) + 24)
            let chunks = Chunker.pack(rotated, budget: perChunk.input, estimator: estimator, maxRecords: options.maxRecordsPerChunk)
            chunksTotal += chunks.count
            run.update { $0.chunksTotal = chunksTotal }

            // Keep a share of the deadline for merging.
            let reserve: TimeInterval = options.reduceTo != nil ? (run.remaining ?? 0) * 0.25 : 0
            let label = passes > 1 ? "\(options.label) (round \(pass + 1) of \(passes))" : options.label
            var done = 0
            var next = 0
            var finished: [Int: [B.Item]] = [:]
            var readThisPass = 0
            try await withThrowingTaskGroup(of: (Int, [B.Item]?).self) { group in
                func launch() {
                    guard next < chunks.count else { return }
                    let i = next
                    next += 1
                    let chunk = chunks[i]
                    group.addTask { [self] in
                        if let left = run.remaining, left < reserve { run.update { $0.deadlineHit = true }; return (i, nil) }
                        do {
                            return (i, try await self.mapChunk(batch, chunk, instructions: instructions, known: known, goal: goal, depth: 0, run: run))
                        } catch GleanerError.deadlineReached {
                            run.update { $0.deadlineHit = true }
                            return (i, nil)
                        }
                    }
                }
                for _ in 0..<min(max(1, configuration.concurrency), chunks.count) { launch() }
                run.progress(.map, label, 0, chunks.count)
                for try await (i, items) in group {
                    finished[i] = items ?? []
                    done += 1
                    if items != nil { readThisPass += 1 }
                    run.progress(.map, label, done, chunks.count)
                    launch()
                }
            }
            chunksRead += readThisPass
            for i in 0..<chunks.count { absorb(finished[i] ?? []) }
        }

        var result = pool
        if let target = options.reduceTo, pool.count > target {
            result = try await reduce(batch, pool, target: target, goal: goal, estimator: estimator, label: options.label, run: run)
        }
        var report = run.snapshot()
        report.chunksTotal = chunksTotal
        report.chunksRead = chunksRead
        return Extraction(items: result, report: report)
    }

    // MARK: Map

    func mapChunk<B: BatchOutput>(
        _ batch: B.Type, _ chunk: Chunk, instructions: String, known: String, goal: String, depth: Int, run: RunRecorder
    ) async throws -> [B.Item] {
        var prompt = "Records:\n\(chunk.numbered)"
        if !known.isEmpty { prompt += "\n\nAlready found (do not repeat, look for different things):\n\(known)" }
        prompt += "\n\nTask: \(goal)"
        var attempts = 0
        while true {
            do {
                return try await structured(batch, instructions: instructions, prompt: prompt, run: run).items
            } catch let e as ModelFailure where e == .busy && attempts < 2 {
                attempts += 1
                try await Task.sleep(for: .seconds(1))
            } catch let e as ModelFailure where e == .contextOverflow || e == .guardrail {
                return try await splitOrSkip(batch, chunk, instructions: instructions, known: known, goal: goal, depth: depth, run: run)
            } catch GleanerError.promptTooLarge {
                return try await splitOrSkip(batch, chunk, instructions: instructions, known: known, goal: goal, depth: depth, run: run)
            } catch GleanerError.deadlineReached {
                throw GleanerError.deadlineReached
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A timeout, a refusal or an unreadable answer: skip this chunk, keep the run going.
                run.update { $0.failures += 1; $0.skippedRecords += chunk.texts.count }
                return []
            }
        }
    }

    private func splitOrSkip<B: BatchOutput>(
        _ batch: B.Type, _ chunk: Chunk, instructions: String, known: String, goal: String, depth: Int, run: RunRecorder
    ) async throws -> [B.Item] {
        guard depth < configuration.maxSplitDepth, let halves = Chunker.halves(of: chunk) else {
            run.update { $0.failures += 1; $0.skippedRecords += chunk.texts.count }
            return []
        }
        run.update { $0.splitRetries += 1 }
        var out: [B.Item] = []
        for half in halves {
            out += try await mapChunk(batch, half, instructions: instructions, known: known, goal: goal, depth: depth + 1, run: run)
        }
        return out
    }

    // MARK: Reduce

    /// Merges a long item list down to about `target` items: pack the lines into groups that fit, merge each group
    /// with one call, and repeat on the results until one call can take them all. Groups and results keep their order.
    func reduce<B: BatchOutput>(
        _ batch: B.Type, _ items: [B.Item], target: Int, goal: String, estimator: TokenEstimator, label: String, run: RunRecorder
    ) async throws -> [B.Item] {
        var current = items
        var level = 0
        while current.count > target, level < 5 {
            level += 1
            let lines = current.map(\.line)
            let keepFinal = target
            let instructionsFinal = Self.reduceInstructions(goal, keep: keepFinal)
            let budget = await budget(instructions: instructionsFinal, output: batch)
            let groups = Chunker.pack(lines, budget: budget.input, estimator: estimator)
            let isFinal = groups.count <= 1
            var merged: [B.Item] = []
            for (g, group) in groups.enumerated() {
                run.progress(.reduce, "\(label): merging", g, groups.count)
                if run.isExpired { run.update { $0.deadlineHit = true }; merged += group.indices.map { current[$0] }; continue }
                let keep = isFinal ? keepFinal : max(3, Int((Double(group.texts.count) * 0.5).rounded(.up)))
                let prompt = "Items:\n" + group.texts.map { "- \($0)" }.joined(separator: "\n") + "\n\nMerge duplicates. Keep the best \(keep)."
                do {
                    merged += try await structured(batch, instructions: Self.reduceInstructions(goal, keep: keep), prompt: prompt, run: run).items
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The merge failed: keep this group's items as they were rather than losing them.
                    run.update { $0.failures += 1 }
                    merged += group.indices.map { current[$0] }
                }
            }
            var seen = Set<String>()
            let deduped = merged.filter { seen.insert(Self.key($0.line)).inserted }
            run.progress(.reduce, "\(label): merging", groups.count, groups.count)
            if isFinal { return deduped }
            // No progress (the model returned everything): stop shrinking and cut by order.
            if deduped.count >= current.count { current = Array(deduped.prefix(max(target, deduped.count * 3 / 4))); if current.count <= target { break } }
            else { current = deduped }
        }
        return Array(current.prefix(max(target, 1)))
    }

    // MARK: Prompts

    static func extractInstructions(_ goal: String) -> String {
        "You read numbered records. \(goal) Use only what the records say; copy names and details exactly. Skip anything the records do not support. If nothing fits, return an empty list."
    }

    static func reduceInstructions(_ goal: String, keep: Int) -> String {
        "You merge lists. Goal: \(goal) Combine duplicates and near-duplicates into one item with the most specific wording. Drop weak or generic items. Do not invent anything. Return at most \(keep) items."
    }

    static func knownList<I: LineRenderable>(_ items: [I], budgetTokens: Int, estimator: TokenEstimator) -> String {
        var lines: [String] = []
        var used = 0
        for item in items {
            let line = "- " + estimator.truncate(item.line, toTokens: 18)
            let cost = estimator.tokens(line) + 1
            if used + cost > budgetTokens { break }
            lines.append(line)
            used += cost
        }
        return lines.joined(separator: "\n")
    }

    /// A case, punctuation and plural insensitive key for deduping lines.
    static func key(_ line: String) -> String { Terms.of(line).joined(separator: " ") }
}
