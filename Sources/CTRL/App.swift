import AppKit
import SwiftUI

@main
struct CTRLMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--route"), i + 1 < args.count {
            return routeFromCLI(args[(i + 1)...].joined(separator: " "))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Debug: `CTRL --route "open facebook dot com"` prints what would happen, opens nothing.
    /// Add `--exec` to actually run it.
    @MainActor static func routeFromCLI(_ text: String) {
        let exec = CommandLine.arguments.contains("--exec")
        let text = text.replacingOccurrences(of: "--exec", with: "").trimmingCharacters(in: .whitespaces)
        AppCatalog.shared.reload()
        print("sites:", URLExtractor.candidates(in: text))
        guard let key = Keychain.apiKey else { print("no API key"); exit(1) }
        // CTRL_MEMORY="said|did|app;said|did|app" pretends these happened just now.
        if let mem = ProcessInfo.processInfo.environment["CTRL_MEMORY"] {
            for e in mem.split(separator: ";") {
                let f = e.split(separator: "|").map(String.init)
                if f.count >= 2 { Memory.record(said: f[0], did: f[1], app: f.count > 2 ? f[2] : nil) }
            }
        }
        // CTRL_APP=Dia pretends that app is in front (for menu commands).
        var menu: MenuReader.Snapshot?
        var front: NSRunningApplication?
        var elements: [Clicker.Element] = []
        if let name = ProcessInfo.processInfo.environment["CTRL_APP"],
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            front = app
            app.activate(); usleep(400_000)   // like real use: the app is in front
            let t0 = Date()
            menu = MenuReader.snapshot(of: app)
            print("menu: \(menu?.items.count ?? 0) items read in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            let t1 = Date()
            elements = ProcessInfo.processInfo.environment["CTRL_VISUAL"] == "1" ? [] : Clicker.elements(of: app)
            print("clickables: \(elements.count) read in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            if ProcessInfo.processInfo.environment["CTRL_DUMP"] == "2" { elements.forEach { print("   ", $0.role, $0.label) } }
            if ProcessInfo.processInfo.environment["CTRL_DUMP"] == "1" { menu?.items.forEach { print("   ", $0.key, $0.shortcut ?? "") } }
        }
        Task {
            let start = Date()
            do {
                let router = CommandRouter(client: TypeSafeClient(apiKey: key))
                let env = ProcessInfo.processInfo.environment
                let outcome = try await router.route(text, menu: menu, front: front, elements: elements,
                                                     previous: env["CTRL_PREV"], dictating: env["CTRL_DICTATING"] == "1")
                let ms = String(format: "(%.0f ms)", Date().timeIntervalSince(start) * 1000)
                if case .type(let text, let ret) = outcome {
                    print("outcome: type “\(text)” return=\(ret) \(ms)")
                    if exec { front?.activate(); try? await Task.sleep(for: .milliseconds(300)); await Typer.type(text, pressReturn: ret); print("executed") }
                } else if case .file(let url, let reveal) = outcome {
                    print("outcome: file \(url.path) reveal=\(reveal) \(ms)")
                    if exec { Files.open(url, reveal: reveal) }
                } else if case .click(let el) = outcome {
                    print("outcome: click \(el.role) “\(el.label)” at \(el.frame) \(ms)")
                    if exec { front?.activate(); Clicker.press(el); try? await Task.sleep(for: .seconds(0.8)); print("executed") }
                } else if case .clickVisual(let app, let what) = outcome {
                    print("outcome: clickVisual “\(what)” \(ms)")
                    let t = Date()
                    let p = try await router.locate(what, in: app)
                    print("   located: \(p.map { "\($0)" } ?? "not visible") (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                    if exec, let p { app.activate(); try? await Task.sleep(for: .seconds(0.3)); Clicker.click(at: p); print("executed") }
                } else if case .routine(let r) = outcome {
                    print("outcome: routine \(r.name) \(ms)")
                    for step in r.runnableSteps {
                        let o = try await CommandRouter(client: TypeSafeClient(apiKey: key)).route(step)
                        print("   step “\(step)” →", o)
                    }
                } else if case .window(let action, let app) = outcome {
                    print("outcome: window \(action.rawValue) app=\(app.localizedName ?? "?") \(ms)")
                    if exec {
                        let r = await WindowCommands.perform(action, app: app)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                } else if case .system(let action, let level) = outcome {
                    print("outcome: system \(action.rawValue) level=\(level.map(String.init) ?? "-") \(ms)")
                    if exec, ![.lock, .sleep, .displayOff].contains(action) {
                        let r = await SystemController.perform(action, level: level)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1.2))
                    }
                } else if case .menu(let item, let app) = outcome {
                    print("outcome: menu \(item.key) \(item.shortcut ?? "") \(ms)")
                    if exec { MenuReader.press(item, in: app); try? await Task.sleep(for: .seconds(1)); print("executed") }
                } else if case .open(let p) = outcome {
                    let names = p.targets.map { t -> String in
                        switch t { case .app(let a): a.name; case .site(let u): u.absoluteString }
                    }
                    print("outcome: open \(names) windows=\(p.windowsEach) layout=\(p.layout.rawValue) \(ms)")
                    if exec { await WindowManager.run(p); print("executed, AX trusted:", HotkeyMonitor.hasAccessibility) }
                } else if case .settings(let page, let action) = outcome {
                    print("outcome: settings \(page.key) \(action.rawValue) \(ms)")
                    if exec {
                        let r = SettingsController.perform(page, action: action)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1))   // let deferred activation run
                    }
                } else if case .media(let action, let preferred) = outcome {
                    print("outcome: media \(action.rawValue) preferred=\(preferred ?? "-") \(ms)")
                    if exec {
                        let r = await MediaController.perform(action, preferred: preferred)
                        print("executed: \(r.player?.name ?? "media key") — \(r.title) \(r.detail ?? "")")
                    }
                } else {
                    print("outcome:", outcome, ms)
                }
            } catch { print("error:", error.localizedDescription) }
            exit(0)
        }
        RunLoop.main.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel()
    private let hotkey = HotkeyMonitor()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private let routinesWindow = RoutinesWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCatalog.shared.reload()

        let panel = NotchPanel(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        model.onScreenChange = { [weak self] in self?.panel?.reposition() }

        hotkey.onBegin = { [weak self] in self?.model.begin() }
        hotkey.onEnd = { [weak self] in self?.model.end() }
        hotkey.onCancel = { [weak self] in self?.model.cancel() }
        hotkey.onLock = { [weak self] in self?.model.lock() }
        hotkey.onUnlock = { [weak self] in self?.model.unlock() }
        hotkey.start()
        model.startObservers()

        setUpMenu()
        if CommandLine.arguments.contains("--routines") { editRoutines() }

        if ProcessInfo.processInfo.environment["CTRL_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runDemo() }
            return
        }
        if let path = ProcessInfo.processInfo.environment["CTRL_LOCKTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.lockTest(path) }
            return
        }
        if !HotkeyMonitor.hasAccessibility { HotkeyMonitor.promptForAccessibility() }
        Task {
            _ = await SpeechRecorder.requestPermissions()
            await model.prepare()   // download on-device speech model once
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.panel?.reposition() } }
    }

    private func setUpMenu() {
        // Menu-bar-only apps have no Edit menu, so ⌘V/⌘C/⌘A don't work in text fields without this.
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "CTRL")
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold left ⌥ Option and speak", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "⌥⇧ to keep listening · tap ⌥ to stop", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set TypeSafe API Key…", action: #selector(setKey), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        menu.addItem(withTitle: "Routines…", action: #selector(editRoutines), keyEquivalent: "")
        menu.addItem(withTitle: "Rescan Apps", action: #selector(rescan), keyEquivalent: "")
        menu.addItem(withTitle: "Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CTRL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func setKey() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "TypeSafe API Key"
        alert.informativeText = "Stored in your Keychain. Get one at typesafe.ai."
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "apikey_…"
        // Prefill from clipboard if it looks like a key.
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.hasPrefix("apikey_") {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.save(key) }
        }
    }

    @objc private func rescan() { AppCatalog.shared.reload() }

    @objc private func editVocabulary() { Vocabulary.open() }
    @objc private func editRoutines() { routinesWindow.show { [weak self] in self?.model.run($0) } }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
