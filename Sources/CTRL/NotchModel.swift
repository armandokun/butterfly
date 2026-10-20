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
        case opened([WindowManager.Target], detail: String?)
        case media(InstalledApp?, title: String, detail: String?)
        case system(symbol: String, title: String, detail: String?)
        case unsure(InstalledApp?)
        case message(String)
    }

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

    /// Short-term memory entry: what you said, what CTRL did, where.
    private func remember(_ said: String, _ outcome: CommandRouter.Outcome) {
        let did: String
        switch phase {
        case .opened(let targets, _): did = "opened " + targets.map { t in
            switch t { case .app(let a): a.name; case .site(let u): u.host() ?? u.absoluteString } }.joined(separator: ", ")
        case .media(_, let title, let detail), .system(_, let title, let detail): did = title + (detail.map { " · \($0)" } ?? "")
        case .message(let m): did = m
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
            self.levels.removeFirst()
            self.levels.append(CGFloat(level))
        }
    }

    func prepare() async {
        try? await recorder.prepare()
    }

    /// `CTRL_DEMO=1`: cycles through every state for visual checks.
    /// `CTRL_LOCKTEST=file.aiff`: locked mode fed from an audio file instead of the mic.
    func lockTest(_ path: String) {
        isLocked = true
        accepting = true
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
            for t in ["open", "open sla", "open slack"] {
                transcript = t
                for _ in 0..<6 {
                    levels.removeFirst(); levels.append(.random(in: 0.2...1))
                    try? await Task.sleep(for: .milliseconds(120))
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

    func begin() {
        dismissTask?.cancel()
        moveToActiveScreen()
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Task { self.readFrontApp() }   // after the notch appears
        startTask = Task {
            do { try await recorder.start() }
            catch { show(.message("Mic error: \(error.localizedDescription)")) }
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

    /// Read the front app's menus and buttons while you talk, so it costs no time later.
    private func readFrontApp() {
        menuSnapshot = nil
        frontApp = nil
        clickables = []
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontApp = front
            menuSnapshot = MenuReader.snapshot(of: front)
            clickables = Clicker.elements(of: front)
        }
    }

    // MARK: Locked mode (⌥⇧): keep listening, run each sentence when you pause

    @Published private(set) var isLocked = false
    private var accepting = false          // still taking sentences (true until the mic fully stops)
    private var queue: [String] = []
    private var working = false

    func lock() {
        guard !isLocked else { return }
        isLocked = true
        accepting = true
        if phase != .listening { begin() } else { dismissTask?.cancel() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        dictating = false
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
        Task {
            await startTask?.value
            let text = await recorder.stop()
            guard !text.isEmpty else { return close() }
            transcript = text
            phase = .thinking
            await handle(text)
        }
    }

    func cancel() {
        guard !isLocked else { return }
        Task {
            await startTask?.value
            await recorder.cancel()
            close()
        }
    }

    // MARK: Routing

    private func handle(_ text: String) async {
        guard let key = Keychain.apiKey else {
            // No key yet: simple fallbacks so the app still works.
            if let app = AppCatalog.shared.localMatch(text) { return launch(app) }
            let site = Vocabulary.matches(in: text).first { $0.contains(".") } ?? URLExtractor.candidates(in: text).first
            if let site, let url = URLExtractor.url(for: site) { return openSite(url) }
            return show(.message("Add your TypeSafe key from the menu bar"))
        }
        do {
            let router = CommandRouter(client: TypeSafeClient(apiKey: key))
            let previous = Date().timeIntervalSince(lastCommandAt) < 120 ? lastCommand : nil
            var outcome = try await router.route(text, menu: menuSnapshot, front: frontApp, elements: clickables,
                                                 previous: previous, dictating: dictating)
            if case .repeatLast = outcome, let previous {
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
            if case .routine(let r) = outcome { return await run(r, router: router) }
            lastActionDisplay = nil
            await perform(outcome)
            remember(text, outcome)
        } catch {
            if let app = AppCatalog.shared.localMatch(text) { return launch(app) }
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
            switch outcome {
            case .routine: break   // handled by the caller; routines don't nest
            case .type(let text, let pressReturn):
                frontApp?.activate()
                close()   // notch out of the way; typing goes to your cursor
                try? await Task.sleep(for: .milliseconds(120))
                await Typer.type(text, pressReturn: pressReturn)
                typedInDictation = true
            case .continueTyping(let text):
                frontApp?.activate()
                close()
                // "…and press enter" / "send it" works mid-dictation too.
                if let t = Typer.finishText(text) {
                    let space = typedInDictation && !t.text.isEmpty ? " " : ""
                    await Typer.type(space + t.text, pressReturn: t.pressReturn)
                    if !t.text.isEmpty { typedInDictation = true }
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
                    show(.message(denied ? "Allow Screen Recording for CTRL" : error.localizedDescription), for: 2.5)
                }
            case .window(let action, let app):
                let r = await WindowCommands.perform(action, app: app)
                lastActionDisplay = WindowCommands.display(of: app)
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: 1.4)
            case .system(let action, let level):
                let r = await SystemController.perform(action, level: level)
                show(.system(symbol: r.symbol, title: r.title, detail: r.detail), for: action == .screenshotFull ? 0.6 : 1.4)
            case .menu(let item, let app):
                MenuReader.press(item, in: app)
                let icon = app.bundleURL.map { InstalledApp(name: app.localizedName ?? "", url: $0) }
                show(.media(icon, title: item.title, detail: item.path.dropLast().joined(separator: " → ")), for: 1.6)
            case .open(let plan): launch(plan)
            case .media(let action, let preferred):
                let result = await MediaController.perform(action, preferred: preferred)
                show(.media(result.player, title: result.title, detail: result.detail), for: 2.2)
            case .settings(let page, let action):
                let r = SettingsController.perform(page, action: action)
                show(.media(SettingsController.settingsApp, title: r.title, detail: r.detail), for: 1.8)
            case .unsure(let app): show(.unsure(app))
            case .needAddress: show(.message("Say the full address, like “facebook dot com”"))
            case .notACommand: show(.message("Try “open Safari” or “open facebook.com”"))
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
