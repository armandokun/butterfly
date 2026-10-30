import Foundation
import SwiftUI

/// What Butterfly learned by doing: the first time a request needs the planner, the finished plan is saved as a
/// skill with slots ("search {query} on linkedin"). Next time the same kind of request fires that skill directly —
/// no planning, no network. Saved to ~/Library/Application Support/CTRL/skills.json.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    struct Skill: Codable, Identifiable {
        var id = UUID()
        var name: String                 // "Search on LinkedIn"
        var pattern: String              // "search {query} on linkedin" — words to match, {slots} to capture
        var steps: [Planner.Step]        // with {slot} placeholders in string fields
        var examples: [String]           // phrases that used it
        var uses = 0
        var lastUsed = Date()
    }

    @Published private(set) var skills: [Skill] = []
    static let fileURL = Vocabulary.fileURL.deletingLastPathComponent().appendingPathComponent("skills.json")

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode([Skill].self, from: d) { skills = s }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(skills) { try? d.write(to: Self.fileURL, options: .atomic) }
    }

    func learn(name: String, pattern: String, steps: [Planner.Step], example: String) {
        if let i = skills.firstIndex(where: { $0.pattern.lowercased() == pattern.lowercased() }) {
            skills[i].examples.append(example); skills[i].steps = steps; skills[i].lastUsed = Date()
        } else {
            skills.append(Skill(name: name, pattern: pattern, steps: steps, examples: [example]))
        }
        save()
    }

    func used(_ skill: Skill, phrase: String) {
        guard let i = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[i].uses += 1; skills[i].lastUsed = Date()
        if !skills[i].examples.contains(phrase) { skills[i].examples.append(phrase); skills[i].examples = Array(skills[i].examples.suffix(8)) }
        save()
    }

    func forget(_ skill: Skill) { skills.removeAll { $0.id == skill.id }; save() }
    func forgetAll() { skills = []; save() }

    // MARK: Matching

    /// Instant, local: the pattern as a regex. "search {query} on linkedin" matches "okay, search chaseit on LinkedIn please".
    func match(_ spoken: String) -> (Skill, [String: String])? {
        let s = Self.normalize(spoken)
        for skill in skills.sorted(by: { $0.uses > $1.uses }) {
            guard let (re, names) = Self.regex(for: skill.pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            var values: [String: String] = [:]
            for (i, n) in names.enumerated() {
                guard let r = Range(m.range(at: i + 1), in: s) else { continue }
                let v = s[r].trimmingCharacters(in: .whitespaces)
                // Original casing when the words appear verbatim in what was said ("Tesla", "Chase IT").
                values[n] = spoken.range(of: v, options: [.caseInsensitive, .diacriticInsensitive]).map { String(spoken[$0]) } ?? v
            }
            if values.values.contains(where: \.isEmpty) { continue }
            return (skill, values)
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"^(ok(ay)?,?\s+|please\s+|can you\s+|could you\s+|hey,?\s+|butterfly,?\s+)+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(please|for me|once you're there|once you are there|when you're there|and then|then|now)\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[,.!?]"#, with: " ", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// "search {query} on linkedin" → ^search (.+?) on linkedin$, slot names in order.
    static func regex(for pattern: String) -> (NSRegularExpression, [String])? {
        var names: [String] = []
        var out = "^"
        var rest = Substring(normalize(pattern.replacingOccurrences(of: #"\{(\w+)\}"#, with: " {$1} ", options: .regularExpression)))
        while let open = rest.firstIndex(of: "{") {
            let literal = rest[..<open].trimmingCharacters(in: .whitespaces)
            if !literal.isEmpty { out += (out == "^" ? "" : "\\s+") + NSRegularExpression.escapedPattern(for: literal) }
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            names.append(String(rest[rest.index(after: open)..<close]))
            out += (out == "^" ? "" : "\\s+") + "(.+?)"
            rest = rest[rest.index(after: close)...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out += (out == "^" ? "" : "\\s+") + NSRegularExpression.escapedPattern(for: tail) }
        out += "$"
        return (try? NSRegularExpression(pattern: out, options: .caseInsensitive)).map { ($0, names) }
    }

    /// The skill's steps with slots filled in.
    static func fill(_ steps: [Planner.Step], with values: [String: String]) -> [Planner.Step] {
        func sub(_ s: String?) -> String? {
            guard var t = s else { return nil }
            for (k, v) in values {
                t = t.replacingOccurrences(of: "{\(k)}", with: v)
                t = t.replacingOccurrences(of: "{\(k)|url}", with: v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)
            }
            return t
        }
        return steps.map { st in
            var s = st
            s.text = sub(s.text); s.url = sub(s.url); s.source = sub(s.source); s.combo = sub(s.combo)
            s.title = sub(s.title); s.start = sub(s.start); s.due = sub(s.due); s.location = sub(s.location); s.notes = sub(s.notes)
            return s
        }
    }

    /// For the classifier when the regex doesn't hit: "s3": "Search on LinkedIn (e.g. 'search chaseit on linkedin')".
    var options: [String: String] {
        var o: [String: String] = [:]
        for (i, s) in skills.prefix(60).enumerated() { o["s\(i)"] = "\(s.name): pattern “\(s.pattern)”, e.g. “\(s.examples.first ?? s.pattern)”" }
        return o
    }
    func skill(forOption key: String) -> Skill? { Int(key.dropFirst()).flatMap { skills.indices.contains($0) ? skills[$0] : nil } }

    /// Slot names in a pattern: "search {query} on {site}" → ["query", "site"].
    static func slots(in pattern: String) -> [String] {
        pattern.matches(of: #/\{(\w+)\}/#).map { String($0.1) }
    }

    /// The regex missed (different wording, another language): one classifier call picks the skill that means the same,
    /// or none. Returns the skill and how sure it was.
    func semanticMatch(_ spoken: String, client: TypeSafeClient) async throws -> (skill: Skill, confidence: Double)? {
        guard !skills.isEmpty else { return nil }
        var opts = options
        opts["none"] = "none of these: the request is about something else"
        let r = try await client.systemOne(
            state: ["spoken_command": spoken],
            questions: ["skill": .choice("Which learned skill does the user's request ask for? Same meaning counts even with different words or another language; the {slots} are the variable parts.", options: opts)])
        guard let a = r.choice("skill"), a.choice != "none", let s = skill(forOption: a.choice) else { return nil }
        return (s, a.confidence)
    }
}
