import Foundation
import FoundationModels

/// "Open Notes, and once you're there create a new note" → ["Open Notes", "create a new note in Notes"].
/// One spoken sentence often carries several commands; the router handles one at a time.
enum StepSplitter {
    @Generable
    struct Steps {
        @Guide(description: "The separate commands, in the order they should run. One entry when the sentence is a single command.")
        var steps: [String]
    }

    /// A joining word that could carry a second command. Without one the sentence is routed as is (no model call, no delay).
    /// English plus Lithuanian ("ir", "tada", "po to"). Bare "and" only counts before a verb: "Slack and Safari side by side" is one command.
    private static let conjunction = #/\b(then|after|also|once|before|ir|tada|po to|, and|and (open|close|create|make|go|type|write|search|take|play|send|put|click|turn|set|switch|show|start|stop|add|remove|delete|move|resize|find|tell|say|press|scroll))\b/#
    nonisolated static func hasConjunction(_ text: String) -> Bool {
        text.lowercased().firstMatch(of: conjunction) != nil
    }

    static func split(_ text: String) async -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.split(separator: " ").count >= 5, hasConjunction(t) else { return [t] }
        if SystemLanguageModel.default.isAvailable, let steps = await model(t), steps.count > 1 { return steps }
        return heuristic(t)
    }

    private static func model(_ t: String) async -> [String]? {
        let session = LanguageModelSession(instructions: """
        You split one spoken request to a Mac voice assistant into separate commands, in order. Each command must stand alone: \
        replace "there", "it", "this one" with the app or thing named earlier ("once you're there, create a note" → "create a new note in Notes"). \
        Keep the user's words otherwise; never add steps, never drop a request. Leave out pure acknowledgments ("great", "thank you", "um"). \
        If a later step searches or acts on a site opened earlier, name the site in that step ("open LinkedIn and search chaseit" → "search chaseit on LinkedIn"). \
        A single command stays a single entry.
        """)
        guard let r = try? await session.respond(to: "Request: “\(t)”", generating: Steps.self, options: GenerationOptions(temperature: 0)) else { return nil }
        let steps = r.content.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”."))) }.filter { $0.count > 2 }
        guard (1...5).contains(steps.count) else { return nil }
        // The model's words only when it actually split something; a single command keeps your exact phrasing.
        if steps.count == 1 { return [t] }
        // It may add words ("in Notes") but must not lose any you said ("open notes…" → "create a new note" dropped "open").
        return covers(steps, t) ? steps : nil
    }

    /// Joining and pointing words the split is allowed to drop or replace.
    private static let droppable: Set<String> = ["and", "then", "after", "that", "afterwards", "also", "once", "you're", "youre", "you", "are", "there",
                                                 "it", "this", "one", "the", "a", "an", "please", "ok", "okay", "um", "uh", "great", "thanks", "thank", "ir", "tada", "po", "to"]
    private static func covers(_ steps: [String], _ original: String) -> Bool {
        func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init) }
        let out = Set(steps.flatMap(words))
        return words(original).allSatisfy { w in droppable.contains(w) || out.contains(w) || (w.count > 3 && out.contains { $0.hasPrefix(w.prefix(4)) }) }
    }

    private static func heuristic(_ t: String) -> [String] {
        let parts: [String] = t.split(separator: #/,?\s+(?:and then|then|after that|afterwards|and once you're there,?|once you're there,?|and also|ir tada|tada|po to)\s+|,?\s+and\s+(?=(?:open|close|create|make|go|type|write|search|take|play|send|put|click|turn|set|switch|show|start|stop|add|remove|move|find|press|scroll)\b)/#.ignoresCase())
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.count > 1 ? parts : [t]
    }
}
