import AppKit

/// Dictation output: tidies spoken text and types it where your cursor is.
@MainActor
enum Typer {
    /// ~/Library/Logs/Butterfly/typing.log: what was heard and what was typed (to debug the cleaner).
    private static func log(raw: String, out: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("typing.log")
        let line = Data("\(Date().formatted(.iso8601)) typed in:  “\(raw)”\n\(String(repeating: " ", count: 26))out: “\(out)”\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }

    /// Spoken text as written text: no "um"/"uh", no stutters ("I I think" → "I think"), tidy punctuation.
    static func clean(_ raw: String) -> String {
        var t = raw
        let filler = #"(um+|uh+|uhm+|er+m*|hm+|mm+|ah+|eh+|ehm+)"#
        t = t.replacingOccurrences(of: #"(?i)\b(okay|ok|well|so|yes|no|right|now|alright|actually|anyway),\s*"# + filler + #",\s*"#, with: "$1, ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i),\s*"# + filler + #",(?=\s)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)(^|[\s,.])"# + filler + #"([,.]?)(?=\s|$|[,.!?])"#, with: "$1", options: .regularExpression)
        let keep: Set<String> = ["no", "very", "really", "bye", "ha", "so", "yes", "okay", "ok", "please"]
        if let re = try? NSRegularExpression(pattern: #"\b(\w+)([,.]?\s+)\1\b(?![\w'])"#, options: .caseInsensitive) {
            var out = t
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t), let word = Range(m.range(at: 1), in: t), !keep.contains(t[word].lowercased()) else { continue }
                out.replaceSubrange(whole, with: t[word])
            }
            t = out
        }
        t = t.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,.!?])(?:\s*[,.])+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[,.\s]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let f = t.first, f.isLowercase, raw.first?.isUppercase == true { t = f.uppercased() + t.dropFirst() }
        if let re = try? NSRegularExpression(pattern: #"([.!?]\s+)(\p{Ll})"#) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                if let r = Range(m.range(at: 2), in: t) { t.replaceSubrange(r, with: t[r].uppercased()) }
            }
        }
        return t.isEmpty ? raw : t
    }

    /// Types Unicode text into the focused field (any language, emoji; no clipboard involved).
    static func type(_ text: String) async {
        let lead = text.prefix { $0 == " " }   // keeps the space joining this to the previous sentence
        let heard = String(text.dropFirst(lead.count))
        let text = lead + clean(heard)
        log(raw: heard, out: String(text))
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
    }
}
