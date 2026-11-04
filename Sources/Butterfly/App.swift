import AppKit
import EventKit
import Sparkle
import SwiftUI

@main
struct ButterflyMain {
    static func main() {
        // Debug flags (`--plan`, `--route`, `--skills`, …) run without the app: they print and exit.
        if CLI.run(CommandLine.arguments) { RunLoop.main.run(); return }
        AppDelegate.lastRun = CrashReporter.install()
        Migration.run()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var lastRun: String?   // CrashReporter's note about the previous run
    private let model = NotchModel()
    private let hotkey = HotkeyMonitor()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var openSettings: (() -> Void)?
    private var scenes: AnyObject?   // keep the Settings scene alive
    private let updater = Updates.controller

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apple's Settings scene (WWDC26 "Use SwiftUI with AppKit"): standard pane toolbar, title, dimmed buttons.
        let model = self.model
        let scenes = NSHostingSceneRepresentation {
            Settings { SettingsView(run: { model.run($0) }) }
        }
        NSApplication.shared.addSceneRepresentation(scenes)
        self.scenes = scenes
        // While Settings is open Butterfly is a normal app (Dock icon), so macOS brings you to it,
        // even from a full-screen app. Closing it goes back to menu-bar-only.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue.contains("Settings") == true else { return }
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }
        openSettings = { scenes.environment.openSettings() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] == "1" { setlinebuf(stdout) }
        AudioOutput.warm()
        if Installer.offerMoveToApplications() { return }
        AppCatalog.shared.reload()
        ScreenMemory.shared.start()

        let panel = NotchPanel(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        model.onScreenChange = { [weak self] in self?.panel?.reposition() }
        model.onInteractive = { [weak self] on in self?.panel?.setInteractive(on) }
        panel.onHover = { [weak self] over in self?.model.hover(over) }
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
        if let last = Self.lastRun { print(last) }
        if CommandLine.arguments.contains("--routines") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.editRoutines() } }

        if let b = ProcessInfo.processInfo.environment["BUTTERFLY_BADGE"]?.split(separator: "|").map(String.init), b.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.badge(symbol: b[0], text: b[1], tint: .green), for: 4) }
        }
        if let a = ProcessInfo.processInfo.environment["BUTTERFLY_SYSTEM"]?.split(separator: "|").map(String.init), a.count == 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.system(symbol: a[0], title: a[1], detail: a[2]), for: 8) }
        }
        if let a = ProcessInfo.processInfo.environment["BUTTERFLY_ANSWER"]?.split(separator: "|").map(String.init), a.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.ambient(.answer(title: a[0], text: a[1].replacingOccurrences(of: "\\n", with: "\n")), for: 6) }
        }
        if let s = ProcessInfo.processInfo.environment["BUTTERFLY_TIMER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = Timers.shared.start(s) }
        }
        if let lines = ProcessInfo.processInfo.environment["BUTTERFLY_SPEAK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.model.speakTest(lines.components(separatedBy: "|")) }
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_PTT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.model.pttTest() }
        }
        if let say = ProcessInfo.processInfo.environment["BUTTERFLY_SAY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.say(say.components(separatedBy: "|")) }
        }
        if let app = ProcessInfo.processInfo.environment["BUTTERFLY_MEETING_PROMPT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Meetings.shared.simulateAsk(app) }
        }
        if let lines = ProcessInfo.processInfo.environment["BUTTERFLY_CLEAN"] {   // show how spoken text is tidied before typing
            for l in lines.components(separatedBy: "|") { print("“\(l)” → “\(Typer.clean(l))”") }; exit(0)
        }
        if let lines = ProcessInfo.processInfo.environment["BUTTERFLY_SEARCH"] {   // how search phrases parse: site + query + URL
            for l in lines.components(separatedBy: "|") { print("“\(l)” →", WebSearch.parse(l).map { "\($0.engine): “\($0.query)” \($0.url)" } ?? "nil") }; exit(0)
        }
        if let lines = ProcessInfo.processInfo.environment["BUTTERFLY_SPLIT"] {   // print how sentences split into steps, then quit
            Task { for l in lines.components(separatedBy: "|") { print("“\(l)” →", await StepSplitter.split(l)) }; exit(0) }
        }
        if let f = ProcessInfo.processInfo.environment["BUTTERFLY_TRANSCRIBE"] {   // re-run Gemini on this meeting folder
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Meetings.shared.retranscribeLast(folder: URL(fileURLWithPath: f)) }
        }
        if let m = ProcessInfo.processInfo.environment["BUTTERFLY_RECORDING_AT"].flatMap(Double.init) {   // minutes in: the recording pill alone
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.recording = NotchModel.Recording(app: "Demo", since: Date().addingTimeInterval(-m * 60)) }
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_RECORDING_STATES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.recordingStatesDemo() }
        }
        // BUTTERFLY_TRANSCRIPT_READY=1: the "Transcript ready" card for the newest meeting.
        if ProcessInfo.processInfo.environment["BUTTERFLY_TRANSCRIPT_READY"] == "1",
           let last = (try? FileManager.default.contentsOfDirectory(at: Meetings.root, includingPropertiesForKeys: nil))?.max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.model.notify(.transcriptReady(title: String(last.lastPathComponent.dropFirst(17)), file: last.appendingPathComponent("transcript.md")), for: 12)
            }
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_GALLERY"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runGallery() }
            return
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runDemo() }
            return
        }
        if let path = ProcessInfo.processInfo.environment["BUTTERFLY_LOCKTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.lockTest(path) }
            return
        }
        if let s = ProcessInfo.processInfo.environment["BUTTERFLY_MARKTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.markTest(s) }
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
        glyph?.size = .init(width: 19, height: 19)   // fills the menu bar height so the thin script line reads
        item.button?.image = glyph
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(editRoutines), keyEquivalent: ",")
        menu.addItem(.separator())
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        update.isHidden = !Updates.bundled
        menu.addItem(withTitle: "Quit Butterfly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) && i !== update { i.target = self }
        item.menu = menu
        statusItem = item
        watchDeveloperMode()
    }

    private var developerObserver: NSObjectProtocol?

    /// Developer mode on/off: close the decision tree when it goes off, open it the first time it goes on.
    private func watchDeveloperMode() {
        // Fires for any defaults change, even mid-layout (AppKit registers defaults while SwiftUI draws Settings):
        // act only when the toggle really flips, and after the current layout pass, or SwiftUI aborts.
        var last = UserDefaults.standard.bool(forKey: "developerMode")
        developerObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let on = UserDefaults.standard.bool(forKey: "developerMode")
                    guard on != last else { return }
                    last = on
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
