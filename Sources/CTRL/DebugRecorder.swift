import AppKit

/// Developer mode only: every voice command becomes a run folder — what was said, the context the model saw, every
/// decision (DecisionTrace nodes), what ran, click checks with screenshots, and a verdict (👍/👎, a spoken correction,
/// a failed click check, or silence for 2 min = accepted). Declined/failed runs become lessons the router and planner
/// see next time. Export zips it all with an INDEX.md for a coding agent.
/// ~/Library/Application Support/CTRL/debug/{runs/<date>_<id>/run.json|run.md|click*.jpg, lessons.jsonl}
@MainActor
final class DebugRecorder {
    static let shared = DebugRecorder()
    static let root = ProcessInfo.processInfo.environment["CTRL_DEBUG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CTRL/debug")
    static let runsDir = root.appendingPathComponent("runs")
    static let lessonsURL = root.appendingPathComponent("lessons.jsonl")
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "developerMode") }
    static let window: TimeInterval = 120   // a correction / repeat this soon after declines the run; silence accepts it
    static let keep = 300

    struct AppInfo: Codable { var name: String?; var bundle: String?; var version: String? }
    struct Node: Codable { var kind: String; var title: String; var detail: String?; var ms: Int?; var p: Double?; var at: Int; var children: [Node] }
    struct Click: Codable { var what: String; var x: Int; var y: Int; var done: Double?; var retryX: Int?; var retryY: Int?; var retryDone: Double?; var shots: [String] = [] }
    struct Record: Codable {
        var id: String
        var folder: String
        var start: Date
        var end: Date?
        var said: String
        var app = AppInfo()
        var context: String?
        var clickOptions: [String] = []
        var menuOptions: [String] = []
        var nodes: [Node] = []
        var outcome: String?
        var actions: [String] = []        // "+812 ms · perform: …", planner steps and their results
        var clicks: [Click] = []
        var errors: [String] = []
        var latencyMs: Int?
        var verdict = "unknown"           // accepted / declined / failed / unknown
        var verdictBy: String?
        var correction: String?
        var skillPattern: String?
        var lessoned = false
        var session: String?              // sessions/<this>/video.mp4: the whole listening session this run was part of
        var videoOffset: Double?          // where this run starts in that video, seconds
    }
    struct Lesson: Codable { var said: String; var app: String?; var did: String; var why: String; var at: Date }

    private var records: [UUID: Record] = [:]
    private var order: [UUID] = []          // newest last
    private var ended: Set<UUID> = []
    private var pending: [UUID: Int] = [:]  // async work (click checks) still running for a run

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private func ms(_ r: Record) -> Int { Int(Date().timeIntervalSince(r.start) * 1000) }

    // MARK: Recording

    func begin(_ id: UUID, said: String) {
        guard Self.enabled else { return }
        followUp(said)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        records[id] = Record(id: id.uuidString, folder: "\(f.string(from: Date()))_\(id.uuidString.prefix(8).lowercased())", start: Date(), said: said)
        order.append(id)
        RunVideo.shared.attach(id, folder: records[id]!.folder, said: said)
        // Only the last few minutes stay in memory (corrections attach to them); the rest lives on disk.
        while order.count > 30, let old = order.first { order.removeFirst(); records[old] = nil; ended.remove(old) }
    }

    func context(_ app: NSRunningApplication?, summary: String, run id: UUID? = nil) {
        update(id) { r in
            r.app = AppInfo(name: app?.localizedName, bundle: app?.bundleIdentifier,
                            version: app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String })
            r.context = summary
        }
        if let name = app?.localizedName, ScreenMemory.isExcluded(name) { RunVideo.shared.discard() }   // private app: no video
    }

    /// The ranked click / menu options the router offered the model (top 15 each).
    func options(click: [String], menu: [String], run id: UUID? = nil) {
        update(id) { r in
            if !click.isEmpty { r.clickOptions = Array(click.prefix(15)) }
            if !menu.isEmpty { r.menuOptions = Array(menu.prefix(15)) }
        }
    }

    func node(_ n: DecisionTrace.Node, run id: UUID) {
        update(id) { r in
            let at = ms(r)
            func conv(_ n: DecisionTrace.Node) -> Node { Node(kind: n.kind.rawValue, title: n.title, detail: n.detail, ms: n.ms, p: n.p, at: at, children: n.children.map(conv)) }
            r.nodes.append(conv(n))
            RunVideo.shared.caption(n.title + (n.detail.map { " — \($0)" } ?? ""))
            if n.kind == .outcome { r.outcome = n.title }
            if n.kind == .error { r.errors.append(n.title + (n.detail.map { " — \($0)" } ?? "")) }
        }
    }

    func action(_ text: String, run id: UUID? = nil) {
        update(id) { r in r.actions.append("+\(ms(r)) ms · \(text)") }
        RunVideo.shared.caption(text)
    }

    func skill(_ pattern: String?, run id: UUID? = nil) {
        guard let pattern else { return }
        update(id) { $0.skillPattern = pattern }
    }

    // MARK: Click checks (async: the run stays open until they finish)

    func hold(_ id: UUID?) { if let id, records[id] != nil { pending[id, default: 0] += 1 } }
    func release(_ id: UUID?) {
        guard let id, let n = pending[id] else { return }
        pending[id] = n > 1 ? n - 1 : nil
        if pending[id] == nil, ended.contains(id) { finalize(id) }
    }

    /// Starts a click entry; returns its index for `clickUpdate`.
    func click(_ what: String, at p: CGPoint, run id: UUID?) -> Int? {
        var i: Int?
        update(id) { r in r.clicks.append(Click(what: what, x: Int(p.x), y: Int(p.y))); i = r.clicks.count - 1 }
        return i
    }

    func clickUpdate(_ i: Int?, run id: UUID?, _ change: (inout Click) -> Void) {
        guard let i else { return }
        update(id) { r in if r.clicks.indices.contains(i) { change(&r.clicks[i]) } }
    }

    /// Before/after screenshot as jpg in the run folder; skipped for apps excluded from screen memory.
    func shot(_ s: Clicker.Shot?, _ name: String, click i: Int?, run id: UUID?) {
        guard let s, let i, let id, let r = records[id] else { return }
        if let app = r.app.name, ScreenMemory.isExcluded(app) { return }
        let dir = Self.runsDir.appendingPathComponent(r.folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "click\(i + 1)-\(name).jpg"
        guard (try? s.jpeg.write(to: dir.appendingPathComponent(file))) != nil else { return }
        clickUpdate(i, run: id) { $0.shots.append(file) }
    }

    // MARK: End and verdict

    func finish(_ run: DecisionTrace.Run) {
        guard records[run.id] != nil else { return }
        update(run.id) { r in r.latencyMs = run.ms }
        ended.insert(run.id)
        if pending[run.id] == nil { finalize(run.id) }
    }

    private func finalize(_ id: UUID) {
        guard var r = records[id], r.end == nil else { return }
        r.end = Date()
        r.latencyMs = r.latencyMs.map { max($0, ms(r)) } ?? ms(r)
        records[id] = r
        RunVideo.shared.finished(id, outcome: r.outcome)
        if r.verdict == "unknown", !r.errors.isEmpty { return verdict("failed", by: "error: \(r.errors[0])", run: id) }
        write(r)
        prune()
        // No complaint within 2 minutes: it did what you wanted.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.window))
            guard let self, self.records[id]?.verdict == "unknown" else { return }
            if let o = self.records[id]?.outcome, o.hasPrefix("aside") || o.hasPrefix("cancelled") { return }
            self.verdict("accepted", by: "implicit: no correction within 2 min", run: id)
        }
    }

    /// Explicit (👍/👎), a correction, or a failed click check. Declined/failed → a lesson; a learned skill that got it wrong is dropped.
    func verdict(_ v: String, by: String, correction: String? = nil, run id: UUID?) {
        guard let id, var r = records[id] else { return }
        r.verdict = v; r.verdictBy = by
        if let correction { r.correction = correction }
        if v == "declined" || v == "failed", !r.lessoned {
            r.lessoned = true
            let did = ([r.outcome].compactMap { $0 } + r.actions.suffix(3).map { $0.components(separatedBy: " · ").dropFirst().joined(separator: " · ") }).joined(separator: " → ")
            appendLesson(Lesson(said: r.said, app: r.app.name, did: did.isEmpty ? "nothing" : String(did.prefix(300)), why: correction ?? by, at: Date()))
            if v == "declined", let p = r.skillPattern, let s = SkillStore.shared.skills.first(where: { $0.pattern == p }) {
                SkillStore.shared.forget(s)
                r.actions.append("skill “\(p)” dropped (declined)")
            }
        }
        records[id] = r
        write(r)
    }

    /// A new sentence soon after a run: "no, not that", "that didn't work", "I meant…" or the same request again → the last run was declined.
    func followUp(_ said: String, force: Bool = false) {
        guard let id = order.last(where: { $0 != DecisionTrace.shared.currentID }), let r = records[id], Date().timeIntervalSince(r.end ?? r.start) < Self.window,
              r.verdict == "unknown" || (r.verdict == "accepted" && r.verdictBy?.hasPrefix("implicit") == true) else { return }
        let s = said.lowercased()
        let corrects = s.range(of: #"^\W*(no\b|nope\b|not that|wrong\b|i meant\b|i said\b|that'?s not)|\b(didn'?t|did not|doesn'?t|does not) work\b|\bthat'?s wrong\b|\bnot what i (said|meant|wanted)\b"#, options: .regularExpression) != nil
        let norm: (String) -> String = { SkillStore.normalize($0) }
        let repeated = norm(said) == norm(r.said) && !(r.outcome ?? "").contains(#/(?i)volume|brightness|scroll|next|previous|press|media/#)
        guard force || corrects || repeated else { return }
        verdict("declined", by: repeated && !corrects && !force ? "repeated the same request" : "voice correction", correction: said, run: id)
    }

    /// The session video this run is in was saved (after the session went idle).
    func attachSession(_ id: UUID, session: String, offset: Double) {
        if records[id] != nil { return update(id) { r in r.session = session; r.videoOffset = offset } }
        // Already out of memory: patch the file.
        guard let r = Self.allRuns().last(where: { $0.id == id.uuidString }) else { return }
        var x = r; x.session = session; x.videoOffset = offset
        write(x)
    }

    // MARK: Lessons (self-improvement)

    private var lessonCache: [Lesson]?
    var lessons: [Lesson] {
        if let lessonCache { return lessonCache }
        let lines = (try? String(contentsOf: Self.lessonsURL, encoding: .utf8))?.split(separator: "\n") ?? []
        let l = lines.compactMap { try? Self.decoder.decode(Lesson.self, from: Data($0.utf8)) }
        lessonCache = l
        return l
    }

    private func appendLesson(_ l: Lesson) {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys
        guard let d = try? e.encode(l) else { return }
        if let h = try? FileHandle(forWritingTo: Self.lessonsURL) { h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close() }
        else { try? (d + Data("\n".utf8)).write(to: Self.lessonsURL) }
        lessonCache?.append(l)
    }

    /// Up to 5 past mistakes like this request (same app and/or shared words), for the router / planner prompt.
    func pastMistakes(_ request: String, app: String?) -> String? {
        guard Self.enabled else { return nil }
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }) }
        let w = words(request)
        let ranked = lessons.reversed().map { l -> (Lesson, Int) in
            (l, words(l.said).intersection(w).count * 2 + (app != nil && l.app == app ? 1 : 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(5)
        guard !ranked.isEmpty else { return nil }
        return ranked.map { l, _ in "“\(l.said)”\(l.app.map { " in \($0)" } ?? "") → did: \(l.did) → WRONG (\(l.why))" }.joined(separator: "\n")
    }

    // MARK: Files

    private func update(_ id: UUID?, _ change: (inout Record) -> Void) {
        guard let id = id ?? DecisionTrace.shared.currentID, var r = records[id] else { return }
        change(&r)
        records[id] = r
        if r.end != nil { write(r) }   // late events after the run ended still land on it
    }

    private func write(_ r: Record) {
        let dir = Self.runsDir.appendingPathComponent(r.folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Self.encoder.encode(r) { try? d.write(to: dir.appendingPathComponent("run.json"), options: .atomic) }
        try? Self.markdown(r).write(to: dir.appendingPathComponent("run.md"), atomically: true, encoding: .utf8)
    }

    private func prune() {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(atPath: Self.runsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in all.dropLast(Self.keep) { try? fm.removeItem(at: Self.runsDir.appendingPathComponent(old)) }
        let sessions = ((try? fm.contentsOfDirectory(atPath: RunVideo.sessionsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in sessions.dropLast(50) { try? fm.removeItem(at: RunVideo.sessionsDir.appendingPathComponent(old)) }
    }

    static func markdown(_ r: Record) -> String {
        var o = "# “\(r.said)”\n\n"
        o += "Written for an AI coding agent fixing Butterfly (a macOS voice assistant). One voice command, start to end.\n\n"
        o += "- **Verdict: \(r.verdict)**" + (r.verdictBy.map { " (\($0))" } ?? "") + "\n"
        if let c = r.correction { o += "- **User's correction:** “\(c)”\n" }
        o += "- When: \(r.start.formatted(date: .abbreviated, time: .standard)) · total \(r.latencyMs ?? 0) ms\n"
        o += "- Front app: \(r.app.name ?? "?") (\(r.app.bundle ?? "?") \(r.app.version ?? ""))\n"
        if let c = r.context { o += "- Context: \(c)\n" }
        if let o2 = r.outcome { o += "- Router outcome: `\(o2)`\n" }
        if let s = r.skillPattern { o += "- Learned skill used: “\(s)”\n" }
        o += "\n## What was decided and why (decision trace, +ms since start)\n\n```\n"
        func walk(_ n: Node, _ d: Int) {
            var line = String(repeating: "  ", count: d) + (d == 0 ? "■ +\(n.at) " : "└ ") + "[\(n.kind)] \(n.title)"
            if let p = n.p { line += String(format: " (%.2f)", p) }
            if let x = n.detail { line += " — \(x)" }
            if let ms = n.ms { line += " · \(ms) ms" }
            o += line + "\n"
            n.children.forEach { walk($0, d + 1) }
        }
        r.nodes.forEach { walk($0, 0) }
        o += "```\n\n## What happened\n\n" + (r.actions.isEmpty ? "- (nothing executed)\n" : r.actions.map { "- \($0)\n" }.joined())
        if !r.clicks.isEmpty {
            o += "\n## Click checks (before/after screenshots judged by the model; done ≥ 0.5 = worked)\n\n"
            for c in r.clicks {
                o += "- “\(c.what)” at (\(c.x), \(c.y)): done \(c.done.map { String(format: "%.2f", $0) } ?? "not checked")"
                if let x = c.retryX, let y = c.retryY { o += " → retry at (\(x), \(y)): done \(c.retryDone.map { String(format: "%.2f", $0) } ?? "?")" }
                o += c.shots.map { " · [\($0)](\($0))" }.joined() + "\n"
            }
        }
        if let s = r.session {
            let at = RunVideo.Session.clock(r.videoOffset ?? 0), base = "../../sessions/\(s)/"
            o += "\n## Video\n\nThis run starts at **\(at)** in its session video (the whole listening session; captions show the utterance and each decision, yellow rings mark clicks).\n\n"
            o += "- [video.mp4 @ \(at)](\(base)video.mp4) · [contact sheet](\(base)contact-sheet.jpg) · [session.md](\(base)session.md)\n"
        }
        if !r.clickOptions.isEmpty { o += "\n## Click options shown to the model (ranked)\n\n" + r.clickOptions.map { "- \($0)\n" }.joined() }
        if !r.menuOptions.isEmpty { o += "\n## Menu options shown to the model (ranked)\n\n" + r.menuOptions.map { "- \($0)\n" }.joined() }
        if !r.errors.isEmpty { o += "\n## Errors\n\n" + r.errors.map { "- \($0)\n" }.joined() }
        return o
    }

    static func allRuns() -> [Record] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: runsDir.path)) ?? []).sorted().compactMap { f in
            (try? Data(contentsOf: runsDir.appendingPathComponent(f).appendingPathComponent("run.json"))).flatMap { try? decoder.decode(Record.self, from: $0) }
        }
    }

    // MARK: Export

    /// Zips the debug folder (INDEX.md on top: declined/failed first) to the Desktop. Returns the zip.
    @discardableResult
    static func export(to dir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]) -> URL? {
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let runs = allRuns().reversed()
        let rank = ["failed": 0, "declined": 1, "unknown": 2, "accepted": 3]
        let sorted = runs.sorted { (rank[$0.verdict] ?? 2, $1.start) < (rank[$1.verdict] ?? 2, $0.start) }
        let cell = { (s: String) in s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").prefix(70) }
        var md = "# Butterfly debug logs\n\nFor an AI coding agent: each row is one voice command. Start with failed/declined runs; open its run.md "
        md += "(what was said, what was decided and why, what happened, the verdict and the user's correction). lessons.jsonl lists every mistake.\n\n"
        md += "\(runs.count) runs · \(runs.filter { $0.verdict == "failed" }.count) failed · \(runs.filter { $0.verdict == "declined" }.count) declined · \(shared.lessons.count) lessons\n\n"
        md += "| When | Said | App | Outcome | Verdict | Run | Video |\n|---|---|---|---|---|---|---|\n"
        for r in sorted {
            md += "| \(r.start.formatted(date: .numeric, time: .shortened)) | \(cell(r.said)) | \(cell(r.app.name ?? "?")) | \(cell(r.outcome ?? "—")) | **\(r.verdict)**\(r.correction.map { " “\(cell($0))”" } ?? "") | [run.md](runs/\(r.folder)/run.md) | \(r.session.map { "[mp4 @ \(RunVideo.Session.clock(r.videoOffset ?? 0))](sessions/\($0)/video.mp4)" } ?? "") |\n"
        }
        let sessions = ((try? FileManager.default.contentsOfDirectory(atPath: RunVideo.sessionsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().reversed()
        if !sessions.isEmpty {
            md += "\n## Session videos (one per listening session, newest first)\n\n" + sessions.map { "- \($0): [video.mp4](sessions/\($0)/video.mp4) · [contact sheet](sessions/\($0)/contact-sheet.jpg) · [session.md](sessions/\($0)/session.md)\n" }.joined()
        }
        try? md.write(to: root.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm"
        let zip = dir.appendingPathComponent("Butterfly-debug-\(f.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", root.path, zip.path]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? zip : nil
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}
