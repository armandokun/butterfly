import AppKit
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case opened([WindowManager.Target], detail: String?)
        case media(InstalledApp?, title: String, detail: String?)
        case unsure(InstalledApp?)
        case message(String)
    }

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)

    private let recorder = SpeechRecorder()
    private var menuSnapshot: MenuReader.Snapshot?
    private var dismissTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init() {
        recorder.onPartial = { [weak self] in self?.transcript = $0 }
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
    func runDemo() {
        Task {
            let safari = AppCatalog.shared.app(named: "Safari")
            phase = .listening
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
        transcript = ""
        levels = levels.map { _ in 0 }
        phase = .listening
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // Read the front app's menus while you talk, so it costs no time later.
        menuSnapshot = nil
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            Task { self.menuSnapshot = MenuReader.snapshot(of: front) }
        }
        startTask = Task {
            do { try await recorder.start() }
            catch { show(.message("Mic error: \(error.localizedDescription)")) }
        }
    }

    func end() {
        guard phase == .listening else { return }
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
            let outcome = try await router.route(text, menu: menuSnapshot)
            if case .routine(let r) = outcome { return await run(r, router: router) }
            await perform(outcome)
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
        phase = .idle
        transcript = ""
    }
}
