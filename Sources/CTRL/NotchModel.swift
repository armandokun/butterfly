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
        case recap(title: String, range: String, items: [RecapItem])   // expanded, "what did I do" timeline
        case playlists(title: String, items: [PlaylistItem])    // expanded: artwork tiles to pick from
        case meetingPrompt(app: String)                         // expanded: "Record this meeting?" with buttons
        case recordingCard                                      // expanded on hover while recording: time + Stop
        case transcriptReady(title: String, file: URL)          // expanded: "Transcript ready" + Open
        case stopPrompt(app: String)                            // expanded: "Call ended?" · Keep / Stop
    }
    struct Recording: Equatable { let app: String; let since: Date }
    /// A meeting is being recorded: the notch shows a red dot + time, hover to stop.
    @Published var recording: Recording? {
        didSet {
            updateInteractive()
            // Say "recording" for a few seconds, then get out of the way: hover the notch to see it again.
            badgeTask?.cancel()
            if let r = recording, oldValue?.since != r.since {
                recordingBadge = true
                badgeTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { recordingBadge = false } }
            } else if recording == nil { recordingBadge = false }
        }
    }
    @Published private(set) var recordingBadge = false
    private var badgeTask: Task<Void, Never>?
    /// Gemini is writing the transcript for this meeting: the notch shows "Transcribing" until it's done.
    @Published var transcribing: String?
    struct AgendaItem: Equatable { let time: String; let title: String; let color: Color; let allDay: Bool }
    /// One activity in a "what did I do" recap: when, in which app, what.
    struct RecapItem: Equatable { let time: String; let app: String; let text: String }
    struct PlaylistItem: Equatable { let name: String; let artwork: NSImage? }

    /// Background events (volume keys, battery, Wi-Fi…): only when the notch isn't busy with you.
    func ambient(_ p: Phase, for seconds: Double = 1.6) {
        if case .meetingPrompt = phase { return }   // waiting for your answer
        if case .stopPrompt = phase { return }
        switch phase {
        case .idle, .level: show(p, for: seconds)
        default:
            if case .level = p { return }
            guard !isLocked, phase != .listening, phase != .thinking else { return }
            show(p, for: seconds)
        }
    }

    /// Must-see events (meeting recording): shown over anything except you talking to Butterfly,
    /// in which case it waits (up to 30 s) until you're done.
    func notify(_ p: Phase, for seconds: Double, waited: Int = 0) {
        if phase == .listening || phase == .thinking, waited < 30 {
            Task { try? await Task.sleep(for: .seconds(1)); notify(p, for: seconds, waited: waited + 1) }
            return
        }
        show(p, for: seconds)
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
        Meetings.shared.onEvent = { [weak self] e in
            // Shown even over other results (not ambient): recording must never start or stop unseen.
            switch e {
            case .ask(let app): self?.notify(.meetingPrompt(app: app), for: 30)
            case .unasked: if case .meetingPrompt = self?.phase { self?.close() }
            case .askStop(let app): self?.notify(.stopPrompt(app: app), for: 118)
            case .unaskStop: if case .stopPrompt = self?.phase { self?.close() }
            case .started(let app): self?.recording = Recording(app: app, since: Date())
            case .stopped(let app): self?.recording = nil; self?.transcribing = app
            case .discarded: self?.recording = nil; self?.notify(.badge(symbol: "xmark.circle", text: "Not saved", tint: .gray), for: 3)
            case .saved(let title, let folder): self?.transcribing = nil; self?.notify(.transcriptReady(title: title, file: folder.appendingPathComponent("transcript.md")), for: 12)
            case .failed(let why):
                self?.transcribing = nil
                if !Meetings.shared.isRecording { self?.recording = nil }
                self?.notify(.system(symbol: "exclamationmark.triangle", title: "Meeting notes", detail: why), for: 8)
            }
        }
        Meetings.shared.start()
        Meetings.nameUntitledFolders()
        // Brightness keys: same, macOS shows its own HUD.
        KeyCommands.startTracking()
        Clipboard.shared.start()
        Timers.shared.restore()
    }
    private var lastTyped: String?
    private var peakLevel: CGFloat = 0   // loudest sound this press: 0 = the mic heard nothing

    @Published var phase: Phase = .idle {
        didSet {
            updateInteractive()
            // Timed out or replaced without an answer: no recording.
            if case .meetingPrompt = oldValue, !isPrompt { Meetings.shared.answer(record: false) }
        }
    }
    private var isPrompt: Bool {
        switch phase { case .meetingPrompt, .stopPrompt: true; default: false }
    }
    private var isReady: Bool { if case .transcriptReady = phase { return true }; return false }
    /// Card with buttons on screen (prompt, recording card, transcript ready).
    var showsButtons: Bool { isPrompt || isReady || phase == .recordingCard }
    private var interactive = false
    /// The panel tracks the mouse (clicks + hover) while buttons are up or a meeting records.
    var onInteractive: ((Bool) -> Void)?
    private func updateInteractive() {
        let wants = isPrompt || isReady || recording != nil
        if wants != interactive { interactive = wants; onInteractive?(wants) }
    }

    func answerStop(_ stopNow: Bool) {
        Meetings.shared.answerStop(stopNow)
        dismissTask?.cancel()
        close()
    }

    func openTranscript(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])   // the meeting folder in Finder, transcript selected
        dismissTask?.cancel()
        close()
    }

    /// Mouse over the notch while recording: open the card; leaving it closes it.
    func hover(_ over: Bool) {
        guard recording != nil else { return }
        if case .stopPrompt = phase { return }
        if over, phase == .idle { dismissTask?.cancel(); phase = .recordingCard }
        else if !over, phase == .recordingCard { close() }
    }

    /// Debug (CTRL_RECORDING_STATES=1): every meeting-notes state, 3 s each, for screenshots.
    func recordingStatesDemo() {
        let steps: [() -> Void] = [
            { self.phase = .meetingPrompt(app: "Dia call") },
            { self.phase = .idle; self.recording = Recording(app: "Dia call", since: Date().addingTimeInterval(-270)) },
            { self.phase = .recordingCard },
            { self.phase = .stopPrompt(app: "Dia call") },
            { self.recording = nil; self.phase = .idle; self.transcribing = "Dia call" },
            { self.transcribing = nil; self.phase = .transcriptReady(title: "Dia call", file: Meetings.root) },
            { self.phase = .badge(symbol: "xmark.circle", text: "Not saved", tint: .gray) },
            { self.phase = .system(symbol: "exclamationmark.triangle", title: "Meeting notes", detail: "Recorded, but no Gemini key to transcribe") },
            { self.phase = .idle },
        ]
        for (i, s) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) { self.dismissTask?.cancel(); s() }
        }
    }

    func stopRecording() {
        Meetings.shared.stop(byHand: true)
        close()
    }

    /// Notch prompt buttons.
    func answerMeeting(_ record: Bool) {
        Meetings.log("button: \(record ? "Record" : "Not now")")
        Meetings.shared.answer(record: record)
        dismissTask?.cancel()
        close()
    }
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
    /// A planned action waiting for "yes" (destructive steps ask first).
    private var pendingPlan: (plan: Planner.Plan, request: String, at: Date)?
    /// The last thing the planner (or a learned skill) did — "no, not that, do this" refers to it.
    private var lastPlan: (previous: Planner.Previous, at: Date)?
    /// What the planner did in the last 3 minutes, if anything: the router offers "correction" only then.
    private var recentPlan: Planner.Previous? {
        guard let last = lastPlan, Date().timeIntervalSince(last.at) < 180 else { return nil }
        return last.previous
    }

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
        case .recap(_, _, let items): did = "recapped: " + items.map { "\($0.time) \($0.app) — \($0.text)" }.joined(separator: "; ")
        case .playlists(_, let items): did = "offered playlists: " + items.map(\.name).joined(separator: ", ")
        case .badge(_, let text, _): did = text
            if case .focus(let m) = outcome { did = m == "off" ? "Focus turned off" : "\(m) Focus turned on" }
            if case .bluetooth(let n, _, let c) = outcome { did = "\(n) \(c ? "connected" : "disconnected") (\(text))" }
            if case .joinWiFi(let n) = outcome { did = "joined Wi-Fi \(n)" }
        default:
            switch outcome {
            case .type(let t, _), .continueTyping(let t): did = "typed “\(t.prefix(60))”"
            case .notACommand, .unsure, .aside, .memoryQuestion, .correction: return
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

    /// `CTRL_MARKTEST="what is this"`: action mode with a synthetic circle drawn mid-screen, then that sentence.
    func markTest(_ sentence: String) {
        isLocked = true
        accepting = true
        phase = .listening
        Task {
            try? await Task.sleep(for: .seconds(1))
            let f = NSScreen.screens[0].frame
            let c = CGPoint(x: f.midX, y: f.midY)   // CG coords, top-left origin (main screen: same as AppKit except y)
            MarkOverlay.shared.showPassive()
            for i in 0...40 {
                let a = Double(i) / 40 * 2 * .pi
                MarkOverlay.shared.addPoint(global: CGPoint(x: c.x + 120 * cos(a), y: c.y + 80 * sin(a)), newStroke: i == 0)
            }
            MarkOverlay.shared.endStroke()
            print("marks:", MarkOverlay.shared.hasMarks)
            try? await Task.sleep(for: .seconds(1))
            enqueue(sentence)
        }
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

    private var requestTask: Task<Void, Never>?
    private var requestGen = 0

    func begin(dictation: Bool = false) {
        cancelRequestIfRunning()   // (normally already done in arm)
        if Date().timeIntervalSince(Self.armedAt) > 0.5 { Self.t0 = Date() } else { Self.t0 = Self.armedAt }
        firstLevel = true
        defer { Self.lap("begin() returned") }
        dictationOnly = dictation
        dismissTask?.cancel()
        moveToActiveScreen()
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        if !dictation { MarkGesture.shared.enabled = true }   // while you hold ⌥ you can press-hold-drag to mark something
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
        if !dictation { MarkGesture.shared.enabled = true }   // action mode: press-hold-drag marks things to talk about
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        dictating = false
        dictationOnly = false
        MarkGesture.shared.enabled = false
        if MarkOverlay.shared.hasMarks { MarkOverlay.shared.cancel() }
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
                    if (MarkOverlay.shared.hasMarks || MarkGesture.shared.isMarking), await handleMarked(next) { continue }
                    // "Open Notes, and once you're there create a new note": one sentence, several commands, in order.
                    let steps = dictating ? [next] : await StepSplitter.split(next)
                    for (i, step) in steps.enumerated() {
                        if i > 0 {
                            try? await Task.sleep(for: .milliseconds(600))
                            transcript = step; phase = .thinking
                            readFrontApp()
                        }
                        if steps.count > 1 { DecisionTrace.shared.add(.rule, "step \(i + 1)/\(steps.count)", step) }
                        await handle(step)
                    }
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
        requestGen += 1
        let gen = requestGen
        requestTask = Task {
            defer { if requestGen == gen { requestTask = nil } }
            await startTask?.value
            let text = await recorder.stop()
            lastFinalizeMs = Int(Date().timeIntervalSince(released) * 1000)
            let silent = peakLevel < 0.02
            peakLevel = 0
            if text.isEmpty, MarkOverlay.shared.hasMarks, let marks = await MarkOverlay.shared.hide() {
                MarkGesture.shared.enabled = false   // circled something, said nothing: "what's this"
                transcript = "What is this?"
                return await explainMarks(marks, request: "What is this?", app: frontApp)
            }
            guard !text.isEmpty else {
                MarkGesture.shared.enabled = false
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
            if MarkOverlay.shared.hasMarks || MarkGesture.shared.isMarking {
                let done = await handleMarked(text)
                MarkGesture.shared.enabled = false
                if done { return }
                MarkOverlay.shared.cancel()   // an ordinary command; no next sentence coming for the marks
            }
            MarkGesture.shared.enabled = false
            let steps = await StepSplitter.split(text)
            for (i, step) in steps.enumerated() {
                if i > 0 { try? await Task.sleep(for: .milliseconds(600)); transcript = step; phase = .thinking; readFrontApp() }
                if steps.count > 1 { DecisionTrace.shared.add(.rule, "step \(i + 1)/\(steps.count)", step) }
                await handle(step)
            }
        }
    }

    func cancel() {
        guard !isLocked else { return }
        dictationOnly = false
        MarkGesture.shared.enabled = false
        if MarkOverlay.shared.hasMarks { MarkOverlay.shared.cancel() }
        Task {
            await startTask?.value
            await recorder.cancel()
            Ducker.restore()
            close()
        }
    }

    // MARK: Marks in action mode (press, hold still, drag — see MarkGesture)

    /// Said with marks on the screen. Decides what you meant: a question about the marked thing, a job for Cursor
    /// (with the annotated screenshot pasted into its chat), or an ordinary command that just happened to follow a mark
    /// (then the marks stay for your next sentence). Returns false when it should be handled as a normal command.
    private func handleMarked(_ text: String) async -> Bool {
        // Mid-stroke: let you finish drawing before deciding.
        for _ in 0..<30 where MarkGesture.shared.isMarking { try? await Task.sleep(for: .milliseconds(100)) }
        guard MarkOverlay.shared.hasMarks else { return false }
        let app = frontApp
        let cursor = NSRunningApplication.runningApplications(withBundleIdentifier: CursorControl.bundleID).first
        var intent = "ask"
        if let key = Keychain.apiKey {
            let client = TypeSafeClient(apiKey: key)
            var options = [
                "ask": "wants information about the marked thing: what is this, what does it mean, when did this arrive, who sent it, is this right, explain, translate, summarize",
                "command": "an ordinary Mac command that has nothing to do with the marked thing (open an app, type text, volume, click something they named, next tab…)"]
            if cursor != nil {
                options["cursor"] = "wants their AI coding agent (Cursor) to change, fix, build, move, restyle, add or remove the marked thing, or asks why the marked UI/code behaves like that ('can you change this', 'make this bigger', 'why is this broken', 'remove this')"
            }
            if let r = try? await client.systemOne(
                state: ["spoken": text, "front_app": app?.localizedName ?? "?", "cursor_running": cursor == nil ? "no" : "yes", "front_is_cursor": app?.bundleIdentifier == CursorControl.bundleID ? "yes" : "no"],
                questions: ["intent": .choice("The user drew a mark on the screen, then said this. What do they want?", options: options)]),
               let a = r.choice("intent"), a.confidence > 0.35 { intent = a.choice }
        }
        DecisionTrace.shared.add(.rule, "marks + “\(text)” → \(intent)", app?.localizedName)
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { print("marks + “\(text)” → \(intent) (front: \(app?.localizedName ?? "?"))") }
        if intent == "command" || (intent == "cursor" && cursor == nil) { return false }
        guard let marks = await MarkOverlay.shared.hide() else { return false }
        if intent == "cursor", let cursor { await sendToCursor(marks, text: text, cursor: cursor, from: app) }
        else { await explainMarks(marks, request: text, app: app) }
        return true
    }

    /// Pastes the annotated screenshot into Cursor's chat box, types what you said, sends it.
    private func sendToCursor(_ marks: MarkOverlay.Marks, text: String, cursor: NSRunningApplication, from app: NSRunningApplication?) async {
        guard let img = marks.images.first,
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        show(.system(symbol: "paperplane", title: "Sending to Cursor…", detail: nil), for: 10)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        let snap = CursorControl.snapshot(of: cursor)
        cursor.activate()
        try? await Task.sleep(for: .milliseconds(150))
        if let c = snap?.composer { CursorControl.focus(c) } else { Keys.press(37, flags: .maskCommand) }   // ⌘L
        try? await Task.sleep(for: .milliseconds(150))
        Keys.press(9, flags: .maskCommand)   // ⌘V: the screenshot
        try? await Task.sleep(for: .milliseconds(500))
        let where_ = app.map { $0.bundleIdentifier == CursorControl.bundleID ? "" : " (seen in \($0.localizedName ?? "another app"))" } ?? ""
        await Typer.type("\(Typer.clean(text)) — I marked it with a glowing white line on the screenshot\(where_).", pressReturn: true)
        show(.system(symbol: "paperplane", title: "Asked Cursor", detail: "“\(text.prefix(50))”"), for: 2.5)
        Memory.record(said: text, did: "sent a marked screenshot to Cursor", app: app?.localizedName)
    }

    private func explainMarks(_ marks: MarkOverlay.Marks, request: String, app: NSRunningApplication?) async {
        show(.system(symbol: "sparkles", title: "Looking…", detail: app?.localizedName), for: 30)
        do {
            let answer = try await ScreenReader.explain(marks.images, request: request, app: app?.localizedName)
            let seconds = min(20, max(6, Double(answer.split(separator: " ").count) / 3))
            show(.answer(title: request == "What is this?" ? "This is" : "Answer", text: answer), for: seconds)
            if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { print("answer:", answer) }
            Memory.record(said: request, did: "explained a marked part of the screen", app: app?.localizedName)
        } catch {
            if Task.isCancelled { return }
            if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { print("explain error:", error) }
            show(.message(error.localizedDescription), for: 3)
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
        cancelRequestIfRunning()   // ⌥ again while a request runs: that one's dropped, the new one wins (tap = just cancel)
        Self.armedAt = Date()
        recorder.arm()
        TypeSafeClient.preconnect()
    }

    /// ⌥ (either side) pressed while a request is running: stop it. Any time from release until the result shows
    /// (finalizing speech, thinking, "Looking…", typing into Cursor). Returns true when something was stopped.
    @discardableResult
    private func cancelRequestIfRunning() -> Bool {
        guard let requestTask, !requestTask.isCancelled, !isLocked else { return false }
        requestTask.cancel()
        self.requestTask = nil
        MarkGesture.shared.enabled = false
        if MarkOverlay.shared.hasMarks { MarkOverlay.shared.cancel() }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        DecisionTrace.shared.add(.outcome, "cancelled by ⌥ tap", nil)
        show(.system(symbol: "xmark", title: "Cancelled", detail: nil), for: 0.9)
        return true
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
        Task { for l in lines { readFrontApp(); await handle(l); try? await Task.sleep(for: .seconds(2.5)) } }
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
        // A plan asked "yes?" — this is the answer.
        if let p = pendingPlan, Date().timeIntervalSince(p.at) < 40 {
            pendingPlan = nil
            if text.lowercased().range(of: #"\b(yes|yeah|yep|sure|do it|go ahead|confirm|ok|okay)\b"#, options: .regularExpression) != nil {
                trace.add(.rule, "confirmed", p.plan.confirm)
                return await execute(p.plan, request: p.request, learn: true)
            }
            trace.add(.rule, "not confirmed", "plan dropped")
        }
        // "learn this app" / "learn Slack": read the app's menus, settings and scripting now (also happens on first need).
        if !dictating, let m = text.lowercased().firstMatch(of: #/^\W*(?:please\s+)?(?:re)?learn\s+(this app|the app|(?:the\s+)?[\w .]+?)\W*$/#) {
            let who = String(m.1)
            let target = who.hasSuffix("app") && who.hasPrefix("th") ? frontApp
                : AppCatalog.shared.localMatch(who).flatMap { a in NSWorkspace.shared.runningApplications.first { $0.bundleURL == a.url } } ?? frontApp
            if let target {
                let name = target.localizedName ?? "app"
                trace.add(.rule, "learn app", name)
                show(.system(symbol: "brain", title: "Learning \(name)…", detail: "reading its menus and settings"), for: 30)
                let m = await AppMap.shared.build(for: target, crawlSettings: true)
                return show(.system(symbol: "brain", title: "Learned \(name)", detail: "\(m?.entries.count ?? 0) things it can do" + (m?.settingsCrawled == true ? "" : " · no settings window found")), for: 3)
            }
        }
        // "What did I do in the last five minutes?": a named period is language-light proof it's about screen memory.
        if !dictating, Keychain.geminiKey != nil, let w = ScreenMemory.window(in: text), w.label.hasPrefix("the last") || w.label.hasPrefix("around"),
           !ScreenMemory.shared.timeline(from: w.from, to: w.to).isEmpty {
            trace.add(.rule, "memory question", "period: \(w.label)")
            return await plan(text, trace: trace)
        }
        // Learned skill: the same kind of request as before fires its saved steps — no model, no network.
        if !dictating, let (skill, values) = SkillStore.shared.match(text) {
            trace.add(.rule, "learned skill", "“\(skill.pattern)” · \(values.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            trace.add(.outcome, "skill: \(skill.name)", nil, ms: 0)
            SkillStore.shared.used(skill, phrase: text)
            let plan = Planner.harden(Planner.Plan(steps: SkillStore.fill(skill.steps, with: values), summary: skill.name), request: text)
            if let c = plan.confirm {
                pendingPlan = (plan, text, Date())
                return show(.answer(title: "Say “yes” to continue", text: c), for: 40)
            }
            return await execute(plan, request: text, learn: false, skillPattern: skill.pattern)
        }
        do {
            let router = CommandRouter(client: TypeSafeClient(apiKey: key))
            let previous = Date().timeIntervalSince(lastCommandAt) < 120 ? lastCommand : nil
            // A sentence the router probably won't know (long, or naming nothing it knows): start the planner now, so when
            // the router says "not a command" the answer is already on its way. Cancelled the moment the router wins.
            var speculative: Task<Planner.Plan, Error>?
            if !dictating, !inPlan, let gKey = Keychain.geminiKey, likelyNeedsPlanner(text), frontApp.map({ AppMap.shared.isCurrent(for: $0) }) ?? true {
                let (app, menu, els) = (frontApp, menuSnapshot, clickables)
                speculative = Task { try await Planner.plan(text, app: app, menu: menu, elements: els, key: gKey) }
                trace.add(.rule, "planner started in parallel", "\(text.split(separator: " ").count) words, nothing known named")
            }
            defer { speculative?.cancel() }
            let routed = Date()
            var outcome = try await router.route(text, menu: menuSnapshot, front: frontApp, elements: clickables,
                                                 previous: previous, dictating: dictating, cursor: cursorSnapshot, conversational: isLocked, recentPlan: recentPlan?.request)
            if case .aside = outcome {
                // Said to yourself or to someone else: leave it, keep listening (and keep dictating if you were).
                trace.add(.outcome, "aside — ignored", nil, ms: Int(Date().timeIntervalSince(routed) * 1000))
                phase = .listening; transcript = ""
                return
            }
            if case .repeatLast = outcome, let previous {
                trace.add(.rule, "repeat", "re-running “\(previous)” in the current context")
                // Same words, fresh context: "close this tab" → "this one too" closes the new current tab.
                outcome = try await router.route(previous, menu: menuSnapshot, front: frontApp, elements: clickables)
            } else {
                switch outcome {
                case .notACommand, .unsure, .needAddress, .fileNotFound, .continueTyping, .startDictation, .repeatLast, .memoryQuestion, .correction: break
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
            // Nothing built-in understood it: let the planner work it out from the screen (and learn it for next time).
            if !dictating, !inPlan, Keychain.geminiKey != nil {
                switch outcome {
                case .notACommand, .unsure, .memoryQuestion, .agent: return await plan(text, trace: trace, speculative: speculative)
                case .correction:
                    trace.add(.rule, "correction", "follows “\(recentPlan?.request ?? "")”")
                    return await plan(text, trace: trace, previous: recentPlan)
                default: break
                }
            }
            lastActionDisplay = nil
            let ran = Date()
            await perform(outcome)
            trace.add(.result, Self.describe(phase), nil, ms: Int(Date().timeIntervalSince(ran) * 1000))
            remember(text, outcome)
        } catch {
            if Task.isCancelled { return }   // you tapped ⌥ to stop it
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

    /// Click, then look: before/after screenshots tell whether it did what was asked.
    /// A miss gets one corrected retry; still wrong → say so instead of claiming "Clicked".
    private func clickChecked(at p: CGPoint, what: String, _ click: () -> Void) async {
        let display = Memory.display(at: p)
        lastActionDisplay = display
        let spoken = lastCommand ?? what
        func shot() async -> Clicker.Shot? {
            guard let display, CGPreflightScreenCaptureAccess() else { return nil }
            return try? await Clicker.screenshot(region: CGDisplayBounds(display), display: display)
        }
        let before = await shot()
        click()
        guard let router, let before else { show(.system(symbol: "cursorarrow.click", title: "Clicked", detail: what), for: 1.2); return }
        show(.system(symbol: "eye", title: "Clicked · checking…", detail: what), for: 6)
        try? await Task.sleep(for: .milliseconds(700))
        guard let after = await shot(), let check = try? await router.verifyClick(spoken, clicked: what, before: before, after: after) else {
            show(.system(symbol: "cursorarrow.click", title: "Clicked", detail: what), for: 1.2); return
        }
        DecisionTrace.shared.add(.rule, "click check", String(format: "done %.2f", check.done))
        if check.done >= 0.5 { show(.system(symbol: "checkmark.circle", title: "Done", detail: what), for: 1.2); return }
        // Retry spot: the zoomed locator (precise), told the first spot missed; never the same spot again.
        let hint = "\(spoken) (a click at \(Int(p.x)),\(Int(p.y)) on screen missed it)"
        let located = frontApp.flatMap { app in Task { try? await router.locate(hint, in: app) } }
        let retry = (await located?.value ?? nil).flatMap { hypot($0.x - p.x, $0.y - p.y) > 12 ? $0 : nil }
        guard let retry else { show(.system(symbol: "exclamationmark.triangle", title: "Clicked, but it didn't seem to work", detail: what), for: 2.2); return }
        show(.system(symbol: "arrow.uturn.right", title: "Missed · retrying", detail: what), for: 6)
        Clicker.click(at: retry)
        lastActionDisplay = Memory.display(at: retry)
        try? await Task.sleep(for: .milliseconds(700))
        if let again = await shot(), let c2 = try? await router.verifyClick(spoken, clicked: what, before: before, after: again), c2.done < 0.5 {
            show(.system(symbol: "exclamationmark.triangle", title: "Couldn't hit it", detail: what), for: 2.2)
        } else {
            show(.system(symbol: "checkmark.circle", title: "Done", detail: what), for: 1.2)
        }
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
            case .agent: show(.message("Add a Gemini key in Settings for this"), for: 2.5)   // the planner does these; handled in handle() when there is a key
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
                await clickChecked(at: CGPoint(x: el.frame.midX, y: el.frame.midY), what: el.label) { Clicker.press(el) }
            case .clickVisual(let app, let what):
                show(.system(symbol: "eye", title: "Looking…", detail: what), for: 15)
                app.activate()
                guard let router else { return }
                do {
                    if let p = try await router.locate(what, in: app) {
                        await clickChecked(at: p, what: what) { Clicker.click(at: p) }
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
            case .memoryQuestion, .correction: show(.message("Add a Gemini key in Settings for this"), for: 2.5)   // handled in handle() when there is one
            case .aside: close()
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

    // MARK: Third layer (Gemini plans from the screen; the result is learned as a skill)

    /// True while a plan's "command" steps run through the router, so a step that fails can't call the planner again.
    private var inPlan = false

    /// Worth starting the planner before the router answers? Long sentences, or ones naming no app, menu item or
    /// control the router could match, almost always end up there anyway.
    private func likelyNeedsPlanner(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() }
        if words.count > 6 { return true }
        let said = Set(words.filter { $0.count >= 3 })
        func named(_ s: String) -> Bool { s.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { $0.count >= 3 && said.contains(String($0)) } }
        if AppCatalog.shared.apps.contains(where: { named($0.name) }) { return false }
        if (menuSnapshot?.items ?? []).contains(where: { named($0.title) }) { return false }
        if clickables.contains(where: { named($0.label) }) { return false }
        return true
    }

    private func plan(_ request: String, trace: DecisionTrace, previous: Planner.Previous? = nil, speculative: Task<Planner.Plan, Error>? = nil) async {
        guard let key = Keychain.geminiKey else { return }
        // A learned skill said differently ("look up X on LinkedIn" vs "search X on linkedin"): cheaper than planning again.
        if previous == nil, !SkillStore.shared.skills.isEmpty, let apiKey = Keychain.apiKey,
           let (skill, confidence) = try? await SkillStore.shared.semanticMatch(request, client: TypeSafeClient(apiKey: apiKey)), confidence >= 0.6 {
            let slots = SkillStore.slots(in: skill.pattern)
            if let values = try? await Planner.fillSlots(slots, pattern: skill.pattern, request: request, key: key) {
                speculative?.cancel()
                trace.add(.rule, "learned skill (by meaning)", "“\(skill.pattern)” \(String(format: "%.2f", confidence)) · \(values.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
                SkillStore.shared.used(skill, phrase: request)
                let plan = Planner.harden(Planner.Plan(steps: SkillStore.fill(skill.steps, with: values), summary: skill.name), request: request)
                if let c = plan.confirm { pendingPlan = (plan, request, Date()); return show(.answer(title: "Say “yes” to continue", text: c), for: 40) }
                return await execute(plan, request: request, learn: false, skillPattern: skill.pattern)
            }
        }
        // First planner request about an app: learn what it can do (menus, every Settings pane, scripting) and keep it.
        if let app = frontApp, !AppMap.shared.isCurrent(for: app) {
            let name = app.localizedName ?? "this app"
            show(.system(symbol: "brain", title: "Learning \(name)…", detail: "reading its menus and settings once"), for: 30)
            let t = Date()
            let m = await AppMap.shared.build(for: app, crawlSettings: true) { [weak self] p in self?.show(.system(symbol: "brain", title: "Learning \(name)…", detail: p), for: 30) }
            trace.add(.context, "learned \(name)", "\(m?.entries.count ?? 0) entries · settings \(m?.settingsCrawled == true ? "read" : "not found")", ms: Int(Date().timeIntervalSince(t) * 1000))
            readFrontApp()
        }
        show(.system(symbol: "brain", title: previous == nil ? "Working it out…" : "Adjusting…", detail: request), for: 45)
        let started = Date()
        do {
            let plan: Planner.Plan
            if let speculative, previous == nil, !speculative.isCancelled {
                plan = try await speculative.value
                trace.add(.rule, "used the parallel plan", nil)
            } else {
                speculative?.cancel()
                plan = try await Planner.plan(request, app: frontApp, menu: menuSnapshot, elements: clickables, previous: previous, key: key)
            }
            trace.add(.outcome, "planned \(plan.steps.count) steps", plan.steps.map(Planner.describe).joined(separator: " → ").nilIfEmpty, ms: Int(Date().timeIntervalSince(started) * 1000))
            // The request this plan is really about: a correction keeps the original wording, so the fixed skill replaces the wrong one.
            let about = previous?.request ?? request
            if let r = plan.recap {
                let items = r.items.map { RecapItem(time: $0.time, app: $0.app, text: $0.text) }
                lastPlan = (Planner.Previous(request: about, steps: [], result: "recapped \(items.count) activities", skillPattern: nil), Date())
                Memory.record(said: request, did: "recap: " + items.map { "\($0.time) \($0.app) — \($0.text)" }.joined(separator: "; "))
                return show(.recap(title: r.title, range: r.range, items: items), for: 4 + Double(items.count) * 1.5)
            }
            if plan.steps.isEmpty, let s = plan.skill {
                // Taught, not asked ("when I say X, do Y"): keep it, nothing to run.
                if let old = previous?.skillPattern, old != s.pattern, let o = SkillStore.shared.skills.first(where: { $0.pattern == old }) { SkillStore.shared.forget(o) }
                SkillStore.shared.learn(name: s.name, pattern: s.pattern, steps: s.steps, example: about)
                lastPlan = (Planner.Previous(request: about, steps: s.steps, result: "learned, not run", skillPattern: s.pattern), Date())
                return show(.system(symbol: "brain", title: "Learned", detail: "“\(s.pattern)” → \(s.steps.map(Planner.describe).joined(separator: " → "))"), for: 4)
            }
            if let q = plan.clarify, plan.steps.isEmpty {
                lastPlan = (Planner.Previous(request: about, steps: [], result: "answered: \(q.prefix(160))", skillPattern: previous?.skillPattern), Date())
                return show(.answer(title: "Butterfly", text: q), for: 6)
            }
            if plan.steps.isEmpty { return show(.message("Couldn't work that out"), for: 2.5) }
            if let c = plan.confirm {
                pendingPlan = (plan, about, Date())
                return show(.answer(title: "Say “yes” to continue", text: c), for: 40)
            }
            await execute(plan, request: about, learn: true, replacing: previous?.skillPattern)
        } catch {
            if Task.isCancelled { return }
            trace.add(.error, error.localizedDescription, nil)
            show(.message(error.localizedDescription), for: 3)
        }
    }

    private func execute(_ plan: Planner.Plan, request: String, learn: Bool, skillPattern: String? = nil, replacing: String? = nil) async {
        let app = frontApp
        Planner.runCommand = { [weak self] command in
            guard let self, let router = self.router else { return "failed: no router" }
            self.inPlan = true; defer { self.inPlan = false }
            self.readFrontApp()   // a previous step may have opened another app
            let front = self.frontApp ?? app
            guard let o = try? await router.route(command, menu: self.menuSnapshot, front: front, elements: self.clickables) else { return "failed: route" }
            switch o {
            case .notACommand, .unsure: return "failed: not understood"
            default: await self.perform(o); return "ok"
            }
        }
        Planner.openURL = { [weak self] url in self?.openSite(url) }
        Planner.readToggle = { label in Clicker.toggleState(label: label, in: NSWorkspace.shared.frontmostApplication ?? app) }
        Planner.progress = { [weak self] d in self?.show(.media(nil, title: plan.summary, detail: d), for: 30) }
        let r = await Planner.run(plan.steps, app: app, request: request)
        if !r.created.isEmpty {
            let what = r.created.count == 1 ? "removed “\(r.said.last?.components(separatedBy: " · ").first ?? "it")”" : "removed \(r.created.count) items"
            let ids = r.created
            Undo.register(what) { _ = CalendarWriter.remove(ids) }
        }
        if let f = r.failed {
            if f == "cancelled" { return }
            lastPlan = (Planner.Previous(request: request, steps: plan.steps, result: "stopped: \(f)", skillPattern: skillPattern ?? plan.skill?.pattern), Date())
            return show(.system(symbol: "xmark.circle", title: "Stopped", detail: f), for: 3)
        }
        var pattern = skillPattern
        // Only a run whose clicks were seen to take effect is worth remembering; an unverified one would learn a guess.
        let learned = learn && r.verified && plan.skill != nil
        if learned, let s = plan.skill {
            // A corrected plan replaces the skill that got it wrong.
            if let old = replacing, old != s.pattern, let o = SkillStore.shared.skills.first(where: { $0.pattern == old }) { SkillStore.shared.forget(o) }
            SkillStore.shared.learn(name: s.name, pattern: s.pattern, steps: s.steps, example: request)
            pattern = s.pattern
        }
        lastPlan = (Planner.Previous(request: request, steps: plan.steps, result: r.said.isEmpty ? "done" : "answered: \(r.said.joined(separator: " ").prefix(160))", skillPattern: pattern), Date())
        let corrected = replacing != nil
        if !r.said.isEmpty { show(.answer(title: plan.summary, text: r.said.joined(separator: "\n")), for: 6) }
        else { show(.system(symbol: learned ? "brain" : "checkmark", title: plan.summary, detail: learned ? (corrected ? "got it · corrected for next time" : "learned · next time it's instant") : (learn && plan.skill != nil ? "done · not saved, couldn't verify the clicks" : nil)), for: 2.2) }
        Memory.record(said: request, did: plan.summary, app: app?.localizedName)
    }

    // MARK: Screen (Apple's on-device model)

    private func screen(_ action: ScreenReader.Action, request: String) async {
        if action == .stopReading {
            return show(.system(symbol: "speaker.slash.fill", title: ScreenReader.stop() ? "Stopped reading" : "Not reading", detail: nil), for: 1)
        }
        let app = frontApp
        if action == .whatsThis {
            show(.system(symbol: "circle.dashed", title: "Circle what you mean", detail: "Esc cancels"), for: 60)
            guard let marks = await MarkOverlay.shared.selectOnce() else { return show(.message("Nothing circled"), for: 1.2) }
            await explainMarks(marks, request: request, app: app)
            return
        }
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
