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

    /// "Type …", "Please type …", "Dictate …" — unambiguous typing, whatever follows.
    static func startsWithTrigger(_ transcript: String) -> Bool {
        transcript.lowercased().firstMatch(of: #/^\W*((please|can you|could you|now|and|okay|ok)[ ,]+)*(type|dictate)\b/#) != nil
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

    private static func finish(_ raw: String) -> Text? { finishText(raw).flatMap { $0.text.isEmpty ? nil : $0 } }

    /// ~/Library/Logs/Butterfly/typing.log: what was heard and what was typed (to debug the cleaner).
    private static func log(_ kind: String, raw: String, out: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("typing.log")
        let line = Data("\(Date().formatted(.iso8601)) \(kind) in:  “\(raw)”\n\(String(repeating: " ", count: 26))out: “\(out)”\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }

    /// Spoken text as written text: no "um"/"uh", no stutters ("I I think" → "I think"), tidy punctuation.
    static func clean(_ raw: String) -> String {
        var t = raw
        // Fillers, with the comma or period the recognizer attached to them.
        let filler = #"(um+|uh+|uhm+|er+m*|hm+|mm+|ah+|eh+|ehm+)"#
        // ", um, " between two commas: drop both, unless the word before is a discourse marker whose comma should stay ("Okay, um, just…").
        t = t.replacingOccurrences(of: #"(?i)\b(okay|ok|well|so|yes|no|right|now|alright|actually|anyway),\s*"# + filler + #",\s*"#, with: "$1, ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i),\s*"# + filler + #",(?=\s)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)(^|[\s,.])"# + filler + #"([,.]?)(?=\s|$|[,.!?])"#, with: "$1", options: .regularExpression)
        // Doubled words ("the the", "I I", "now now") — not ones people double on purpose.
        let keep: Set<String> = ["no", "very", "really", "bye", "ha", "so", "yes", "okay", "ok", "please"]
        if let re = try? NSRegularExpression(pattern: #"\b(\w+)([,.]?\s+)\1\b(?![\w'])"#, options: .caseInsensitive) {
            var out = t
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t), let word = Range(m.range(at: 1), in: t), !keep.contains(t[word].lowercased()) else { continue }
                out.replaceSubrange(whole, with: t[word])
            }
            t = out
        }
        // Leftover punctuation: " ," / ", ," / leading comma / double spaces.
        t = t.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,.!?])(?:\s*[,.])+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[,.\s]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let f = t.first, f.isLowercase, raw.first?.isUppercase == true { t = f.uppercased() + t.dropFirst() }
        // A removed "Um." / "Eh," left the next sentence starting in lowercase.
        if let re = try? NSRegularExpression(pattern: #"([.!?]\s+)(\p{Ll})"#) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                if let r = Range(m.range(at: 2), in: t) { t.replaceSubrange(r, with: t[r].uppercased()) }
            }
        }
        return t.isEmpty ? raw : t
    }

    /// Splits off "…and press enter" / "send it". Text may come back empty ("press enter" alone).
    static func finishText(_ raw: String) -> Text? {
        let bare = raw.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if ["press enter", "hit enter", "press return", "hit return", "send it", "send", "and send it", "and press enter"].contains(bare) {
            return Text(text: "", pressReturn: true)
        }
        var text = raw.trimmingCharacters(in: .whitespaces)
        var pressReturn = false
        if let m = text.lowercased().firstMatch(of: sendSuffix) {
            let cut = text.index(text.startIndex, offsetBy: text.lowercased().distance(from: text.lowercased().startIndex, to: m.range.lowerBound))
            text = String(text[..<cut])
            pressReturn = true
        }
        // Strip quotes the transcriber sometimes adds.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces))
        // "Type." alone → nothing to type yet (punctuation the transcriber added).
        if text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) { text = "" }
        guard !text.isEmpty || pressReturn else { return nil }
        return Text(text: text, pressReturn: pressReturn)
    }

    /// Types Unicode text into the focused field (any language, emoji; no clipboard involved).
    static func type(_ text: String, pressReturn: Bool) async {
        // Keep the leading space that joins this to the previous sentence; tidy the rest.
        let lead = text.prefix { $0 == " " }
        let heard = String(text.dropFirst(lead.count))
        let text = lead + clean(heard)
        log("typed", raw: heard, out: String(text))
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count, !Task.isCancelled {
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
