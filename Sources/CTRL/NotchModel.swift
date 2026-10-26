import AppKit
import EventKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case opened([WindowManager.Target], detail: String?)
        case media(InstalledApp?, title: String, detail: String?)
        case system(symbol: String, title: String, detail: String?)
        case unsure(InstalledApp?)
        case message(String)
        case level(LevelKind, Int)   // compact HUD beside the notch
        case nowPlaying              // expanded player card (the compact one shows whenever music plays)
        case timerDone(String)       // expanded "Timer done" alert
        case badge(symbol: String, text: String, tint: Color)   // compact: icon left, short text right
        case answer(title: String, text: String)                // expanded, a few lines (screen summaries, agenda)
        case agenda(day: Date, events: [AgendaItem], more: Int) // expanded, iOS Calendar widget style
        case playlists(title: String, items: [PlaylistItem])    // expanded: artwork tiles to pick from
    }
    struct AgendaItem: Equatable { let time: String; let title: String; let color: Color; let allDay: Bool }
    struct PlaylistItem: Equatable { let name: String; let artwork: NSImage? }

    /// Background events (volume keys, battery, Wi-Fi…): only when the notch isn't busy with you.
    func ambient(_ p: Phase, for seconds: Double = 1.6) {
        switch phase {
        case .idle, .level: show(p, for: seconds)
        default:
            if case .level = p { return }
            guard !isLocked, phase != .listening, phase != .thinking else { return }
            show(p, for: seconds)
        }
    }

    func startObservers() {
        // Volume keys: macOS shows its own HUD, so the notch stays quiet (voice "volume up" still shows the bar).
        NowPlaying.shared.start()   // for "what's playing" / media commands; no automatic popups
        Timers.shared.onFinish = { [weak self] t in
            // Always shown, even mid-command: it's what you asked for.
            self?.show(.timerDone(t.label ?? Timers.spoken(t.total) + " timer"), for: 6)
        }
        WiFi.shared.start()
        Bluetooth.shared.start()
        // Battery: only when you ask ("how much battery"), no automatic low-battery popups.
        Connectivity.shared.start()
        Agenda.shared.onSoon = { [weak self] e, minutes in
            NSSound(named: "Tink")?.play()
            let join = Agenda.meetingURL(e) != nil ? " · say “join my meeting”" : ""
            self?.ambient(.system(symbol: "calendar.badge.clock", title: e.title ?? "Meeting", detail: "In \(minutes) min\(join)"), for: 6)
            Memory.record(said: "(automatic)", did: "reminded: \(e.title ?? "meeting") starts in \(minutes) min")
        }
        Agenda.shared.start()
        // Brightness keys: same, macOS shows its own HUD.
        KeyCommands.startTracking()
        Clipboard.shared.start()
        Timers.shared.restore()
    }
    private var lastTyped: String?
    private var peakLevel: CGFloat = 0   // loudest sound this press: 0 = the mic heard nothing

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)

    private let recorder = SpeechRecorder()
    private var menuSnapshot: MenuReader.Snapshot?
    private var frontApp: NSRunningApplication?
    private var clickables: [Clicker.Element] = []
    private var lastCommand: String?
    private var lastCommandAt = Date.distantPast
    private var dictating = false
    private var typedInDictation = false   // first dictated sentence gets no leading space
    private var lastActionDisplay: CGDirectDisplayID?
    private var pendingPlaylists: ([String], Date)?

    /// "the second one" / "Mycelia" / "play jet fuel" → one of the offered names.
    static func pick(_ spoken: String, from names: [String]) -> String? {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let s = fold(spoken)
        let ordinals = [["first", "one", "1"], ["second", "two", "2"], ["third", "three", "3"], ["fourth", "four", "4", "last"]]
        let words = Set(s.components(separatedBy: CharacterSet.alphanumerics.inverted))
        if let i = ordinals.firstIndex(where: { !words.isDisjoint(with: $0) && (s.contains("one") || s.count < 12) }), i < names.count { return names[i] }
        let letters: (String) -> String = { fold($0).filter { $0.isLetter || $0.isNumber } }
        let said = letters(spoken)
        return names.max { a, b in score(letters(a), said) < score(letters(b), said) }.flatMap { score(letters($0), said) >= 0.75 ? $0 : nil }
    }
    private static func score(_ name: String, _ said: String) -> Double {
        guard !name.isEmpty else { return 0 }
        if said.contains(name) || name.contains(said) && said.count > 3 { return 1 }
        // Shared characters in order (longest common subsequence) relative to the name.
        let a = Array(name), b = Array(said)
        var dp = Array(repeating: 0, count: b.count + 1)
        for x in a { var prev = 0; for j in 0..<b.count { let t = dp[j + 1]; dp[j + 1] = x == b[j] ? prev + 1 : max(dp[j + 1], dp[j]); prev = t } }
        return Double(dp[b.count]) / Double(a.count)
    }

    /// Short-term memory entry: what you said, what CTRL did, where.
    private func remember(_ said: String, _ outcome: CommandRouter.Outcome) {
        var did: String
        switch phase {
        case .opened(let targets, _): did = "opened " + targets.map { t in
            switch t { case .app(let a): a.name; case .site(let u): u.host() ?? u.absoluteString } }.joined(separator: ", ")
        case .media(_, let title, let detail), .system(_, let title, let detail): did = title + (detail.map { " · \($0)" } ?? "")
        case .message(let m): did = m
        case .level(let k, let v): did = "\(k.label.lowercased()) set to \(v)%"
        case .nowPlaying: did = NowPlaying.shared.track.map { "now playing: \($0.title)" + ($0.artist.map { " by \($0)" } ?? "") + ($0.playing ? "" : " (paused)") } ?? "music"
        case .timerDone(let l): did = "\(l) finished"
        case .answer(let title, let text): did = "\(title): \(text.prefix(120))"
        case .agenda(_, let events, _): did = "showed the agenda: " + events.map { "\($0.time) \($0.title)" }.joined(separator: ", ")
        case .playlists(_, let items): did = "offered playlists: " + items.map(\.name).joined(separator: ", ")
        case .badge(_, let text, _): did = text
            if case .focus(let m) = outcome { did = m == "off" ? "Focus turned off" : "\(m) Focus turned on" }
            if case .bluetooth(let n, _, let c) = outcome { did = "\(n) \(c ? "connected" : "disconnected") (\(text))" }
            if case .joinWiFi(let n) = outcome { did = "joined Wi-Fi \(n)" }
        default:
            switch outcome {
            case .type(let t, _), .continueTyping(let t): did = "typed “\(t.prefix(60))”"
            case .notACommand, .unsure: return
            default: did = "\(outcome)".prefix(80).description
            }
        }
        let app: String? = {
            if case .window(_, let a) = outcome { return a.localizedName }
            if case .menu(_, let a) = outcome { return a.localizedName }
            return frontApp?.localizedName
        }()
        Memory.record(said: said, did: did, app: app, display: lastActionDisplay)
    }
    private var router: CommandRouter? { Keychain.apiKey.map { CommandRouter(client: TypeSafeClient(apiKey: $0)) } }
    private var dismissTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init() {
        recorder.onPartial = { [weak self] text in
            guard let self, !self.isLocked else { return }
            self.transcript = text
        }
        // Locked mode: show only the sentence in progress; run each one as it finalizes.
        recorder.onVolatile = { [weak self] text in
            guard let self, self.isLocked, self.phase == .listening else { return }
            self.transcript = text
        }
        recorder.onSegment = { [weak self] text in self?.enqueue(text) }
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if self.firstLevel { self.firstLevel = false; Self.lap("first audio level") }
            self.peakLevel = max(self.peakLevel, CGFloat(level))
            self.levels.removeFirst()
            self.levels.append(CGFloat(level))
        }
    }

    func prepare() async {
        recorder.watchDevices()
        try? await recorder.prepare()
    }

    /// `CTRL_DEMO=1`: cycles through every state for visual checks.
    /// `CTRL_LOCKTEST=file.aiff`: locked mode fed from an audio file instead of the mic.
    func lockTest(_ path: String) {
        isLocked = true
        accepting = true
        dictationOnly = ProcessInfo.processInfo.environment["CTRL_LOCKDICT"] == "1"
        frontApp = NSWorkspace.shared.frontmostApplication
        phase = .listening
        Task {
            let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
            let a = SpeechAnalyzer(modules: [t])
            guard let f = try? AVAudioFile(forReading: URL(filePath: path)) else { return print("no file") }
            let results = Task { for try await x in t.results where x.isFinal { print("segment:", String(x.text.characters)); self.enqueue(String(x.text.characters)) } }
            try? await a.start(inputAudioFile: f, finishAfterFile: true)
            _ = try? await results.value
        }
    }
    /// CTRL_GALLERY=1: steps through every notch design, writing each name to /tmp/butterfly-gallery/state for capture.
    func runGallery() {
        moveToActiveScreen()
        let safari = AppCatalog.shared.app(named: "Safari"), slack = AppCatalog.shared.app(named: "Slack"), music = AppCatalog.shared.app(named: "Music")
        let dir = URL(fileURLWithPath: "/tmp/butterfly-gallery"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func mark(_ s: String) { try? s.write(to: dir.appending(path: "state"), atomically: true, encoding: .utf8) }
        Task {
            let wave = Task { while !Task.isCancelled { levels.removeFirst(); levels.append(.random(in: 0.2...1)); try? await Task.sleep(for: .milliseconds(110)) } }
            var steps: [(String, () -> Void)] = [
                ("01-listening", { self.transcript = ""; self.phase = .listening }),
                ("02-transcript", { self.transcript = "open slack and safari side by side"; self.phase = .listening }),
                ("03-transcript-long", { self.transcript = "put my browser and discord side by side on the big screen please"; self.phase = .listening }),
                ("04-locked", { self.isLocked = true; self.transcript = ""; self.phase = .listening }),
                ("05-dictation", { self.isLocked = false; self.dictationOnly = true; self.transcript = ""; self.phase = .listening }),
                ("06-thinking", { self.dictationOnly = false; self.transcript = "what's on my calendar today"; self.phase = .thinking }),
                ("08-media", { self.phase = .media(music, title: "Ambient Deep Focus Music", detail: "Playlist") }),
                ("09-system", { self.phase = .system(symbol: "moon.fill", title: "Dark mode on", detail: nil) }),
                ("10-system-working", { self.phase = .system(symbol: "magnifyingglass", title: "Searching…", detail: "Google") }),
                ("11-unsure", { self.phase = .unsure(slack) }),
                ("12-message", { self.phase = .message("Allow Screen Recording for Butterfly") }),
                ("13-volume", { self.phase = .level(.volume, 60) }),
                ("14-brightness", { self.phase = .level(.brightness, 40) }),
                ("15-offline", { self.phase = .system(symbol: "wifi.slash", title: "No internet", detail: "Couldn’t process that request. Check your connection.") }),
                ("16-agenda", { self.phase = .agenda(day: Date(), events: [
                    .init(time: "All day", title: "Aiša atvažiuoja pas mus", color: .red, allDay: true),
                    .init(time: "All day", title: "Pasikeisti kapas", color: .red, allDay: true),
                    .init(time: "11:00", title: "Team Sync", color: .orange, allDay: false),
                    .init(time: "13:00", title: "Lunch with Ana", color: .green, allDay: false),
                    .init(time: "16:30", title: "Design review", color: .blue, allDay: false)], more: 2) }),
                ("16b-answer", { self.phase = .answer(title: "Screen summary", text: "A Slack thread about the launch: Ana wants the copy finalised by Friday and asks who owns the pricing page.") }),
                ("17-playlists", {
                    let names = MediaController.ownPlaylists().prefix(4)
                    self.phase = .playlists(title: "No “focus” playlist", items: MediaController.artwork(for: Array(names)).map { PlaylistItem(name: $0.0, artwork: $0.1) })
                }),
                ("18-timer-done", { self.phase = .timerDone("5 minute timer") }),
                ("_play", { _ = MediaController.play(playlist: MediaController.ownPlaylists().first ?? "Library") }),
                ("19b-now-playing", { self.phase = .nowPlaying }),
            ]
            if let safari, let slack { steps.insert(("07-opened", { self.phase = .opened([.app(safari), .app(slack)], detail: "side by side") }), at: 6) }
            if let only = ProcessInfo.processInfo.environment["CTRL_GALLERY_ONLY"] { steps = steps.filter { $0.0.contains(only) } }
            for (name, apply) in steps {
                withAnimation(.smooth) { apply() }
                try? await Task.sleep(for: .milliseconds(name == "_play" ? 2500 : 1100))
                if !name.hasPrefix("_") { mark(name) }
                try? await Task.sleep(for: .milliseconds(700))
            }
            wave.cancel()
            _ = await MediaController.perform(.pause, preferred: nil, query: nil)
            mark("done")
            close()
        }
    }

    func runDemo() {
        moveToActiveScreen()
        Task {
            let safari = AppCatalog.shared.app(named: "Safari")
            phase = .listening
            transcript = ""
            for _ in 0..<14 {
                levels.removeFirst(); levels.append(.random(in: 0.2...1))
                try? await Task.sleep(for: .milliseconds(120))
            }
            let sentence = "put my browser and discord side by side on the big screen please"
            let words = sentence.split(separator: " ")
            for n in 1...words.count {
                transcript = words.prefix(n).joined(separator: " ")
                for _ in 0..<3 {
                    levels.removeFirst(); levels.append(.random(in: 0.2...1))
                    try? await Task.sleep(for: .milliseconds(110))
                }
            }
            phase = .thinking
            try? await Task.sleep(for: .seconds(1.2))
            if let safari, let slack = AppCatalog.shared.app(named: "Slack") {
                phase = .opened([.app(safari), .app(slack)], detail: "side by side")
            }
            try? await Task.sleep(for: .seconds(1.5))
            close()
        }
    }

    // MARK: Hotkey events

    /// Right ⌥: dictation only. What you say gets typed, nothing is interpreted.
    @Published private(set) var dictationOnly = false

    func begin(dictation: Bool = false) {
        if Date().timeIntervalSince(Self.armedAt) > 0.5 { Self.t0 = Date() } else { Self.t0 = Self.armedAt }
        firstLevel = true
        defer { Self.lap("begin() returned") }
        dictationOnly = dictation
        dismissTask?.cancel()
        moveToActiveScreen()
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        Cues.listening()
        Ducker.duck()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if dictation {
            frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        }
        startTask = Task {
            do {
                Self.lap("recorder start")
                // The mic starts off the main thread (~0.4 s): read the front app's menus/buttons meanwhile.
                if !dictation { Task { self.readFrontApp(); Self.lap("readFrontApp done") } }
                try await recorder.start(onAudio: { Self.lap("mic live") })
                Self.lap("analyzer started")
            }
            catch { show(.message("Mic error: \(error.localizedDescription)")) }
        }
    }

    private var firstLevel = true
    private var lastFinalizeMs: Int?
    static var t0 = Date()
    static func lap(_ s: String) { if ProcessInfo.processInfo.environment["CTRL_TIMING"] == "1" { print(String(format: "%5.0f ms  %@", Date().timeIntervalSince(t0) * 1000, s)); fflush(stdout) } }

    // MARK: Multiple displays

    /// Bumps when the notch moves to another screen, so the view re-measures.
    @Published private(set) var screenID = 0
    var onScreenChange: (() -> Void)?

    /// The notch opens on the screen your mouse is on.
    private func moveToActiveScreen() {
        guard phase == .idle, let s = NotchMetrics.screenUnderMouse, s != NotchMetrics.screen else { return }
        NotchMetrics.active = s
        screenID += 1
        onScreenChange?()
    }

    /// Read the front app's menus and buttons while you talk, so it costs no time later.
    private func readFrontApp() {
        menuSnapshot = nil
        frontApp = nil
        clickables = []
        cursorSnapshot = nil
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontApp = front
            menuSnapshot = MenuReader.snapshot(of: front)
            clickables = Clicker.elements(of: front)
            cursorSnapshot = CursorControl.snapshot(of: front)
        }
    }
    private var cursorSnapshot: CursorControl.Snapshot?

    // MARK: Locked mode (⌥⇧): keep listening, run each sentence when you pause

    @Published private(set) var isLocked = false
    private var accepting = false          // still taking sentences (true until the mic fully stops)
    private var queue: [String] = []
    private var working = false

    func lock(dictation: Bool = false) {
        guard !isLocked else { return }
        isLocked = true
        accepting = true
        typedInDictation = false
        if phase != .listening { begin(dictation: dictation) } else { dismissTask?.cancel(); if dictation { dictationOnly = true } }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        dictating = false
        dictationOnly = false
        Cues.stopped()
        Ducker.restore()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Task {
            await startTask?.value
            _ = await recorder.stop()   // flushes the last sentence through onSegment
            accepting = false
            if !working { close() }
        }
    }

    private func enqueue(_ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepting, s.count > 1 else { return }
        queue.append(s)
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let chunk = queue.removeFirst()
                // Locked dictation: every sentence is just typed. Only "stop listening" / "stop dictating" end it.
                if dictationOnly {
                    for part in Self.controlSplit(chunk) {
                        if part.lowercased().firstMatch(of: #/^(ok(ay)?,? )?(stop( (listening|dictating|dictation|typing))?|that's all|i'm done)[.!]?$/#) != nil {
                            unlock(); break
                        }
                        frontApp?.activate()
                        await Typer.type((typedInDictation ? " " : "") + part, pressReturn: false)
                        typedInDictation = true
                    }
                    transcript = ""
                    continue
                }
                // The recognizer can merge "Stop typing. Stop listening." into one result: handle control phrases per sentence.
                for next in Self.controlSplit(chunk) {
                    if !isLocked && !accepting { break }
                    if next.lowercased().firstMatch(of: #/^(ok(ay)?,? )?(stop( listening)?|that's all|i'm done|done)[.!]?$/#) != nil {
                        unlock()   // "stop listening" ends locked mode
                        continue
                    }
                    if dictating, next.lowercased().firstMatch(of: #/^(ok(ay)?,? )?(stop|done|finish(ed)?|end) (typing|dictating|dictation)[.!]?$/#) != nil {
                        dictating = false
                        show(.system(symbol: "character.cursor.ibeam", title: "Stopped typing", detail: nil), for: 1.0)
                        continue
                    }
                    dismissTask?.cancel()
                    transcript = next
                    phase = .thinking
                    readFrontApp()   // the last command may have changed what's in front
                    await handle(next)
                }
                // Let you see the result before the next one replaces it.
                try? await Task.sleep(for: .milliseconds(queue.isEmpty ? 0 : 700))
            }
            working = false
            if !accepting { close() }
        }
    }

    /// Splits off control phrases ("stop typing", "stop listening") from a merged result; other text stays whole.
    private static func controlSplit(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let isControl = t.lowercased().firstMatch(of: #/^(ok(ay)?,? )?((stop|done|finish(ed)?|end) (typing|dictating|dictation|listening)|stop|that's all|i'm done|done)[.!]?$/#) != nil
            if isControl {
                if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                parts.append(t)
            } else {
                current += s
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? [text] : parts
    }

    func end() {
        guard phase == .listening, !isLocked else { return }
        Cues.stopped()
        Ducker.restore()   // on release, before the command runs ("volume up" starts from your real level)
        let released = Date()
        Task {
            await startTask?.value
            let text = await recorder.stop()
            lastFinalizeMs = Int(Date().timeIntervalSince(released) * 1000)
            let silent = peakLevel < 0.02
            peakLevel = 0
            guard !text.isEmpty else {
                // Total silence = wrong or muted mic, not a quiet voice: say which one, and where to change it.
                if silent { return show(.system(symbol: "mic.slash", title: "Heard nothing", detail: "Using \(recorder.micName ?? "no microphone") · change it in Settings"), for: 3) }
                return close()
            }
            if dictationOnly {
                dictationOnly = false
                close()
                frontApp?.activate()
                try? await Task.sleep(for: .milliseconds(80))
                await Typer.type(text, pressReturn: false)
                lastTyped = text
                registerTypedUndo(text)
                Memory.record(said: text, did: "typed (dictation)", app: frontApp?.localizedName)
                return
            }
            transcript = text
            phase = .thinking
            await handle(text)
        }
    }

    func cancel() {
        guard !isLocked else { return }
        dictationOnly = false
        Task {
            await startTask?.value
            await recorder.cancel()
            Ducker.restore()
            close()
        }
    }

    // MARK: Routing

    /// Short label for the debug tree: the enum case and its main values.
    private static func describe(_ v: Any) -> String {
        var s = String(describing: v)
        for noise in ["CTRL.", "Butterfly.", "Optional(", "InstalledApp(name: "] { s = s.replacingOccurrences(of: noise, with: "") }
        s = s.replacingOccurrences(of: #", url: file://[^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "…", options: .regularExpression)
        return s.count > 180 ? String(s.prefix(180)) + "…" : s
    }

    /// CTRL_SAY="a|b|c": runs each as if spoken (debug, for the decision tree).
    /// CTRL_PTT=1: simulate holding ⌥ for 2 s, five times (timing test).
    /// ⌥ went down: start the mic during the hold delay; cancelled if it was a shortcut.
    func arm() {
        Self.armedAt = Date()
        recorder.arm()
        TypeSafeClient.preconnect()
    }
    static var armedAt = Date.distantPast
    func disarm() { recorder.disarm() }

    func pttTest() {
        Task { for _ in 0..<5 { arm(); try? await Task.sleep(for: .milliseconds(100)); begin(); Self.lap("notch shown (key down + hold delay)"); try? await Task.sleep(for: .seconds(1.5)); let r0 = Date(); _ = await recorder.stop(); print(String(format: "stop (finalize) %.0f ms", Date().timeIntervalSince(r0) * 1000)); fflush(stdout); phase = .idle; try? await Task.sleep(for: .seconds(1)) } ; exit(0) }
    }

    /// CTRL_SPEAK="a|b": holds ⌥ while macOS `say` speaks each line into the mic, then releases (end-to-end timing).
    func speakTest(_ lines: [String]) {
        Task {
            for l in lines {
                arm(); try? await Task.sleep(for: .milliseconds(100)); begin()
                try? await Task.sleep(for: .milliseconds(500))
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", "Samantha", l]
                try? p.run(); while p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(300))
                print("released, live: \(transcript)"); fflush(stdout)
                end()
                try? await Task.sleep(for: .seconds(4))
            }
            exit(0)
        }
    }

    func say(_ lines: [String]) {
        Task { for l in lines { await handle(l); try? await Task.sleep(for: .seconds(2.5)) } }
    }

    private func handle(_ text: String) async {
        let trace = DecisionTrace.shared
        trace.begin(text)
        trace.add(.heard, "“\(text)”" + (lastFinalizeMs.map { _ in "" } ?? ""), [isLocked ? "locked mode" : nil, dictating ? "dictating" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        trace.add(.context, frontApp?.localizedName ?? "no front app",
                  "\(menuSnapshot?.items.count ?? 0) menu items · \(clickables.count) clickable elements" + (cursorSnapshot.map { " · Cursor: \($0.chats.count) chats" } ?? ""))
        if let ms = lastFinalizeMs { trace.add(.context, "Speech finalized after release", nil, ms: ms); lastFinalizeMs = nil }
        defer { trace.end() }
        // Just offered playlists: saying one of them (or "the first one") plays it.
        if let (names, at) = pendingPlaylists, Date().timeIntervalSince(at) < 30 {
            pendingPlaylists = nil
            if let name = Self.pick(text, from: names), let r = MediaController.play(playlist: name) {
                trace.add(.rule, "playlist follow-up", "picked “\(name)” from the offered list (no model call)")
                trace.add(.outcome, "play playlist", name)
                try? await Task.sleep(for: .milliseconds(250))
                if NowPlaying.shared.track != nil { show(.nowPlaying, for: 2.6) }
                else { show(.media(r.player, title: r.title, detail: r.detail), for: 2.2) }
                return
            }
        }
        guard let key = Keychain.apiKey else {
            trace.add(.rule, "no API key", "local fallbacks only")
            // No key yet: simple fallbacks so the app still works.
            if let app = AppCatalog.shared.localMatch(text) { return launch(app) }
            let site = Vocabulary.matches(in: text).first { $0.contains(".") } ?? URLExtractor.candidates(in: text).first
            if let site, let url = URLExtractor.url(for: site) { return openSite(url) }
            return show(.message("Add your TypeSafe key from the menu bar"))
        }
        do {
            let router = CommandRouter(client: TypeSafeClient(apiKey: key))
            let previous = Date().timeIntervalSince(lastCommandAt) < 120 ? lastCommand : nil
            let routed = Date()
            var outcome = try await router.route(text, menu: menuSnapshot, front: frontApp, elements: clickables,
                                                 previous: previous, dictating: dictating, cursor: cursorSnapshot)
            if case .repeatLast = outcome, let previous {
                trace.add(.rule, "repeat", "re-running “\(previous)” in the current context")
                // Same words, fresh context: "close this tab" → "this one too" closes the new current tab.
                outcome = try await router.route(previous, menu: menuSnapshot, front: frontApp, elements: clickables)
            } else {
                switch outcome {
                case .notACommand, .unsure, .needAddress, .fileNotFound, .continueTyping, .startDictation, .repeatLast: break
                default: lastCommand = text; lastCommandAt = Date()
                }
            }
            // Mid-dictation, a "type" result is just more text: keep the space between sentences.
            if dictating, case .type(let t, let ret) = outcome {
                outcome = .continueTyping(ret ? t + " and press enter" : t)
            }
            // Dictation continues (locked mode) after "type …" until a real command.
            switch outcome {
            case .type, .startDictation, .continueTyping: dictating = isLocked
            case .notACommand: break
            default: dictating = false
            }
            trace.add(.outcome, Self.describe(outcome), nil, ms: Int(Date().timeIntervalSince(routed) * 1000))
            if case .routine(let r) = outcome { return await run(r, router: router) }
            lastActionDisplay = nil
            let ran = Date()
            await perform(outcome)
            trace.add(.result, Self.describe(phase), nil, ms: Int(Date().timeIntervalSince(ran) * 1000))
            remember(text, outcome)
        } catch {
            trace.add(.error, error.localizedDescription, Connectivity.shared.explains(error) ? "offline" : nil)
            if let app = AppCatalog.shared.localMatch(text) { return launch(app) }
            if Connectivity.shared.explains(error) { return show(.system(symbol: "wifi.slash", title: "No internet", detail: "Couldn’t process that request. Check your connection."), for: 3) }
            show(.message(error.localizedDescription))
        }
    }

    /// Runs a routine (from voice or the Routines window's Run Now).
    func run(_ r: Routine) {
        guard let key = Keychain.apiKey else { return show(.message("Add your TypeSafe key from the menu bar")) }
        Task { await run(r, router: CommandRouter(client: TypeSafeClient(apiKey: key))) }
    }

    private func run(_ r: Routine, router: CommandRouter) async {
        // Each step is a normal command: route it, run it, give apps a moment to appear.
        let steps = r.runnableSteps
        for (i, step) in steps.enumerated() {
            show(.media(nil, title: r.name, detail: "\(i + 1)/\(steps.count) · \(step)"), for: 30)
            if let o = try? await router.route(step) { await perform(o) }
            try? await Task.sleep(for: .seconds(1.2))
        }
        show(.media(nil, title: r.name, detail: "done"), for: 1.4)
    }

    private func perform(_ outcome: CommandRouter.Outcome) async {
            if case .undo = outcome {} else if case .notACommand = outcome {} else { prepareUndo(outcome) }
            switch outcome {
            case .undo:
                if let step = Undo.pop() {
                    await step.run()
                    show(.system(symbol: "arrow.uturn.backward", title: "Undid", detail: step.what), for: 1.4)
                } else {
                    frontApp?.activate()
                    try? await Task.sleep(for: .milliseconds(60))
                    Keys.press(6, flags: .maskCommand)   // ⌘Z
                    show(.system(symbol: "arrow.uturn.backward", title: "Undo", detail: frontApp?.localizedName), for: 1.2)
                }
            case .calendar(let action): await calendar(action)
            case .navigate(let action):
                let r = await KeyCommands.perform(action, in: frontApp)
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: 0.9)
            case .edit(let action):
                let r = await KeyCommands.perform(action, in: frontApp, typed: lastTyped)
                if action == .scratch { lastTyped = nil }
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: 1.0)
            case .screen(let action, let request): await screen(action, request: request)
            case .agent(let request): await agent(request)
            case .webSearch(let url, let query, let engine):
                BrowserTab.open(url)
                show(.system(symbol: "magnifyingglass", title: query, detail: "Searching \(engine)"), for: 1.6)
            case .askBrowser(let question):
                let browser = await BrowserTab.ask(question)
                show(.media(browser, title: question, detail: "Asking \(browser?.name ?? "the browser")"), for: 1.8)
            case .press(let combo):
                await KeyPress.perform(combo, in: frontApp)
                show(.system(symbol: "keyboard", title: combo.label + (combo.times > 1 ? " ×\(combo.times)" : ""), detail: nil), for: 0.9)
            case .cursor(let action, let chat, let project, let message):
                guard let snap = cursorSnapshot else { break }
                let r = await CursorControl.perform(action, chat: chat, project: project, message: message, snapshot: snap, menu: menuSnapshot)
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: 1.8)
            case .quickSetting(let key, let on):
                guard let s = QuickSettings.setting(key) else { break }
                let before = s.get()
                let r = QuickSettings.apply(s, on: on)
                if let before { Undo.register("\(s.title) back \(before ? "on" : "off")") { s.set(before) } }
                show(.system(symbol: r.symbol, title: r.title, detail: nil), for: 1.6)
            case .audioOutput(let d):
                let ok = AudioOutput.set(d.id)
                show(ok ? .badge(symbol: AudioOutput.symbol(d.name), text: d.name, tint: .blue) : .message("Couldn't switch to \(d.name)"), for: 1.8)
            case .audioOutputBluetooth(let name, let address):
                show(.system(symbol: AudioOutput.symbol(name), title: "Connecting \(name)…", detail: nil), for: 12)
                guard await Bluetooth.shared.connect(address, on: true) else { show(.message("Couldn't connect \(name)"), for: 2); break }
                // The audio device shows up a moment after the Bluetooth link.
                var dev: AudioOutput.Device?
                for _ in 0..<20 {
                    dev = AudioOutput.devices.first { $0.name == name }
                    if dev != nil { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if let dev { AudioOutput.set(dev.id) }
                show(.badge(symbol: AudioOutput.symbol(name), text: name, tint: dev != nil ? .blue : .orange), for: 1.8)
            case .pasteHistory(let item):
                close()
                await Clipboard.shared.paste(item, into: frontApp)
            case .clipboardList:
                let list = Clipboard.shared.items.prefix(5).map { "· " + $0.text.prefix(60).replacingOccurrences(of: "\n", with: " ") }
                show(list.isEmpty ? .message("Nothing copied yet") : .answer(title: "Clipboard", text: list.joined(separator: "\n")), for: 5)
            case .routine: break   // handled by the caller; routines don't nest
            case .type(let text, let pressReturn):
                frontApp?.activate()
                close()   // notch out of the way; typing goes to your cursor
                try? await Task.sleep(for: .milliseconds(120))
                await Typer.type(text, pressReturn: pressReturn)
                typedInDictation = true
                lastTyped = text
            case .continueTyping(let text):
                frontApp?.activate()
                close()
                // "…and press enter" / "send it" works mid-dictation too.
                if let t = Typer.finishText(text) {
                    let space = typedInDictation && !t.text.isEmpty ? " " : ""
                    await Typer.type(space + t.text, pressReturn: t.pressReturn)
                    if !t.text.isEmpty { typedInDictation = true; lastTyped = space + t.text }
                }
            case .startDictation:
                typedInDictation = false
                show(.system(symbol: "character.cursor.ibeam", title: "Dictating…", detail: "Say “stop typing” when done"), for: 1.6)
            case .repeatLast: break   // resolved in handle()
            case .file(let url, let reveal):
                Files.open(url, reveal: reveal)
                let name = url.lastPathComponent
                show(.media(InstalledApp(name: name, url: url), title: name, detail: reveal ? "Shown in Finder" : nil), for: 1.8)
            case .fileNotFound(let text):
                show(.system(symbol: "doc.questionmark", title: text, detail: nil), for: 1.8)
            case .click(let el):
                frontApp?.activate()
                Clicker.press(el)
                lastActionDisplay = Memory.display(at: CGPoint(x: el.frame.midX, y: el.frame.midY))
                show(.system(symbol: "cursorarrow.click", title: "Clicked", detail: el.label), for: 1.2)
            case .clickVisual(let app, let what):
                show(.system(symbol: "eye", title: "Looking…", detail: what), for: 15)
                app.activate()
                guard let router else { return }
                do {
                    if let p = try await router.locate(what, in: app) {
                        Clicker.click(at: p)
                        lastActionDisplay = Memory.display(at: p)
                        show(.system(symbol: "cursorarrow.click", title: "Clicked", detail: what), for: 1.2)
                    } else {
                        show(.system(symbol: "eye.slash", title: "Couldn't find it", detail: what), for: 1.8)
                    }
                } catch {
                    let denied = !CGPreflightScreenCaptureAccess()
                    if denied { CGRequestScreenCaptureAccess() }
                    show(.message(denied ? "Allow Screen Recording for Butterfly" : error.localizedDescription), for: 2.5)
                }
            case .window(let action, let app):
                let r = await WindowCommands.perform(action, app: app)
                lastActionDisplay = WindowCommands.display(of: app)
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: 1.4)
            case .timer(let action, let seconds):
                let timers = Timers.shared
                switch action {
                case .start:
                    guard let seconds else { show(.system(symbol: "timer", title: "How long?", detail: "Say “set a timer for 5 minutes”"), for: 2); break }
                    let t = timers.start(seconds)
                    show(.system(symbol: "timer", title: "Timer · \(Timers.spoken(t.total))", detail: "Ends at \(t.ends.formatted(date: .omitted, time: .shortened))"), for: 1.6)
                case .cancel:
                    let n = timers.cancelAll()
                    show(.system(symbol: "timer", title: n == 0 ? "No timer running" : "Timer cancelled", detail: nil), for: 1.4)
                case .status:
                    if let t = timers.next { show(.system(symbol: "timer", title: "\(Timers.spoken(t.remaining)) left", detail: "Ends at \(t.ends.formatted(date: .omitted, time: .shortened))"), for: 2) }
                    else { show(.system(symbol: "timer", title: "No timer running", detail: nil), for: 1.4) }
                }
            case .focus(let mode):
                if !Focus.isInstalled {
                    show(.system(symbol: "moon.fill", title: "One-time setup", detail: "Click “Add Shortcut”, then say it again"), for: 4)
                    await Focus.install()
                    break
                }
                let ok = await Focus.set(mode)
                let off = mode == "off"
                if ok { show(.badge(symbol: Focus.symbol(for: off ? nil : mode), text: off ? "Focus off" : mode, tint: off ? .white.opacity(0.6) : .indigo), for: 1.8) }
                else { show(.message("Couldn't change Focus"), for: 2) }
            case .bluetooth(let name, let address, let connect):
                show(.system(symbol: Bluetooth.symbol(for: name), title: (connect ? "Connecting " : "Disconnecting ") + name + "…", detail: nil), for: 10)
                let ok = await Bluetooth.shared.connect(address, on: connect)
                if !ok { show(.message("Couldn't \(connect ? "connect" : "disconnect") \(name)"), for: 2); break }
                let battery = connect ? await Bluetooth.battery(of: name) : nil
                show(.badge(symbol: Bluetooth.symbol(for: name), text: connect ? (battery.map { "\($0)%" } ?? "Connected") : "Disconnected",
                            tint: connect ? ((battery ?? 100) <= 20 ? .red : .green) : .white.opacity(0.6)), for: 2)
            case .joinWiFi(let name):
                show(.system(symbol: "wifi", title: "Joining \(name)…", detail: nil), for: 15)
                let ok = await WiFi.shared.join(name)
                show(ok ? .badge(symbol: "wifi", text: name, tint: .blue) : .message("Couldn't join \(name)"), for: 2)
            case .system(let action, let level):
                let r = await SystemController.perform(action, level: level)
                if let l = r.level { show(.level(l.kind, l.value), for: 1.6); break }
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: action == .screenshotFull ? 0.6 : 1.4)
            case .menu(let item, let app):
                let ok = await MenuReader.press(item, in: app)
                let icon = app.bundleURL.map { InstalledApp(name: app.localizedName ?? "", url: $0) }
                if ok {
                    show(.media(icon, title: item.title, detail: "✓ Done · " + item.path.dropLast().joined(separator: " → ") + " · say “undo” to revert"), for: 1.8)
                } else {
                    Undo.clear()
                    show(.media(icon, title: "Couldn't \(item.title.lowercased())", detail: "\(app.localizedName ?? "The app") didn't accept it"), for: 2.2)
                }
            case .open(let plan): launch(plan)
            case .media(let action, let preferred, let query):
                if action == .show {
                    if NowPlaying.shared.track != nil { show(.nowPlaying, for: 4) }
                    else { show(.media(nil, title: "Nothing is playing", detail: nil), for: 1.6) }
                    break
                }
                let result = await MediaController.perform(action, preferred: preferred, query: query)
                if !result.suggestions.isEmpty {
                    pendingPlaylists = (result.suggestions, Date())
                    let items = MediaController.artwork(for: result.suggestions).map { PlaylistItem(name: $0.0, artwork: $0.1) }
                    show(.playlists(title: result.title, items: items), for: 10)
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))   // let the now-playing stream catch up
                if NowPlaying.shared.track != nil { show(.nowPlaying, for: 2.6) }
                else { show(.media(result.player, title: result.title, detail: result.detail), for: 2.2) }
            case .settings(let page, let action):
                let r = SettingsController.perform(page, action: action)
                show(.media(SettingsController.settingsApp, title: r.title, detail: r.detail), for: 1.8)
            case .unsure(let app): show(.unsure(app))
            case .needAddress: show(.message("Say the full address, like “facebook dot com”"))
            case .notACommand: show(.message("Try “open Safari” or “open facebook.com”"))
            }
    }

    // MARK: Undo: remember how to reverse what's about to happen

    private func registerTypedUndo(_ text: String) {
        let app = frontApp
        Undo.register("typing") { _ = await KeyCommands.perform(.scratch, in: app, typed: text) }
    }

    private func prepareUndo(_ outcome: CommandRouter.Outcome) {
        let app = frontApp
        switch outcome {
        case .type(let text, _), .continueTyping(let text):
            registerTypedUndo(Typer.finishText(text)?.text ?? text)
        case .system(let action, _):
            switch action {
            case .volumeUp, .volumeDown, .volumeSet:
                let v = SystemController.Audio.volume
                Undo.register("volume back to \(v)%") { SystemController.Audio.setVolume(v) }
            case .mute: Undo.register("unmuted") { SystemController.Audio.setMuted(false) }
            case .unmute: Undo.register("muted") { SystemController.Audio.setMuted(true) }
            case .brightnessUp, .brightnessDown, .brightnessSet:
                if let b = SystemController.Brightness.value { Undo.register("brightness back to \(b)%") { SystemController.Brightness.set(b) } }
            default: Undo.clear()
            }
        case .window(let action, let target):
            let name = target.localizedName ?? "window"
            switch action {
            case .hideApp: Undo.register("showed \(name)") { target.unhide() }
            case .hideOthers:
                let visible = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden && $0 != target }
                Undo.register("showed other apps") { visible.forEach { $0.unhide() } }
            case .quitApp:
                if let url = target.bundleURL { Undo.register("reopened \(name)") { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init()) } }
            case .close: Undo.clear()
            default:
                if let snap = WindowCommands.snapshot(of: target) { Undo.register("\(name) put back") { await WindowCommands.restore(snap, app: target) } }
            }
        case .audioOutput, .audioOutputBluetooth:
            if let before = AudioOutput.current, let name = AudioOutput.devices.first(where: { $0.id == before })?.name {
                Undo.register("sound back to \(name)") { AudioOutput.set(before) }
            }
        case .focus:
            let before = Focus.active
            Undo.register(before.map { "\($0) Focus back on" } ?? "Focus off") { _ = await Focus.set(before ?? "off") }
        case .timer(.start, _):
            Undo.register("timer cancelled") { Timers.shared.cancelNewest() }
        case .bluetooth(let name, let address, let connect):
            Undo.register("\(name) \(connect ? "disconnected" : "reconnected")") { _ = await Bluetooth.shared.connect(address, on: !connect) }
        case .menu(let item, let menuApp):
            let closedTab = item.title.localizedCaseInsensitiveContains("close tab")
            Undo.register(closedTab ? "reopened tab" : item.title) {
                menuApp.activate()
                try? await Task.sleep(for: .milliseconds(80))
                Keys.press(closedTab ? 17 : 6, flags: closedTab ? [.maskCommand, .maskShift] : .maskCommand)
            }
        case .navigate(let nav):
            let reverse: KeyCommands.Nav? = switch nav {
            case .scrollDown: .scrollUp
            case .scrollUp: .scrollDown
            case .pageDown: .pageUp
            case .pageUp: .pageDown
            case .back: .forward
            case .forward: .back
            case .nextTab: .previousTab
            case .previousTab: .nextTab
            case .previousApp: .previousApp
            default: nil
            }
            if nav == .showDesktop {
                let visible = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden && $0.bundleIdentifier != "com.apple.finder" }
                Undo.register("windows back") { for a in visible { a.unhide() }; app?.activate() }
                break
            }
            if let reverse { Undo.register("went back") { _ = await KeyCommands.perform(reverse, in: app) } } else { Undo.clear() }
        case .edit(let e):
            if e == .scratch, let t = lastTyped {
                Undo.register("put the text back") { app?.activate(); await Typer.type(t, pressReturn: false) }
            } else if [.copy, .selectAll, .selectWord, .selectLine, .selectSentence, .end, .start].contains(e) {
                Undo.clear()
            } else {
                Undo.register("edit") { app?.activate(); try? await Task.sleep(for: .milliseconds(60)); Keys.press(6, flags: .maskCommand) }
            }
        default: Undo.clear()
        }
    }

    // MARK: Calendar

    private func calendar(_ action: Agenda.Action) async {
        let agenda = Agenda.shared
        guard await agenda.requestAccess() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return show(.message("Allow Calendar access for Butterfly"), for: 3)
        }
        switch action {
        case .next:
            // Timed events first; an all-day one only when nothing else is coming.
            guard let e = agenda.next ?? agenda.day(0).first else { return show(.system(symbol: "calendar", title: "Nothing coming up", detail: "Free all week"), for: 2) }
            let join = Agenda.meetingURL(e) != nil ? " · say “join”" : ""
            show(.system(symbol: "calendar", title: e.title ?? "Event", detail: Agenda.when(e) + join), for: 4)
        case .today, .tomorrow:
            let list = agenda.day(action == .today ? 0 : 1)
            let day = action == .today ? "today" : "tomorrow"
            guard !list.isEmpty else { return show(.system(symbol: "calendar", title: "Free \(day)", detail: action == .today ? "Nothing left on your calendar" : "No events"), for: 2) }
            let items = list.map { e in
                AgendaItem(time: e.isAllDay ? "All day" : e.startDate.formatted(date: .omitted, time: .shortened),
                           title: e.title ?? "Event", color: Color(nsColor: e.calendar?.color ?? .systemRed), allDay: e.isAllDay)
            }
            let allDay = items.filter(\.allDay), timed = items.filter { !$0.allDay }
            let shown = allDay.prefix(2) + timed.prefix(4)
            let date = Calendar.current.date(byAdding: .day, value: action == .today ? 0 : 1, to: Date())!
            show(.agenda(day: date, events: Array(shown), more: items.count - shown.count), for: 7)
        case .join:
            // The meeting happening now, or the next one starting within 15 minutes.
            let soon = agenda.events(from: Date(), to: Date().addingTimeInterval(15 * 60)).first { Agenda.meetingURL($0) != nil }
            guard let e = soon ?? agenda.next, let url = Agenda.meetingURL(e) else {
                return show(.system(symbol: "video.slash", title: "No meeting link", detail: agenda.next?.title), for: 2)
            }
            NSWorkspace.shared.open(url)
            show(.system(symbol: "video.fill", title: "Joining \(e.title ?? "meeting")", detail: url.host()), for: 2)
        }
    }

    // MARK: Second layer (Apple's on-device model plans and calls tools)

    private func agent(_ request: String) async {
        guard ScreenReader.available else { return show(.message("Turn on Apple Intelligence for this"), for: 3) }
        let app = frontApp
        Agent.runCommand = { [weak self] command in
            guard let self, let router = self.router, let o = try? await router.route(command) else { return "Couldn't do that." }
            await self.perform(o)
            return "Done: \(command)"
        }
        Agent.typeText = { [weak self] text in
            app?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            await Typer.type(text, pressReturn: false)
            self?.lastTyped = text
        }
        show(.system(symbol: "sparkles", title: "Working on it…", detail: request), for: 45)
        do {
            let done = try await Agent.run(request, app: app, client: Keychain.apiKey.map { TypeSafeClient(apiKey: $0) })
            let created = done.compactMap(\.created)
            if created.isEmpty { Undo.clear() }
            else {
                let what = done.count == 1 ? "removed “\(done[0].text.components(separatedBy: " · ").first ?? "it")”" : "removed \(created.count) items"
                Undo.register(what) { _ = Agent.remove(created) }
            }
            if done.count == 1, let d = done.first {
                show(.system(symbol: d.symbol, title: d.symbol == "sparkles" ? "Done" : Self.doneTitle(d.symbol), detail: d.text + (d.created != nil ? " · say “undo” to remove" : "")), for: 3.5)
            } else {
                show(.answer(title: "Done", text: done.map(\.text).joined(separator: "\n")), for: 4)
            }
        } catch {
            show(.message("Couldn't do it: \(error.localizedDescription)"), for: 3)
        }
    }

    private static func doneTitle(_ symbol: String) -> String {
        switch symbol {
        case "calendar.badge.plus": "Added to Calendar"
        case "checklist": "Added to Reminders"
        case "keyboard": "Typed"
        default: "Done"
        }
    }

    // MARK: Screen (Apple's on-device model)

    private func screen(_ action: ScreenReader.Action, request: String) async {
        if action == .stopReading {
            return show(.system(symbol: "speaker.slash.fill", title: ScreenReader.stop() ? "Stopped reading" : "Not reading", detail: nil), for: 1)
        }
        let app = frontApp
        show(.system(symbol: "text.viewfinder", title: "Reading the screen…", detail: app?.localizedName), for: 30)
        guard let (text, selected) = await ScreenReader.text(of: app) else {
            let denied = !CGPreflightScreenCaptureAccess()
            if denied { CGRequestScreenCaptureAccess() }
            return show(.message(denied ? "Allow Screen Recording for Butterfly" : "Nothing to read"), for: 2.5)
        }
        if action == .readAloud {
            ScreenReader.speak(text)
            return show(.system(symbol: "speaker.wave.2.fill", title: selected ? "Reading selection" : "Reading aloud", detail: "Say “stop reading”"), for: 2)
        }
        guard ScreenReader.available else { return show(.message("Turn on Apple Intelligence to use this"), for: 3) }
        show(.system(symbol: "sparkles", title: action == .reply ? "Writing a reply…" : "Thinking…", detail: selected ? "Selected text" : app?.localizedName), for: 30)
        do {
            let answer = try await ScreenReader.answer(action, request: request, text: text, app: app?.localizedName)
            if action == .reply {
                app?.activate()
                close()
                try? await Task.sleep(for: .milliseconds(150))
                await Typer.type(answer, pressReturn: false)
                lastTyped = answer
                registerTypedUndo(answer)
                return
            }
            let title = switch action { case .summarize: "Summary"; case .explain: "What it says"; default: "Answer" }
            let seconds = min(20, max(5, Double(answer.split(separator: " ").count) / 3))
            show(.answer(title: title, text: answer), for: seconds)
        } catch {
            show(.message("Couldn't read it: \(error.localizedDescription)"), for: 3)
        }
    }

    private func openSite(_ url: URL) {
        launch(.init(targets: [.site(url)], windowsEach: 1, layout: .none))
    }

    private func launch(_ app: InstalledApp) {
        launch(.init(targets: [.app(app)], windowsEach: 1, layout: .none))
    }

    private func launch(_ plan: WindowManager.Plan) {
        show(.opened(plan.targets, detail: Self.describe(plan)), for: 2.2)
        Task { await WindowManager.run(plan) }
    }

    private static func describe(_ plan: WindowManager.Plan) -> String? {
        let multiWindow = plan.targets.count == 1 && plan.apps.count == 1 && plan.windowsEach > 1
        var parts: [String] = []
        if multiWindow { parts.append("\(plan.windowsEach) windows") }
        switch plan.layout {
        case .sideBySide: parts.append("side by side")
        case .stacked: parts.append("stacked")
        case .maximize: parts.append("maximized")
        case .none: if multiWindow { parts.append("side by side") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func show(_ phase: Phase, for seconds: Double = 1.6) {
        self.phase = phase
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            close()
        }
    }

    /// Swipe up (or sideways) on the notch: put away whatever it's showing. Listening isn't interrupted.
    func swipeAway() {
        switch phase {
        case .idle, .listening, .thinking: return
        default:
            dismissTask?.cancel()
            close()
        }
    }

    private func close() {
        // Locked: results fade back to listening instead of closing.
        if isLocked || (accepting && working) {
            phase = .listening
            transcript = ""
            return
        }
        phase = .idle
        transcript = ""
    }
}
