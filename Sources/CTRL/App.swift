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
        Task {
            let start = Date()
            do {
                let outcome = try await CommandRouter(client: TypeSafeClient(apiKey: key)).route(text)
                let ms = String(format: "(%.0f ms)", Date().timeIntervalSince(start) * 1000)
                if case .openApps(let p) = outcome {
                    print("outcome: open \(p.apps.map(\.name)) windows=\(p.windowsEach) layout=\(p.layout.rawValue) \(ms)")
                    if exec { await WindowManager.run(p); print("executed, AX trusted:", HotkeyMonitor.hasAccessibility) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCatalog.shared.reload()

        let panel = NotchPanel(rootView: NotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel

        hotkey.onBegin = { [weak self] in self?.model.begin() }
        hotkey.onEnd = { [weak self] in self?.model.end() }
        hotkey.onCancel = { [weak self] in self?.model.cancel() }
        hotkey.start()

        setUpMenu()

        if ProcessInfo.processInfo.environment["CTRL_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.model.runDemo() }
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set TypeSafe API Key…", action: #selector(setKey), keyEquivalent: "")
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

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
