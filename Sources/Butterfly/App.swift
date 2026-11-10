import AppKit
import EventKit
import Sparkle
import SwiftUI

@main
struct ButterflyMain {
    static func main() {
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
        let scenes = NSHostingSceneRepresentation {
            Settings { SettingsView() }
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
        hotkey.onEnd = { [weak self] in self?.model.end() }
        hotkey.onCancel = { [weak self] in self?.model.cancel() }
        hotkey.onLock = { [weak self] dictation in self?.model.lock(dictation: dictation) }
        hotkey.onUnlock = { [weak self] in self?.model.unlock() }
        hotkey.start()
        model.startObservers()

        setUpMenu()
        LoginItem.applyDefault()
        if let last = Self.lastRun { print(last) }

        if let app = ProcessInfo.processInfo.environment["BUTTERFLY_MEETING_PROMPT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Meetings.shared.simulateAsk(app) }
        }
        if let f = ProcessInfo.processInfo.environment["BUTTERFLY_TRANSCRIBE"] {   // re-run Gemini on this meeting folder
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Meetings.shared.retranscribeLast(folder: URL(fileURLWithPath: f)) }
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_RECORDING_STATES"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.recordingStatesDemo() }
        }
        if let say = ProcessInfo.processInfo.environment["BUTTERFLY_SAY"] {   // run the agent on this sentence, as if spoken
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.say(say) }
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
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        menu.addItem(.separator())
        recordItem = menu.addItem(withTitle: "Record Meeting", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(withTitle: "Meeting Notes", action: #selector(openMeetings), keyEquivalent: "")
        menu.delegate = self
        menu.addItem(.separator())
        let update = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        update.isHidden = !Updates.bundled
        menu.addItem(withTitle: "Quit Butterfly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) && i !== update { i.target = self }
        item.menu = menu
        statusItem = item
    }

    private var recordItem: NSMenuItem?

    @objc private func toggleRecording() { Meetings.shared.toggle() }
    @objc private func openMeetings() { Meetings.openFolder() }

    @objc private func openSettingsWindow() {
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

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        recordItem?.title = Meetings.shared.recordingApp.map { "Stop Recording · \($0)" } ?? "Record Meeting"
    }
}
