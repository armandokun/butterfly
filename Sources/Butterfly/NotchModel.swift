import AppKit
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case system(symbol: String, title: String, detail: String?)
        case message(String)
        case badge(symbol: String, text: String, tint: Color)   // compact: icon left, short text right
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

    @Published var phase: Phase = .idle {
        didSet {
            updateInteractive()
            // Timed out or replaced without an answer: no recording.
            if case .meetingPrompt = oldValue, !isPrompt { Meetings.shared.answer(record: false) }
        }
    }
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)
    @Published private(set) var isLocked = false

    private let recorder = SpeechRecorder()
    private var frontApp: NSRunningApplication?
    private var typedInDictation = false   // first dictated sentence gets no leading space
    private var peakLevel: CGFloat = 0     // loudest sound this press: 0 = the mic heard nothing
    private var dismissTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init() {
        recorder.onPartial = { [weak self] text in
            guard let self, !self.isLocked, !self.liveActive else { return }
            self.transcript = text
        }
        // Locked mode: show only the sentence in progress; run each one as it finalizes.
        recorder.onVolatile = { [weak self] text in
            guard let self, self.isLocked, self.phase == .listening, !self.liveActive else { return }
            self.transcript = text
        }
        recorder.onSegment = { [weak self] text, end in
            guard let self, !self.liveActive, !self.liveFinishing else { return }   // Gemini Live types the sentences
            self.enqueue(text, end: end)
        }
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

    /// Must-see events (meeting recording): shown over anything except you dictating,
    /// in which case it waits (up to 30 s) until you're done.
    func notify(_ p: Phase, for seconds: Double, waited: Int = 0) {
        if phase == .listening, waited < 30 {
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

    // MARK: Dictation (hold ⌥: what you say gets typed)

    /// ⌥ went down: start the mic during the hold delay; cancelled if it was a shortcut.
    func arm() { recorder.arm() }
    func disarm() { recorder.disarm() }

    /// Bumps each press: a slow result from the last press mustn't close the new one.
    private var press = 0

    func begin() {
        press += 1
        dismissTask?.cancel()
        moveToActiveScreen()
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        Cues.listening()
        Ducker.duck()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        if !recorder.isArmed { recorder.resetClip() }   // ⌥⇧ straight away: no armed mic, so no audio yet
        startLive(locked: isLocked)
        startTask = Task {
            do { try await recorder.start(onAudio: {}) }
            catch { show(.message("Mic error: \(error.localizedDescription)")) }
        }
    }

    func end() {
        guard phase == .listening, !isLocked else { return }
        Cues.stopped()
        Ducker.restore()
        let myPress = press
        Task {
            await startTask?.value
            let l = live
            live = nil
            let liveTask = l.map { l in Task { await l.finish() } }   // ends the turn now, in parallel with the mic stopping
            let apple = await recorder.stop()
            recorder.streamPCM(to: nil)
            let silent = peakLevel < 0.02
            peakLevel = 0
            // Total silence = wrong or muted mic, not a quiet voice: say which one, and where to change it.
            if silent { l?.cancel(); return show(.system(symbol: "mic.slash", title: "Heard nothing", detail: "Using \(recorder.micName ?? "no microphone") · change it in Settings"), for: 3) }
            var text: String
            if let t = await liveTask?.value {
                text = t
            } else {
                // Live didn't work: upload the clip instead (slower), else Apple's text.
                if Keychain.geminiKey != nil { phase = .system(symbol: "waveform", title: "Transcribing", detail: nil) }
                text = await transcribe(fallback: apple)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pressedAgain = press != myPress   // a new press is listening: don't close it, just type
            guard !text.isEmpty else { if !pressedAgain { close() }; return }
            if !pressedAgain { close() }
            frontApp?.activate()
            try? await Task.sleep(for: .milliseconds(80))
            await Typer.type(text)
        }
    }

    func cancel() {
        guard !isLocked else { return }
        live?.cancel()
        live = nil
        recorder.streamPCM(to: nil)
        Task {
            await startTask?.value
            await recorder.cancel()
            Ducker.restore()
            close()
        }
    }

    // MARK: Locked mode (⌥⇧): keep listening, type each sentence when you pause

    private var accepting = false          // still taking sentences (true until the mic fully stops)
    /// Sentences to type. `done`: already transcribed (Gemini Live); otherwise Apple's text + where it is in the clip.
    private var queue: [(text: String, from: Double, to: Double, done: Bool)] = []
    private var segmentStart = 0.0
    private var working = false

    private var stopping: Task<Void, Never>?   // the last locked session still finishing
    private var liveFinishing = false

    func lock() {
        guard !isLocked else { return }
        isLocked = true
        // Locked again before the last one finished stopping: start fresh once it has (else it'd stop this mic).
        if let stopping {
            Task {
                await stopping.value
                guard isLocked else { return }
                isLocked = false
                phase = .idle
                lock()
            }
            return
        }
        accepting = true
        typedInDictation = false
        segmentStart = 0
        if phase != .listening { begin() } else {
            dismissTask?.cancel()
            // Upgraded from a hold: finish the hold's turn (typed first), then a locked session for what comes next.
            if let held = live {
                live = nil
                Task {
                    if let t = await held.finish() { enqueueDone(t) }
                }
                startLive(locked: true, fromNow: true)
            }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        Cues.stopped()
        Ducker.restore()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        stopping = Task {
            await startTask?.value
            let l = live
            live = nil
            liveFinishing = l.map { !$0.hasFailed } ?? false   // Live still has the last words: Apple's copy would type them twice
            let liveTask = l.map { l in Task { await l.finish() } }
            _ = await recorder.stop()   // flushes the last sentence through onSegment
            recorder.streamPCM(to: nil)
            _ = await liveTask?.value     // the last sentence arrives through onFinal
            try? await Task.sleep(for: .milliseconds(50))
            accepting = false
            liveFinishing = false
            stopping = nil
            if !working { close() }
        }
    }

    private static let stopPhrase = #/^(ok(ay)?,? )?(stop( (listening|dictating|dictation|typing))?|that's all|i'm done|done)[.!]?$/#

    private func enqueue(_ sentence: String, end: Double) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = segmentStart
        segmentStart = end
        guard accepting, s.count > 1 else { return }
        queue.append((s, from, end, false))
        drain()
    }

    private func enqueueDone(_ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepting, !s.isEmpty else { return }
        queue.append((s, 0, 0, true))
        drain()
    }

    private func drain() {
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let seg = queue.removeFirst()
                if seg.text.lowercased().firstMatch(of: Self.stopPhrase) != nil { unlock(); continue }
                let next = seg.done ? seg.text : await transcribe(fallback: seg.text, from: seg.from, to: seg.to)
                guard !next.isEmpty else { continue }
                frontApp?.activate()
                await Typer.type((typedInDictation ? " " : "") + next.prefix(1).uppercased() + next.dropFirst())
                typedInDictation = true
                transcript = ""
            }
            working = false
            if !accepting { close() }
        }
    }

    // MARK: Gemini Live (streams while you talk)

    private var live: LiveDictation?
    /// Push-to-talk: utterances Live has finished this press (typed on release).
    private var liveSaid = ""
    private var liveActive: Bool { live.map { !$0.hasFailed } ?? false }

    private func startLive(locked: Bool = false, fromNow: Bool = false) {
        live?.cancel()
        live = nil
        liveSaid = ""
        guard let key = Keychain.geminiKey else { return }
        let l = LiveDictation(key: key, vocabulary: Vocabulary.words, manual: !locked)
        l.onInterim = { [weak self, weak l] t in
            guard let self, let l, self.live === l, self.phase == .listening else { return }
            self.transcript = self.isLocked ? t : LiveDictation.join([self.liveSaid, t])
        }
        l.onFinal = { [weak self, weak l] t in
            guard let self, let l, self.live === l || self.isLocked || self.accepting else { return }
            if self.isLocked || self.accepting { self.enqueueDone(t) }
            else { self.liveSaid = LiveDictation.join([self.liveSaid, t]); if self.phase == .listening { self.transcript = self.liveSaid } }
        }
        live = l
        recorder.streamPCM(to: { [weak l] d in l?.feed(d) }, includeSoFar: !fromNow)
    }

    /// Gemini hears Lithuanian (Apple's on-device speech doesn't); Apple's text if there's no key or Gemini fails.
    private func transcribe(fallback: String, from: Double = 0, to: Double = .infinity) async -> String {
        guard let key = Keychain.geminiKey, let wav = recorder.wav(from: max(0, from - 0.3), to: to.isFinite ? to + 0.3 : to) else { return fallback }
        let t0 = Date()
        do {
            let t = try await MeetingTranscriber.dictation(wav: wav, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
            LiveDictation.log(String(format: "upload fallback %.1fs, %d words", Date().timeIntervalSince(t0), t.split(separator: " ").count))
            return t.isEmpty ? fallback : t
        } catch {
            LiveDictation.log("upload fallback failed, using on-device text: \(error.localizedDescription)")
            return fallback
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
        case .idle, .listening: return
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
