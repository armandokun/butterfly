import AppKit
import EventKit
import SwiftUI

@main
struct CTRLMain {
    static func main() {
        let args = CommandLine.arguments
        // `open CTRL.app --args --add-event "title" "yyyy-MM-dd HH:mm" minutes "location" "notes" ["calendar"]` (runs with CTRL's Calendar access)
        if let i = args.firstIndex(of: "--add-event"), args.count >= i + 6 {
            let a = Array(args[(i + 1)...])
            Task {
                _ = try? await Agent.store.requestFullAccessToEvents()
                var out = "failed"
                if let start = Agent.date(a[1]), let cal = Agent.calendar(named: a.count > 5 ? a[5] : "", request: "") {
                    let e = EKEvent(eventStore: Agent.store)
                    e.calendar = cal; e.title = a[0]; e.startDate = start
                    e.endDate = start.addingTimeInterval((Double(a[2]) ?? 60) * 60)
                    if !a[3].isEmpty { e.location = a[3] }
                    if !a[4].isEmpty { e.notes = a[4] }
                    do { try Agent.store.save(e, span: .thisEvent); out = "added \(a[0]) \(start) in \(cal.title)" } catch { out = "error \(error)" }
                }
                try? out.write(toFile: "/tmp/ctrl-add-event.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--date"), i + 1 < args.count {
            for t in args[(i + 1)...] { print(t, "→", Agent.date(t).map { $0.formatted() } ?? "nil", "time:", Agent.hasTime(t)) }
            return
        }
        // `CTRL --mictest`: records 3 s with the same recorder the notch uses, prints mic, level and transcript.
        if args.contains("--mictest") {
            Task { @MainActor in
                let r = SpeechRecorder()
                var peak: Float = 0
                r.onLevel = { peak = max(peak, $0) }
                try? await r.prepare()
                do { try await r.start() } catch { print("start failed:", error); exit(1) }
                print("listening with:", r.micName ?? "?")
                try? await Task.sleep(for: .seconds(3))
                let text = await r.stop()
                print("peak level:", peak, "· heard:", text.isEmpty ? "(nothing)" : text)
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--playlist-art") {
            let names = MediaController.ownPlaylists().prefix(4)
            print("playlists:", Array(names))
            for (n, img) in MediaController.artwork(for: Array(names)) { print(n, "→", img.map { "\($0.size)" } ?? "none") }
            return
        }
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
        AudioOutput.warm()
        AppCatalog.shared.reload()
        print("sites:", URLExtractor.candidates(in: text))
        guard let key = Keychain.apiKey else { print("no API key"); exit(1) }
        Bluetooth.shared.refreshNow()
        // CTRL_CLIPS="newest|older|oldest" pretends these were copied.
        if let c = ProcessInfo.processInfo.environment["CTRL_CLIPS"] { Clipboard.shared.seed(c.components(separatedBy: "|")) }
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
                let cursorSnap = front.flatMap(CursorControl.snapshot)
                if let cursorSnap { print("cursor: \(cursorSnap.chats.count) chats, project \(cursorSnap.currentProject ?? "-"), open: \(cursorSnap.chats.first { $0.current }?.title ?? "-")") }
                let outcome = try await router.route(text, menu: menu, front: front, elements: elements,
                                                     previous: env["CTRL_PREV"], dictating: env["CTRL_DICTATING"] == "1", cursor: cursorSnap)
                let ms = String(format: "(%.0f ms)", Date().timeIntervalSince(start) * 1000)
                if case .cursor(let action, let chat, let project, let message) = outcome {
                    print("outcome: cursor \(action.rawValue) chat=\(chat?.title ?? "-") project=\(project ?? "-") message=“\(message)” \(ms)")
                    if exec, let cursorSnap {
                        let r = await CursorControl.perform(action, chat: chat, project: project, message: message, snapshot: cursorSnap, menu: menu)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1))
                    }
                } else if case .askBrowser(let q) = outcome {
                    print("outcome: askBrowser “\(q)” \(ms)")
                    if exec { let b = await BrowserTab.ask(q); print("executed in \(b?.name ?? "-")"); try? await Task.sleep(for: .seconds(1)) }
                } else if case .type(let text, let ret) = outcome {
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
                    if exec { let ok = await MenuReader.press(item, in: app); try? await Task.sleep(for: .seconds(1)); print("executed", ok) }
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
                } else if case .media(let action, let preferred, let query) = outcome {
                    print("outcome: media \(action.rawValue) preferred=\(preferred ?? "-") query=\(query ?? "-") \(ms)")
                    if exec {
                        let r = await MediaController.perform(action, preferred: preferred, query: query)
                        print("executed: \(r.player?.name ?? "media key") — \(r.title) \(r.detail ?? "")")
                    }
                } else if case .agent(let request) = outcome {
                    print("outcome: agent \(ms)")
                    if exec {
                        Agent.dryRun = true
                        Agent.runCommand = { c in print("   run_command:", c); return "Done" }
                        Agent.typeText = { t in print("   type_text:", t) }
                        let t = Date()
                        for d in try await Agent.run(request, app: front, client: TypeSafeClient(apiKey: key)) { print("   done: \(d.text)") }
                        print("   (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                    }
                } else if case .navigate(let a) = outcome {
                    print("outcome: navigate \(a.rawValue) \(ms)")
                    if exec { let r = await KeyCommands.perform(a, in: front); print("executed: \(r.title)"); try? await Task.sleep(for: .seconds(0.5)) }
                } else if case .screen(let a, let request) = outcome {
                    print("outcome: screen \(a.rawValue) \(ms)")
                    if exec {
                        let t = Date()
                        guard let (text, selected) = await ScreenReader.text(of: front) else { print("no text (screen recording?)"); exit(0) }
                        print("   read \(text.count) chars, selected=\(selected) (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                        let t2 = Date()
                        let answer = try await ScreenReader.answer(a, request: request, text: text, app: front?.localizedName)
                        print("   answer (\(Int(Date().timeIntervalSince(t2) * 1000)) ms): \(answer)")
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
    private var openSettings: (() -> Void)?
    private var scenes: AnyObject?   // keep the Settings scene alive

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apple's Settings scene (WWDC26 "Use SwiftUI with AppKit"): standard pane toolbar, title, dimmed buttons.
        let model = self.model
        let scenes = NSHostingSceneRepresentation {
            Settings { SettingsView(run: { model.run($0) }) }
        }
        NSApplication.shared.addSceneRepresentation(scenes)
        self.scenes = scenes
        // While Settings is open CTRL is a normal app (Dock icon), so macOS brings you to it,
        // even from a full-screen app. Closing it goes back to menu-bar-only.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue.contains("Settings") == true else { return }
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }
        openSettings = { scenes.environment.openSettings() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioOutput.warm()
        if Installer.offerMoveToApplications() { return }
        AppCatalog.shared.reload()

        let panel = NotchPanel(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        model.onScreenChange = { [weak self] in self?.panel?.reposition() }
        panel.onSwipeAway { [weak self] in self?.model.swipeAway() }

        hotkey.onBegin = { [weak self] dictation in self?.model.begin(dictation: dictation) }
        hotkey.onArm = { [weak self] in self?.model.arm() }
        hotkey.onDisarm = { [weak self] in self?.model.disarm() }
        hotkey.onArm = { [weak self] in self?.model.arm() }
        hotkey.onDisarm = { [weak self] in self?.model.disarm() }
        hotkey.onEnd = { [weak self] in self?.model.end() }
        hotkey.onCancel = { [weak self] in self?.model.cancel() }
        hotkey.onLock = { [weak self] dictation in self?.model.lock(dictation: dictation) }
        hotkey.onUnlock = { [weak self] in self?.model.unlock() }
        hotkey.start()
        model.startObservers()

        setUpMenu()
        LoginItem.applyDefault()
        if CommandLine.arguments.contains("--routines") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.editRoutines() } }

        if let b = ProcessInfo.processInfo.environment["CTRL_BADGE"]?.split(separator: "|").map(String.init), b.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.badge(symbol: b[0], text: b[1], tint: .green), for: 4) }
        }
        if let a = ProcessInfo.processInfo.environment["CTRL_SYSTEM"]?.split(separator: "|").map(String.init), a.count == 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.system(symbol: a[0], title: a[1], detail: a[2]), for: 8) }
        }
        if let a = ProcessInfo.processInfo.environment["CTRL_ANSWER"]?.split(separator: "|").map(String.init), a.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.answer(title: a[0], text: a[1].replacingOccurrences(of: "\\n", with: "\n")), for: 6) }
        }
        if let s = ProcessInfo.processInfo.environment["CTRL_TIMER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = Timers.shared.start(s) }
        }
        if let lines = ProcessInfo.processInfo.environment["CTRL_SPEAK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.model.speakTest(lines.components(separatedBy: "|")) }
        }
        if ProcessInfo.processInfo.environment["CTRL_PTT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.model.pttTest() }
        }
        if let say = ProcessInfo.processInfo.environment["CTRL_SAY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.say(say.components(separatedBy: "|")) }
        }
        if ProcessInfo.processInfo.environment["CTRL_GALLERY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runGallery() }
            return
        }
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
        ) { [weak self] _ in Task { @MainActor in self?.panel?.reposition() } }
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
        let glyph = Bundle.main.image(forResource: "menubar") ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Butterfly")
        glyph?.isTemplate = true   // follows light/dark menu bar
        glyph?.size = .init(width: 18, height: 18)
        item.button?.image = glyph
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(editRoutines), keyEquivalent: ",")
        let tree = menu.addItem(withTitle: "Decision Tree", action: #selector(toggleDecisionTree), keyEquivalent: "d")
        tree.keyEquivalentModifierMask = [.command, .option]
        tree.isHidden = !UserDefaults.standard.bool(forKey: "developerMode")
        decisionTreeItem = tree
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Butterfly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item
        watchDeveloperMode()
    }

    private var decisionTreeItem: NSMenuItem?
    private var developerObserver: NSObjectProtocol?

    @objc private func toggleDecisionTree() { DecisionTreeWindow.shared.toggle() }

    /// Developer mode on/off: show or hide the menu item (and close the window when it goes off).
    private func watchDeveloperMode() {
        // Fires for any defaults change, even mid-layout (AppKit registers defaults while SwiftUI draws Settings):
        // act only when the toggle really flips, and after the current layout pass, or SwiftUI aborts.
        var last = UserDefaults.standard.bool(forKey: "developerMode")
        developerObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let on = UserDefaults.standard.bool(forKey: "developerMode")
                    guard on != last else { return }
                    last = on
                    self?.decisionTreeItem?.isHidden = !on
                    if !on { DecisionTreeWindow.shared.close() }
                    else if !DecisionTreeWindow.shared.wasShown { DecisionTreeWindow.shared.show() }
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "developerMode"), UserDefaults.standard.bool(forKey: "decisionTreeOpen") { DecisionTreeWindow.shared.show() }
    }

    @objc private func editRoutines() {
        // The status menu is still tracking when this runs: open on the next turn.
        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            self?.openSettings?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

}
