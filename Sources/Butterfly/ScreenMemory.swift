import AppKit
import CryptoKit
import ScreenCaptureKit

/// Remembers what was on screen. Every few seconds the front window is captured; when it changed, its text is read
/// (on-device OCR) and kept with the time, app and window title. Later, "what was the camera price I saw on Stride?"
/// is answered from this. Text only, nothing leaves the Mac until you ask a question about it.
/// Files: ~/Library/Application Support/Butterfly/screen/YYYY-MM-DD.jsonl, kept 30 days.
@MainActor
final class ScreenMemory {
    static let shared = ScreenMemory()

    struct Entry: Codable {
        var t: Date
        var until: Date
        var app: String
        var title: String
        var text: String
        var image: String?      // JPEG file name in screen/img — the actual frame, for reading exact values later
    }
    nonisolated static let images = folder.appendingPathComponent("img")
    /// Frames are kept a week (text stays 30 days).
    static let imageDays = 7

    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Butterfly/screen")
    static let key = "screenMemory"
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) == nil ? true : UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); if newValue { start() } else { stop() } }
    }

    private var timer: Timer?
    private var busy = false
    private var lastHash: [UInt8] = []
    private var lastTokens: Set<String> = []
    private var recent: [Entry] = []      // today + the last days, in memory for search
    private var loadedDays: Set<String> = []
    private(set) var count = 0
    var debug = ProcessInfo.processInfo.environment["BUTTERFLY_MEMORY_DEBUG"] != nil
    private func log(_ s: String) { if debug { print("  memory:", s) } }

    /// Apps whose windows are never read. Yours to edit in Settings; these are the defaults (password managers, banks, private chats).
    nonisolated static let excludedKey = "screenMemoryExcludedApps"
    nonisolated static let defaultExcluded = ["1Password", "Bitwarden", "Keychain Access", "Passwords", "Messages", "WhatsApp", "Signal", "Telegram", "Revolut", "Swedbank", "SEB", "Luminor", "Wise", "Banking", "Bank"]
    nonisolated static var excludedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludedKey) ?? defaultExcluded }
        set { UserDefaults.standard.set(newValue, forKey: excludedKey) }
    }
    nonisolated private static var skipApps: Set<String> { Set(excludedApps).union(["Butterfly", "loginwindow"]) }
    private static let skipTitles = ["private browsing", "incognito", "private window"]

    /// Bytes used by the text files and frames on disk.
    nonisolated static var diskUsage: Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in e { n += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return n
    }

    func start() {
        guard enabled, timer == nil else { return }
        load(days: 14)
        prune()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Capture

    private func tick() async {
        guard enabled, !busy else { log("skip: \(enabled ? "busy" : "disabled")"); return }
        // Not when the screen is locked, nobody's there, or the app is a password manager.
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any], (s["CGSSessionScreenIsLocked"] as? Bool) == true { return }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) > 90,
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 90 { log("skip: idle"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName, !Self.isExcluded(name),
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { log("skip: app"); return }
        let title = ScreenReader.windowTitle(app)
        if Self.skipTitles.contains(where: { title.lowercased().contains($0) }) { log("skip: private"); return }
        busy = true; defer { busy = false }
        var shot: (image: CGImage, frame: CGRect)?
        do { shot = try await ScreenReader.windowCapture(app) } catch { NSLog("ScreenMemory: capture failed: %@", "\(error)"); return }
        guard let shot else { NSLog("ScreenMemory: no window for %@", name); return }
        // What you type stays yours: text fields, composers and password boxes are painted over before OCR and storage.
        let fields = await ScreenReader.inputFrames(pid: app.processIdentifier)
        let image = ScreenReader.mask(shot.image, window: shot.frame, fields: fields)
        if !fields.isEmpty { log("masked \(fields.count) inputs") }
        if debug, let d = Self.jpeg(image, maxSide: 1400, quality: 0.6) { try? d.write(to: URL(fileURLWithPath: "/tmp/butterfly-last-frame.jpg")) }
        // Cheap change detection: a 16×16 grey thumbnail; only OCR when the window really changed.
        let h = Self.thumbHash(image)
        if Self.distance(h, lastHash) < 10 { log("same frame (\(name))"); return }
        lastHash = h
        guard let text = try? await ScreenReader.text(in: image), text.count >= 20 else { return }
        let tokens = Set(ScreenMemory.tokens(text))
        // Same content as the last entry (scrolled a little, cursor moved): extend it instead of storing again.
        if !lastTokens.isEmpty, Self.jaccard(tokens, lastTokens) > 0.85, var last = recent.last, last.app == name {
            last.until = Date()
            if text.count > last.text.count { last.text = text }
            recent[recent.count - 1] = last
            lastTokens = tokens
            rewriteToday()
            return
        }
        lastTokens = tokens
        let now = Date()
        let e = Entry(t: now, until: now, app: name, title: String(title.prefix(120)), text: String(text.prefix(6000)), image: saveImage(image, at: now))
        recent.append(e)
        count += 1
        append(e)
        log("saved \(name) · \(title.prefix(40)) · \(text.count) chars · image \(e.image ?? "none")")
    }

    /// Frames are encrypted with a per-user key from the Keychain before they touch the disk (`.jpg.enc`), ~100–200 KB each.
    private func saveImage(_ image: CGImage, at t: Date) -> String? {
        try? FileManager.default.createDirectory(at: Self.images, withIntermediateDirectories: true)
        guard let data = Self.jpeg(image, maxSide: 1400, quality: 0.55), let sealed = try? ChaChaPoly.seal(data, using: Keychain.screenKey).combined else { return nil }
        let name = String(format: "%.0f.jpg.enc", t.timeIntervalSince1970)
        return (try? sealed.write(to: Self.images.appendingPathComponent(name))) != nil ? name : nil
    }

    /// "Bank" excludes "Bank of X" too; matching is by whole word, case-insensitive.
    nonisolated static func isExcluded(_ appName: String) -> Bool {
        let name = appName.lowercased()
        let words = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return skipApps.contains { let s = $0.lowercased(); return s == name || words.contains(s) || (s.contains(" ") && name.contains(s)) }
    }

    nonisolated static func jpeg(_ image: CGImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: quality]) }
    }

    /// The saved frame for an entry, re-encoded small enough for the model. Older plain .jpg files still read.
    nonisolated static func frame(_ e: Entry, maxSide: CGFloat = 1100) -> Data? {
        guard let n = e.image, var data = try? Data(contentsOf: images.appendingPathComponent(n)) else { return nil }
        if n.hasSuffix(".enc") {
            guard let box = try? ChaChaPoly.SealedBox(combined: data), let open = try? ChaChaPoly.open(box, using: Keychain.screenKey) else { return nil }
            data = open
        }
        guard let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return jpeg(img, maxSide: maxSide, quality: 0.6)
    }

    nonisolated static func thumbHash(_ image: CGImage) -> [UInt8] {
        let n = 16
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let p = ctx.data else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n * n))
    }
    nonisolated static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count, !a.isEmpty else { return .max }
        return zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }
    }
    nonisolated static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let u = a.union(b).count
        return u == 0 ? 1 : Double(a.intersection(b).count) / Double(u)
    }

    // MARK: Storage

    private static func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
    private static func file(_ day: String) -> URL { folder.appendingPathComponent(day + ".jsonl") }
    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private func append(_ e: Entry) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard var d = try? Self.enc.encode(e) else { return }
        d.append(0x0A)
        let url = Self.file(Self.day(e.t))
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: d) }
        else { try? d.write(to: url) }
    }

    /// The last entry was extended: rewrite today's file (small, once per change).
    private func rewriteToday() {
        let today = Self.day(Date())
        let lines = recent.filter { Self.day($0.t) == today }.compactMap { try? Self.enc.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: Self.file(today), atomically: true, encoding: .utf8)
    }

    private func load(days: Int) {
        for i in 0..<days {
            let d = Self.day(Date().addingTimeInterval(-Double(i) * 86400))
            guard loadedDays.insert(d).inserted, let s = try? String(contentsOf: Self.file(d), encoding: .utf8) else { continue }
            recent += s.split(separator: "\n").compactMap { try? Self.dec.decode(Entry.self, from: Data($0.utf8)) }
        }
        recent.sort { $0.t < $1.t }
        count = recent.count
    }

    private func prune() {
        let keep = Set((0..<30).map { Self.day(Date().addingTimeInterval(-Double($0) * 86400)) })
        for f in (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" && !keep.contains(f.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
        let cutoff = Date().addingTimeInterval(-Double(Self.imageDays) * 86400).timeIntervalSince1970
        for f in (try? FileManager.default.contentsOfDirectory(at: Self.images, includingPropertiesForKeys: nil)) ?? [] {
            if let stem = f.lastPathComponent.split(separator: ".").first, let t = Double(stem), t < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    func forgetAll() {
        stop()
        try? FileManager.default.removeItem(at: Self.folder)
        recent = []; loadedDays = []; count = 0; lastHash = []; lastTokens = []
        if enabled { start() }
    }

    /// The latest entries that have a frame (debugging).
    func newest(_ n: Int) -> [Entry] { Array(recent.filter { $0.image != nil }.suffix(n)) }

    // MARK: Recall

    struct Hit { let entry: Entry; let snippet: String; let score: Int }

    /// Snippets from what was on screen that match the question, newest first among the best.
    func search(_ question: String, limit: Int = 6) -> [Hit] {
        var words = Set(ScreenMemory.tokens(question)).subtracting(ScreenMemory.stop)
            .subtracting(["what", "was", "were", "did", "see", "saw", "seen", "earlier", "before", "remember", "yesterday", "today", "price", "show", "showed", "page", "screen", "looking", "looked", "when", "where", "which", "how", "much", "many", "about", "there", "that", "find", "tell",
                          "last", "past", "minute", "minutes", "hour", "hours", "ago", "five", "ten", "few", "couple", "morning", "afternoon", "doing", "done", "work", "working"])
        if words.isEmpty { words = Set(ScreenMemory.tokens(question)) }
        guard !words.isEmpty else { return [] }
        var hits: [Hit] = []
        for e in recent.reversed() {
            let hay = (e.app + " " + e.title + " " + e.text).lowercased()
            let matched = words.filter { hay.contains($0) }
            guard !matched.isEmpty else { continue }
            var score = matched.count * 10
            if words.contains(where: { e.app.lowercased().contains($0) || e.title.lowercased().contains($0) }) { score += 8 }
            // Recent things first when scores tie.
            score -= Int(min(9, Date().timeIntervalSince(e.t) / 86400))
            hits.append(Hit(entry: e, snippet: Self.snippet(e.text, around: matched), score: score))
            if hits.count > 400 { break }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Lines of the text that contain a matched word, plus their neighbours — numbers and prices are usually next to the name.
    nonisolated static func snippet(_ text: String, around words: Set<String>) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var keep = Set<Int>()
        for (i, l) in lines.enumerated() where words.contains(where: { l.lowercased().contains($0) }) {
            for j in max(0, i - 2)...min(lines.count - 1, i + 3) { keep.insert(j) }
        }
        let out = keep.sorted().map { lines[$0] }.joined(separator: " | ")
        return String(out.prefix(700))
    }

    // MARK: Time windows ("what did I do in the last five minutes?")

    /// The period a question refers to, or nil when it names none.
    nonisolated static func window(in question: String) -> (from: Date, to: Date, label: String)? {
        let q = question.lowercased()
        let now = Date()
        let cal = Calendar.current
        func num(_ s: String) -> Double? {
            let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                                           "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "half an": 0.5, "couple of": 2, "few": 3]
            return Double(s) ?? words[s]
        }
        if let m = q.firstMatch(of: #/(?:last|past|previous)\s+(?:(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty|fifty|sixty|half an|couple of|few)\s+)?(minute|min|hour|hr|day|week)s?/#) {
            let n = m.1.flatMap { num(String($0)) } ?? 1
            let unit: Double = ["minute": 60, "min": 60, "hour": 3600, "hr": 3600, "day": 86400, "week": 604800][String(m.2)] ?? 60
            return (now.addingTimeInterval(-n * unit), now, "the last \(m.0.replacingOccurrences(of: "last ", with: "").replacingOccurrences(of: "past ", with: "").replacingOccurrences(of: "previous ", with: ""))")
        }
        if let m = q.firstMatch(of: #/(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty|fifty|sixty|half an|couple of|few)\s+(minute|min|hour|hr|day)s?\s+ago/#) {
            let n = num(String(m.1)) ?? 1
            let unit: Double = ["minute": 60, "min": 60, "hour": 3600, "hr": 3600, "day": 86400][String(m.2)] ?? 60
            let center = now.addingTimeInterval(-n * unit)
            let half = max(300, n * unit * 0.25)
            return (center.addingTimeInterval(-half), center.addingTimeInterval(half), "around \(m.0)")
        }
        let startToday = cal.startOfDay(for: now)
        if q.contains("this morning") { return (startToday.addingTimeInterval(5 * 3600), startToday.addingTimeInterval(12 * 3600), "this morning") }
        if q.contains("this afternoon") { return (startToday.addingTimeInterval(12 * 3600), startToday.addingTimeInterval(18 * 3600), "this afternoon") }
        if q.contains("yesterday") {
            let y = startToday.addingTimeInterval(-86400)
            if q.contains("morning") { return (y.addingTimeInterval(5 * 3600), y.addingTimeInterval(12 * 3600), "yesterday morning") }
            if q.contains("afternoon") { return (y.addingTimeInterval(12 * 3600), y.addingTimeInterval(18 * 3600), "yesterday afternoon") }
            if q.contains("evening") { return (y.addingTimeInterval(17 * 3600), startToday, "yesterday evening") }
            return (y, startToday, "yesterday")
        }
        if q.contains("this week") || q.contains("the week") {
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startToday.addingTimeInterval(-6 * 86400)
            return (start, now, "this week")
        }
        if q.contains("today") || q.contains("so far") { return (startToday, now, "today") }
        return nil
    }

    /// The window crosses midnight: times need a day, not just HH:mm.
    nonisolated static func multiDay(_ from: Date, _ to: Date) -> Bool { !Calendar.current.isDate(from, inSameDayAs: to) && to.timeIntervalSince(from) > 86400 }

    /// "14:27–15:02" within a day, "Mon 3 Nov – Tue 10 Nov" across days.
    nonisolated static func range(_ from: Date, _ to: Date) -> String {
        guard multiDay(from, to) else { return "\(clock(from))–\(clock(to))" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return "\(f.string(from: from)) – \(f.string(from: to))"
    }

    nonisolated static func dayClock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d) }

    struct Span { let from: Date; let to: Date; let app: String; let title: String; let text: String }

    /// What was on screen in a period, merged into spans per app+window, longest first within time order. Compact enough for a prompt.
    func timeline(from: Date, to: Date, limit: Int = 40) -> [Span] {
        var spans: [Span] = []
        for e in recent where e.until >= from && e.t <= to {
            if var last = spans.last, last.app == e.app, last.title == e.title, e.t.timeIntervalSince(last.to) < 120 {
                last = Span(from: last.from, to: max(last.to, e.until), app: last.app, title: last.title, text: e.text.count > last.text.count ? e.text : last.text)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(from: e.t, to: e.until, app: e.app, title: e.title, text: e.text))
            }
        }
        if spans.count <= limit { return spans }
        // Too many: keep the longest ones, back in time order.
        let keep = Set(spans.enumerated().sorted { $0.element.to.timeIntervalSince($0.element.from) > $1.element.to.timeIntervalSince($1.element.from) }.prefix(limit).map(\.offset))
        return spans.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    nonisolated static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
    nonisolated static let stop: Set<String> = ["the", "and", "to", "in", "on", "of", "for", "me", "my", "it", "this", "that", "from", "can", "you", "please", "with", "an", "is", "at", "up", "do", "i"]

    nonisolated static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    nonisolated static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' HH:mm" : Calendar.current.isDateInYesterday(d) ? "'yesterday' HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: d)
    }
}
