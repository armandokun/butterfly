import AppKit

/// Your custom words: one per line in ~/Library/Application Support/CTRL/vocabulary.txt
/// Used as speech-recognition hints AND to repair split words ("open mail dot sh" → "openmail.sh").
@MainActor
enum Vocabulary {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CTRL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    private static let starter = """
    # CTRL vocabulary: one word, name, or web address per line.
    # Helps speech recognition and fixes words it splits apart.
    openmail.sh
    """

    static var words: [String] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? starter.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Hints for the speech model: your words + app names, plus spoken forms of addresses.
    static var speechHints: [String] {
        var hints = words + AppCatalog.shared.apps.map(\.name)
        for w in words where w.contains(".") {
            hints.append(w.replacingOccurrences(of: ".", with: " dot "))
        }
        return Array(Set(hints)).prefix(100).map { $0 }
    }

    /// Vocabulary entries whose letters appear in the transcript, ignoring spaces/dots.
    /// "open mail dot sh" → letters "openmailsh" contains "openmailsh" → "openmail.sh".
    static func matches(in transcript: String) -> [String] {
        let spoken = compact(URLExtractor.normalize(transcript))
        return words.filter { spoken.contains(compact($0)) }
    }

    /// Rewrites the file, keeping its comment lines.
    static func save(_ list: [String]) {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? starter
        let comments = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("#") }.map(String.init)
        let clean = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? (comments + clean).joined(separator: "\n").appending("\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func open() {
        _ = words   // ensure file exists
        NSWorkspace.shared.open(fileURL)
    }

    private static func compact(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
