import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case system(symbol: String, title: String, detail: String?)
        case message(String)
        case badge(symbol: String, text: String, tint: Color)   // compact: icon left, short text right
        case answer(title: String, text: String)                // expanded, a few lines
        case recap(title: String, range: String, items: [RecapItem])   // expanded, "what did I do" timeline
        case meetingPrompt(app: String)                         // expanded: "Record this meeting?" with buttons
        case recordingCard                                      // expanded on hover while recording: time + Stop
        case transcriptReady(title: String, file: URL)          // expanded: "Transcript ready" + Open
        case stopPrompt(app: String)                            // expanded: "Call ended?" · Keep / Stop
    }
    struct Recording: Equatable { let app: String; let since: Date }
    /// One goal in a "what did I do" recap: when it started, what it was for, the apps used, time spent.
    struct RecapItem: Equatable { let time: String; let goal: String; let apps: [String]; let minutes: Int? }

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

    @Published var phase: Phase = .idle {
        didSet {
            updateInteractive()
            // Timed out or replaced without an answer: no recording.
            if case .meetingPrompt = oldValue, !isPrompt { Meetings.shared.answer(record: false) }
        }
    }
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)
    /// Right ⌥: dictation only. What you say gets typed, nothing is interpreted.
    @Published private(set) var dictationOnly = false
    @Published private(set) var isLocked = false

    private let recorder = SpeechRecorder()
    private var frontApp: NSRunningApplication?
    private var typedInDictation = false   // first dictated sentence gets no leading space
    private var peakLevel: CGFloat = 0     // loudest sound this press: 0 = the mic heard nothing
    private var dismissTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestGen = 0

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
            self.peakLevel = max(self.peakLevel, CGFloat(level))
            self.levels.removeFirst()
            self.levels.append(CGFloat(level))
        }
    }

    func prepare() async {
        recorder.watchDevices()
        try? await recorder.prepare()
    }

    // MARK: Meetings

    func startObservers() {
        Agenda.shared.start()
        NowPlaying.shared.start()   // Ducker lowers music only while something plays
        Meetings.shared.onEvent = { [weak self] e in
            // Shown even over other results: recording must never start or stop unseen.
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

    /// Debug (BUTTERFLY_RECORDING_STATES=1): every meeting-notes state, 3 s each, for screenshots.
    func recordingStatesDemo() {
        let steps: [() -> Void] = [
            { self.phase = .meetingPrompt(app: "Dia call") },
            { self.phase = .idle; self.recording = Recording(app: "Dia call", since: Date().addingTimeInterval(-270)) },
            { self.phase = .recordingCard },
            { self.phase = .stopPrompt(app: "Dia call") },
            { self.recording = nil; self.phase = .idle; self.transcribing = "Dia call" },
            { self.transcribing = nil; self.phase = .transcriptReady(title: "Dia call", file: Meetings.root) },
            { self.phase = .badge(symbol: "xmark.circle", text: "Not saved", tint: .gray) },
            { self.phase = .idle },
        ]
        for (i, s) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) { self.dismissTask?.cancel(); s() }
        }
    }

    // MARK: Hotkey events

    /// ⌥ went down: start the mic during the hold delay; cancelled if it was a shortcut.
    func arm() {
        cancelRequestIfRunning()   // ⌥ again while a request runs: that one's dropped (tap = just cancel)
        recorder.arm()
    }
    func disarm() { recorder.disarm() }

    func begin(dictation: Bool = false) {
        cancelRequestIfRunning()
        dictationOnly = dictation
        dismissTask?.cancel()
        moveToActiveScreen()
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        Cues.listening()
        Ducker.duck()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        if !dictation { DesktopAgent.warm(frontApp) }
        startTask = Task {
            do { try await recorder.start(onAudio: {}) }
            catch { show(.message("Mic error: \(error.localizedDescription)")) }
        }
    }

    func end() {
        guard phase == .listening, !isLocked else { return }
        Cues.stopped()
        Ducker.restore()
        requestGen += 1
        let gen = requestGen
        requestTask = Task {
            defer { if requestGen == gen { requestTask = nil } }
            await startTask?.value
            let text = await recorder.stop()
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
                await Typer.type(text)
                return
            }
            transcript = text
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

    /// ⌥ pressed while a request is running: stop it. Returns true when something was stopped.
    @discardableResult
    private func cancelRequestIfRunning() -> Bool {
        guard let requestTask, !requestTask.isCancelled, !isLocked else { return false }
        requestTask.cancel()
        self.requestTask = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        show(.system(symbol: "xmark", title: "Cancelled", detail: nil), for: 0.9)
        return true
    }

    // MARK: Locked mode (⌥⇧): keep listening, run each sentence when you pause

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

    private static let stopPhrase = #/^(ok(ay)?,? )?(stop( (listening|dictating|dictation|typing))?|that's all|i'm done|done)[.!]?$/#

    private func enqueue(_ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepting, s.count > 1 else { return }
        queue.append(s)
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if next.lowercased().firstMatch(of: Self.stopPhrase) != nil { unlock(); continue }
                if dictationOnly {
                    frontApp?.activate()
                    await Typer.type((typedInDictation ? " " : "") + next)
                    typedInDictation = true
                    transcript = ""
                    continue
                }
                dismissTask?.cancel()
                transcript = next
                frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 } ?? frontApp
                await handle(next)
                try? await Task.sleep(for: .milliseconds(queue.isEmpty ? 0 : 700))
            }
            working = false
            if !accepting { close() }
        }
    }

    // MARK: The agent

    /// BUTTERFLY_SAY: as if spoken, on the app in front.
    func say(_ text: String) {
        frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        transcript = text
        DesktopAgent.warm(frontApp)
        // As if spoken: the request arrives after you've talked for a bit (BUTTERFLY_SAY_DELAY seconds).
        let delay = Double(ProcessInfo.processInfo.environment["BUTTERFLY_SAY_DELAY"] ?? "") ?? 0
        requestTask = Task { try? await Task.sleep(for: .seconds(delay)); await handle(text) }
    }

    private func handle(_ text: String) async {
        guard let key = Keychain.geminiKey else { return show(.message("Add a Gemini key in Settings"), for: 3) }
        phase = .thinking
        frontApp?.activate()   // the agent works on what you were looking at, not the notch
        do {
            let r = try await DesktopAgent.run(text, front: frontApp, key: key) { [weak self] line in
                self?.show(.system(symbol: "sparkles", title: line, detail: text), for: 60)
            }
            if let recap = r.recap {
                let items = recap.items.map { RecapItem(time: $0.time, goal: $0.goal, apps: $0.apps, minutes: $0.minutes) }
                return show(.recap(title: recap.title, range: recap.range, items: items), for: 4 + Double(items.count) * 1.5)
            }
            if let a = r.answer {
                return show(.answer(title: r.summary, text: a), for: min(20, max(6, Double(a.split(separator: " ").count) / 3)))
            }
            show(.system(symbol: "checkmark", title: r.summary, detail: nil), for: 2.2)
        } catch {
            if Task.isCancelled { return }
            show(.message(error.localizedDescription), for: 3.5)
        }
    }

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

    // MARK: Showing

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
