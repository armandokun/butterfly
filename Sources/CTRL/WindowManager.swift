import AppKit
import ApplicationServices

/// Launches apps, opens extra windows, and tiles windows via the Accessibility API.
@MainActor
enum WindowManager {
    enum Layout: String { case none, sideBySide = "side_by_side", stacked, maximize }

    enum Target: Hashable {
        case app(InstalledApp)
        case site(URL)
    }

    struct Plan {
        var targets: [Target]
        var windowsEach: Int     // only used for a single app
        var layout: Layout

        var apps: [InstalledApp] { targets.compactMap { if case .app(let a) = $0 { a } else { nil } } }
    }

    static func run(_ plan: Plan) async {
        var windows: [AXUIElement] = []
        let single = plan.targets.count == 1
        // One site, no layout → normal behavior: a new tab in your browser.
        let siteNeedsWindow = !single || plan.layout != .none

        for target in plan.targets {
            switch target {
            case .app(let app):
                windows += await open(app, windows: single ? plan.windowsEach : 1)
            case .site(let url):
                if siteNeedsWindow {
                    if let w = await openInNewWindow(url) { windows.append(w) }
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Several windows of one app, no layout mentioned → tile them instead of stacking on top of each other.
        let layout = plan.layout == .none && single && windows.count > 1 ? .sideBySide : plan.layout
        guard layout != .none, !windows.isEmpty, let screen = NotchMetrics.screen ?? NSScreen.main else { return }
        tile(windows, layout: layout, in: screen.visibleFrame)
    }

    // MARK: Websites

    /// Opens `url` in a fresh window of the default browser and returns that window.
    private static func openInNewWindow(_ url: URL) async -> AXUIElement? {
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: browserURL)?.bundleIdentifier else {
            NSWorkspace.shared.open(url); return nil
        }
        let browser = InstalledApp(name: browserURL.deletingPathExtension().lastPathComponent, url: browserURL)

        // Make sure it's running with its AX tree available, and remember the window count.
        let wasRunning = running(browser) != nil
        guard let app = try? await NSWorkspace.shared.openApplication(at: browserURL, configuration: activateConfig) else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        _ = await waitFor(timeout: 6) { app.isFinishedLaunching }
        if !wasRunning { _ = await waitFor(timeout: 3) { !windows(of: ax).isEmpty } }
        let before = windows(of: ax).count

        let link = url.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        switch bundle {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            runScript("tell application id \"\(bundle)\" to make new document with properties {URL:\"\(link)\"}", fallback: url)
        case _ where chromiumStyle.contains(bundle):
            runScript("""
            tell application id "\(bundle)"
                set w to make new window
                set URL of active tab of w to "\(link)"
            end tell
            """, fallback: url)
        default:
            // Firefox and others accept --new-window.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", browserURL.path, "--args", "--new-window", url.absoluteString]
            try? p.run()
        }

        // Only tile a window we actually created — never grab your existing one.
        guard await waitFor(timeout: 4, { windows(of: ax).count > before }) else { return nil }
        app.activate()
        return windows(of: ax).first   // newest is frontmost
    }

    /// Browsers with Chrome-style AppleScript: `make new window` + `active tab`.
    private static let chromiumStyle: Set<String> = [
        "company.thebrowser.dia", "company.thebrowser.Browser",   // Dia, Arc
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private static func runScript(_ source: String, fallback url: URL) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            print("AppleScript error:", error)
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Launch + windows

    /// Returns the AX windows created/used for this app, newest first.
    private static func open(_ app: InstalledApp, windows count: Int) async -> [AXUIElement] {
        let wasRunning = running(app) != nil
        guard let running = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: activateConfig) else { return [] }
        let ax = AXUIElementCreateApplication(running.processIdentifier)

        // Wait for the app to be frontmost with its first window (cold launches can take a few seconds).
        _ = await waitFor(timeout: 6) { running.isFinishedLaunching && running.isActive && !windows(of: ax).isEmpty }

        let existing = windows(of: ax).count
        let newNeeded = wasRunning ? (count > 1 ? count : 0) : max(0, count - existing)
        for _ in 0..<newNeeded {
            let before = windows(of: ax).count
            pressCommandN(for: running)
            _ = await waitFor(timeout: 2) { windows(of: ax).count > before }
        }
        // AX lists windows front-to-back (newest first); return oldest first so order reads left → right.
        return Array(windows(of: ax).prefix(max(count, 1)).reversed())
    }

    private static var activateConfig: NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        return c
    }

    private static func running(_ app: InstalledApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
    }

    private static func activate(_ app: InstalledApp) {
        running(app)?.activate()
    }

    private static func pressCommandN(for app: NSRunningApplication) {
        app.activate()
        let src = CGEventSource(stateID: .hidSystemState)
        let n: CGKeyCode = 45
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: n, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        // Skip panels/sheets: keep standard windows only.
        return list.filter { w in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &role)
            return (role as? String) == kAXStandardWindowSubrole as String
        }
    }

    private static func waitFor(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return condition()
    }

    // MARK: Tiling

    private static func tile(_ windows: [AXUIElement], layout: Layout, in area: CGRect) {
        let n = CGFloat(windows.count)
        for (i, w) in windows.enumerated() {   // spoken order, left → right
            let i = CGFloat(i)
            let frame: CGRect
            switch layout {
            case .sideBySide:
                frame = CGRect(x: area.minX + area.width / n * i, y: area.minY, width: area.width / n, height: area.height)
            case .stacked:
                frame = CGRect(x: area.minX, y: area.maxY - area.height / n * (i + 1), width: area.width, height: area.height / n)
            case .maximize, .none:
                frame = area
            }
            setFrame(w, frame)
        }
    }

    /// AX uses top-left origin relative to the primary screen.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Size → position → size: macOS clamps size when a move pushes the window past a screen edge.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
    }
}
