import Foundation

/// Pulls website candidates out of a spoken command.
/// Jev can't generate strings, so code proposes candidates and Jev picks one.
enum URLExtractor {
    private static let fillers: Set<String> = ["open", "go", "to", "the", "launch", "visit", "show", "me", "website", "site", "page", "please", "on", "and"]
    private static let domain = try! NSRegularExpression(
        pattern: #"\b((?:[a-z0-9-]+\.)+[a-z]{2,})(/[^\s]*)?"#
    )

    /// "Open Facebook dot com" → "open facebook.com"
    static func normalize(_ text: String) -> String {
        var t = " " + text.lowercased() + " "
        for (spoken, symbol) in [(" dot ", "."), (" slash ", "/"), (" dash ", "-"), (" hyphen ", "-")] {
            while t.contains(spoken) { t = t.replacingOccurrences(of: spoken, with: symbol) }
        }
        t = t.replacingOccurrences(of: #"\s*\.\s*(?=[a-z])"#, with: ".", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[,!?]"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Candidate hosts, including joins with the previous spoken word
    /// ("open mail.sh" → ["mail.sh", "openmail.sh"]) since speech often splits names.
    static func candidates(in text: String) -> [String] {
        let t = normalize(text)
        let ns = t as NSString
        var out: [String] = []
        for m in domain.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let host = ns.substring(with: m.range(at: 1))
            let path = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            out.append(host + path)

            let before = ns.substring(to: m.range.location).split(separator: " ")
            if let prev = before.last.map(String.init), !prev.isEmpty, !fillers.contains(prev) {
                out.append(prev + host + path)   // "console openmail.sh" → also try "consoleopenmail.sh"
                if before.count >= 2, !fillers.contains(String(before[before.count - 2])) {
                    out.append(String(before[before.count - 2]) + prev + host + path)
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func url(for candidate: String) -> URL? {
        URL(string: candidate.hasPrefix("http") ? candidate : "https://" + candidate)
    }

    /// Normalized text with every web address cut out.
    static func removingAddresses(from normalized: String) -> String {
        let ns = normalized as NSString
        return domain.stringByReplacingMatches(in: normalized, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }
}
