import AppKit
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case opened(InstalledApp)
        case openedSite(URL)
        case unsure(InstalledApp?)
        case message(String)
    }

    @Published var phase: Phase = .idle
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 5)

    private let recorder = SpeechRecorder()
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
            if let safari { phase = .opened(safari) }
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
            if let site = URLExtractor.candidates(in: text).first, let url = URLExtractor.url(for: site) { return openSite(url) }
            return show(.message("Add your TypeSafe key from the menu bar"))
        }
        do {
            switch try await CommandRouter(client: TypeSafeClient(apiKey: key)).route(text) {
            case .openApp(let app): launch(app)
            case .openSite(let url): openSite(url)
            case .unsure(let app): show(.unsure(app))
            case .needAddress: show(.message("Say the full address, like “facebook dot com”"))
            case .notACommand: show(.message("Try “open Safari” or “open facebook.com”"))
            }
        } catch {
            if let app = AppCatalog.shared.localMatch(text) { return launch(app) }
            show(.message(error.localizedDescription))
        }
    }

    private func openSite(_ url: URL) {
        NSWorkspace.shared.open(url)
        show(.openedSite(url))
    }

    private func launch(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
        show(.opened(app))
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
