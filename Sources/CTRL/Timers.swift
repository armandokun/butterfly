import AppKit

/// Voice timers: "set a timer for 5 minutes", "how long is left", "cancel the timer".
/// Shown as a live countdown beside the notch; plays a sound and expands when done.
@MainActor
final class Timers: ObservableObject {
    struct Timer: Identifiable, Equatable {
        let id = UUID()
        let label: String?
        let total: TimeInterval
        let ends: Date
        var remaining: TimeInterval { max(0, ends.timeIntervalSinceNow) }
        var progress: Double { total > 0 ? 1 - remaining / total : 1 }
    }

    enum Action: String { case start = "timer_start", cancel = "timer_cancel", status = "timer_status" }

    static let shared = Timers()
    @Published private(set) var active: [Timer] = []
    var onFinish: ((Timer) -> Void)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var next: Timer? { active.min { $0.ends < $1.ends } }

    static let actionQuestion = TypeSafeClient.Question.choice("What does the user want to do with a timer?", options: [
        "timer_start": "start / set a new timer or countdown for some amount of time (also 'remind me in 10 minutes')",
        "timer_cancel": "cancel, stop, or delete the timer",
        "timer_status": "ask how much time is left on the timer, or show it",
    ])

    static let durationQuestion = TypeSafeClient.Question.choice("How long should the timer run? Speech-to-text may write numbers as words.", options: [
        "none": "no duration given",
        "30": "30 seconds, half a minute", "60": "1 minute, a minute", "120": "2 minutes", "180": "3 minutes",
        "300": "5 minutes", "600": "10 minutes", "900": "15 minutes, a quarter hour", "1200": "20 minutes",
        "1500": "25 minutes, a pomodoro", "1800": "30 minutes, half an hour", "2700": "45 minutes",
        "3600": "1 hour, an hour", "5400": "1.5 hours, an hour and a half", "7200": "2 hours",
    ])

    func start(_ seconds: TimeInterval, label: String? = nil) -> Timer {
        schedule(Timer(label: label, total: seconds, ends: Date().addingTimeInterval(seconds)))
    }

    @discardableResult private func schedule(_ t: Timer) -> Timer {
        active.append(t)
        tasks[t.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(t.remaining))
            guard !Task.isCancelled, let self else { return }
            self.active.removeAll { $0.id == t.id }
            self.tasks[t.id] = nil
            self.save()
            NSSound(named: "Glass")?.play()
            self.onFinish?(t)
        }
        save()
        return t
    }

    @discardableResult func cancelAll() -> Int {
        let n = active.count
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        active = []
        save()
        return n
    }

    /// Undo for "set a timer".
    func cancelNewest() {
        guard let t = active.max(by: { $0.ends.timeIntervalSince1970 - $0.total < $1.ends.timeIntervalSince1970 - $1.total }) else { return }
        tasks[t.id]?.cancel()
        tasks[t.id] = nil
        active.removeAll { $0.id == t.id }
        save()
    }

    // MARK: Survive restarts

    private static let key = "timers"
    private func save() {
        UserDefaults.standard.set(active.map { ["label": $0.label ?? "", "total": $0.total, "ends": $0.ends.timeIntervalSince1970] }, forKey: Self.key)
    }

    /// At launch: timers still running come back; ones that ended while CTRL was closed (≤10 min ago) ring now.
    func restore() {
        let saved = UserDefaults.standard.array(forKey: Self.key) as? [[String: Any]] ?? []
        for d in saved {
            guard let total = d["total"] as? Double, let ends = d["ends"] as? Double else { continue }
            let label = (d["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let t = Timer(label: label, total: total, ends: Date(timeIntervalSince1970: ends))
            if t.remaining > 0 { schedule(t) }
            else if -t.ends.timeIntervalSinceNow < 600 {
                Task { try? await Task.sleep(for: .seconds(1.5)); NSSound(named: "Glass")?.play(); self.onFinish?(t) }
            }
        }
        save()
    }

    // MARK: Parsing "five minutes", "1 hour and 30 minutes", "90 seconds", "an hour and a half"

    private static let words: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90, "half": 0.5, "couple": 2, "few": 3,
    ]

    static func seconds(in text: String) -> TimeInterval? {
        var s = text.lowercased().replacingOccurrences(of: "-", with: " ")
        // "twenty five" → 25
        for tens in ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50] {
            for (w, n) in words where (1...9).contains(n) && n == n.rounded() && !["a", "an", "few"].contains(w) {
                s = s.replacingOccurrences(of: "\(tens.key) \(w)", with: String(Int(Double(tens.value) + n)))
            }
        }
        let units: [(pattern: String, mult: Double)] = [("h(ou)?rs?", 3600), ("min(ute)?s?", 60), ("sec(ond)?s?", 1)]
        var total = 0.0
        for u in units {
            let re = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?|[a-z]+)\s+(?:and\s+a\s+half\s+)?"# + u.pattern + #"\b(\s+and\s+a\s+half)?"#)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s) else { continue }
                let token = String(s[r])
                guard let n = Double(token) ?? words[token] else { continue }
                let half = s[Range(m.range, in: s)!].contains("and a half") ? 0.5 : 0
                total += (n + half) * u.mult
            }
        }
        return total > 0 ? total : nil
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func spoken(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        var parts: [String] = []
        if s >= 3600 { parts.append("\(s / 3600) hr") }
        if s % 3600 >= 60 { parts.append("\(s % 3600 / 60) min") }
        if s % 60 > 0 && s < 600 { parts.append("\(s % 60) sec") }
        return parts.joined(separator: " ")
    }
}
