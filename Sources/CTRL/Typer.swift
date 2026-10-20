import AppKit

/// "Type see you at 5" → types "see you at 5" where your cursor is.
/// Code pulls the text out (Jev only decides that it's a typing command), so nothing gets rephrased.
@MainActor
enum Typer {
    /// Words that start dictation, longest first so "type in" beats "type".
    private static let triggers = ["type out", "type in", "type", "write down", "write", "enter", "input", "dictate", "insert", "spell"]
    private static let sendSuffix = #/[,.]?\s*(and|then)?\s*(press|hit)\s+(enter|return|send)\s*[.!]?$|[,.]?\s*(and|then)\s+send( it)?\s*[.!]?$/#

    struct Text { let text: String; let pressReturn: Bool }

    static func hasTrigger(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        return triggers.contains { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    /// Jev picks where the text to type starts: "enter my email armandas@…" → starts at "armandas@…".
    static func startQuestion(_ transcript: String) -> (TypeSafeClient.Question, [String: String.Index])? {
        var opts: [String: String] = [:]
        var starts: [String: String.Index] = [:]
        var i = 0
        transcript.enumerateSubstrings(in: transcript.startIndex..., options: .byWords) { word, range, _, stop in
            guard let word, i < 60 else { stop = true; return }
            let rest = transcript[range.lowerBound...].prefix(40)
            opts["w\(i)"] = "start typing from word \(i + 1), “\(word)”, so the typed text begins: “\(rest)”"
            starts["w\(i)"] = range.lowerBound
            i += 1
        }
        guard opts.count > 1 else { return nil }
        return (.choice("The user is dictating text to type. Which word does the text to type begin with? Skip the command words (type, write, enter…) and descriptions like 'my email' or 'the following'.", options: opts), starts)
    }

    /// From a start index: the rest, with "…and press enter" split off.
    static func extract(_ transcript: String, from start: String.Index) -> Text? {
        finish(String(transcript[start...]))
    }

    /// Text after the trigger word, with "…and press enter" split off.
    static func extract(_ transcript: String) -> Text? {
        let lower = transcript.lowercased()
        var start: String.Index?
        for t in triggers {
            // Whole word only ("typewriter" isn't "type").
            if let r = lower.range(of: "\\b\(t)\\b[:,]?\\s*", options: .regularExpression) {
                if start == nil || r.lowerBound < start! { start = r.upperBound }
                break
            }
        }
        guard let start else { return nil }
        return finish(String(transcript[start...]))
    }

    private static func finish(_ raw: String) -> Text? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var pressReturn = false
        if let m = text.lowercased().firstMatch(of: sendSuffix) {
            let cut = text.index(text.startIndex, offsetBy: text.lowercased().distance(from: text.lowercased().startIndex, to: m.range.lowerBound))
            text = String(text[..<cut])
            pressReturn = true
        }
        // Strip quotes the transcriber sometimes adds.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces))
        guard !text.isEmpty else { return nil }
        return Text(text: text, pressReturn: pressReturn)
    }

    /// Types Unicode text into the focused field (any language, emoji; no clipboard involved).
    static func type(_ text: String, pressReturn: Bool) async {
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])   // apps drop longer strings per event
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []   // ⌥ may still be held from the hotkey
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            i += 16
            try? await Task.sleep(for: .milliseconds(8))
        }
        if pressReturn {
            try? await Task.sleep(for: .milliseconds(60))
            Keys.press(36, flags: [])   // Return
        }
    }
}
