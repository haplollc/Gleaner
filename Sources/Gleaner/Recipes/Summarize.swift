import Foundation

extension Gleaner {
    /// Summarizes more text than fits the window, level by level: summarize each chunk, then summarize the
    /// summaries, until one call can take what is left (the hierarchical approach Apple's own TN3193 describes,
    /// and the one in Wu et al. 2021).
    public func summarize(
        _ records: [String], goal: String = "Summarize what these records say.", options: SummarizeOptions = SummarizeOptions()
    ) async throws -> Summary {
        try await requireAvailable()
        let run = RunRecorder(deadline: options.deadline, progress: options.progress)
        let estimator = await estimator(sampling: records)
        let chunkWords = max(20, Int(Double(options.chunkSummaryTokens) * 0.7))
        let finalWords = max(20, Int(Double(options.targetTokens) * 0.7))
        let chunkIns = "You summarize numbered records in about \(chunkWords) words. Keep names, numbers and specifics. Do not add anything. Goal: \(goal)"
        let finalIns = "You write one summary of about \(finalWords) words from the notes you are given. Keep the most specific and most repeated facts. Do not add anything. Goal: \(goal)"
        let chunkBudget = await textBudget(instructions: chunkIns, outputReserve: options.chunkSummaryTokens + 40)
        let finalBudget = await textBudget(instructions: finalIns, outputReserve: options.targetTokens + 40)

        var texts = records
        var level = 0
        var chunksTotal = 0
        var chunksRead = 0
        while true {
            level += 1
            let single = Chunker.pack(texts, budget: finalBudget.input, estimator: estimator)
            if single.count <= 1 {
                let body = single.first?.numbered ?? ""
                chunksTotal += 1
                let text = try await self.text(instructions: finalIns, prompt: "Records:\n\(body)\n\nWrite the summary.", maxTokens: options.targetTokens + 40, run: run)
                chunksRead += 1
                run.progress(.summarize, options.label, 1, 1)
                var report = run.snapshot()
                report.chunksTotal = chunksTotal; report.chunksRead = chunksRead
                return Summary(text: text.trimmingCharacters(in: .whitespacesAndNewlines), levels: level, report: report)
            }
            let chunks = Chunker.pack(texts, budget: chunkBudget.input, estimator: estimator)
            chunksTotal += chunks.count
            var next: [String] = []
            for (i, chunk) in chunks.enumerated() {
                run.progress(.summarize, "\(options.label) (level \(level))", i, chunks.count)
                if run.isExpired {
                    // Out of time: pass the chunk's first lines through so nothing silently vanishes.
                    run.update { $0.deadlineHit = true }
                    next.append(estimator.truncate(chunk.texts.joined(separator: " "), toTokens: options.chunkSummaryTokens))
                    continue
                }
                do {
                    next.append(try await self.summarizeChunk(chunk, instructions: chunkIns, maxTokens: options.chunkSummaryTokens + 40, depth: 0, run: run))
                    chunksRead += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    run.update { $0.failures += 1 }
                    next.append(estimator.truncate(chunk.texts.joined(separator: " "), toTokens: options.chunkSummaryTokens))
                }
            }
            run.progress(.summarize, "\(options.label) (level \(level))", chunks.count, chunks.count)
            let before = texts.reduce(0) { $0 + estimator.tokens($1) }
            let after = next.reduce(0) { $0 + estimator.tokens($1) }
            texts = next.filter { !$0.isEmpty }
            // Guard against a level that did not shrink anything.
            if after >= before || level >= 8 {
                texts = [estimator.truncate(texts.joined(separator: " "), toTokens: finalBudget.input)]
            }
        }
    }

    private func summarizeChunk(_ chunk: Chunk, instructions: String, maxTokens: Int, depth: Int, run: RunRecorder) async throws -> String {
        do {
            return try await text(instructions: instructions, prompt: "Records:\n\(chunk.numbered)\n\nWrite the summary.", maxTokens: maxTokens, run: run)
        } catch let e as ModelFailure where e == .contextOverflow || e == .guardrail {
            guard depth < configuration.maxSplitDepth, let halves = Chunker.halves(of: chunk) else { throw e }
            run.update { $0.splitRetries += 1 }
            var parts: [String] = []
            for half in halves { parts.append(try await summarizeChunk(half, instructions: instructions, maxTokens: maxTokens, depth: depth + 1, run: run)) }
            return parts.joined(separator: " ")
        }
    }
}
