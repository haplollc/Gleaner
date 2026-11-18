import Foundation
import FoundationModels
@testable import Gleaner

/// The numbered records inside a prompt that has a "Records:" block.
func recordTexts(in prompt: String) -> [String] {
    guard let start = prompt.range(of: "Records:\n") else { return [] }
    let block = prompt[start.upperBound...].components(separatedBy: "\n\n").first ?? ""
    return block.split(separator: "\n").map { line in
        if let dot = line.range(of: ". ") { return String(line[dot.upperBound...]) }
        return String(line)
    }
}

/// A model that "finds" one idea per record, titled with the record's text.
func echoModel(contextSize: Int = 4096, charsPerToken: Double = 4, onStructured: (@Sendable (ScriptedCall) throws -> Void)? = nil) -> ScriptedModel {
    ScriptedModel(contextSize: contextSize, charsPerToken: charsPerToken, structured: { call in
        try onStructured?(call)
        if call.instructions.hasPrefix("You merge lists") {
            let lines = call.prompt.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
            let keep = Int(call.instructions.components(separatedBy: "at most ").last?.components(separatedBy: " ").first ?? "") ?? 3
            return Ideas(items: lines.prefix(keep).map { Idea(title: String($0.split(separator: ":").first ?? ""), why: "merged") })
        }
        return Ideas(items: recordTexts(in: call.prompt).map { Idea(title: $0, why: "seen") })
    })
}

func sampleRecords(_ n: Int, width: Int = 1) -> [String] {
    (0..<n).map { "record-\($0)" + String(repeating: " filler", count: width) }
}
