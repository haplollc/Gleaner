import Foundation

extension Gleaner {
    /// Reads records in order, keeping a short set of running notes that rides along in every prompt: the
    /// Chain-of-Agents idea (Zhang et al., 2024) with one model playing every worker. Each step sees the notes so
    /// far plus one new chunk and writes the updated notes. When the notes outgrow their budget they are compacted.
    ///
    /// Use it when order matters or facts build on each other. For independent records, `extract` is faster to merge.
    public func runningNotes(
        _ records: [String], goal: String, options: NotesOptions = NotesOptions()
    ) async throws -> Notes {
        try await requireAvailable()
        let run = RunRecorder(deadline: options.deadline, progress: options.progress)
        let estimator = await estimator(sampling: records)
        let words = max(30, Int(Double(options.noteTokens) * 0.7))
        let stepIns = "You keep running notes while reading numbered records. Goal: \(goal) Update the notes with what the new records add. Keep specific names, numbers and repeated patterns; drop one-off noise. Use short lines. Stay under \(words) words. Reply with the notes only."
        let compactIns = "You shorten notes. Keep the most specific and most repeated facts that serve this goal: \(goal) Use short lines. Stay under \(words) words. Reply with the notes only."
        // Reserve room in every prompt for a full set of notes and for the rewritten ones.
        let budget = await textBudget(instructions: stepIns, outputReserve: options.noteTokens + 60, extraFixed: options.noteTokens + 20)
        let chunks = Chunker.pack(records, budget: budget.input, estimator: estimator)
        run.update { $0.chunksTotal = chunks.count }

        var notes = ""
        var trail: [String] = []
        var compactions = 0
        for (i, chunk) in chunks.enumerated() {
            run.progress(.notes, options.label, i, chunks.count)
            if run.isExpired { run.update { $0.deadlineHit = true }; break }
            let prompt = "Notes so far:\n\(notes.isEmpty ? "(none yet)" : notes)\n\nNew records:\n\(chunk.numbered)\n\nWrite the updated notes."
            do {
                notes = try await text(instructions: stepIns, prompt: prompt, maxTokens: options.noteTokens + 60, run: run)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                throw CancellationError()
            } catch GleanerError.deadlineReached {
                run.update { $0.deadlineHit = true }
                break
            } catch {
                run.update { $0.failures += 1; $0.skippedRecords += chunk.texts.count }
                continue   // keep the notes as they were and move on
            }
            run.update { $0.chunksRead += 1 }
            if await measurer.count(notes, model: model) > Int(Double(options.noteTokens) * 1.15) {
                compactions += 1
                run.progress(.compact, options.label, i, chunks.count)
                if let shorter = try? await text(instructions: compactIns, prompt: "Notes:\n\(notes)\n\nShorten them.", maxTokens: options.noteTokens, run: run) {
                    notes = shorter.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // If the model would not shorten them, cut hard so they can never crowd out the data.
                if estimator.tokens(notes) > options.noteTokens { notes = estimator.truncate(notes, toTokens: options.noteTokens) }
            }
            trail.append(notes)
        }
        run.progress(.notes, options.label, chunks.count, chunks.count)
        return Notes(text: notes, trail: trail, compactions: compactions, report: run.snapshot())
    }
}
