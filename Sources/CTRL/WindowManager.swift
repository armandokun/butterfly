import AppKit
import ApplicationServices

/// Launches apps, opens extra windows, and tiles windows via the Accessibility API.
@MainActor
enum WindowManager {
    enum Layout: String { case none, sideBySide = "side_by_side", stacked, maximize }

    struct Plan {
        var apps: [InstalledApp]
        var windowsEach: Int     // only used when one app
        var layout: Layout
    }

    static func run(_ plan: Plan) async {
        var targets: [AXUIElement] = []

        for app in plan.apps {
            let count = plan.apps.count == 1 ? plan.windowsEach : 1
            targets += await open(app, windows: count)
        }

        // Several windows of one app, no layout mentioned → tile them instead of stacking on top of each other.
        let layout = plan.layout == .none && plan.apps.count == 1 && targets.count > 1 ? .sideBySide : plan.layout
        guard layout != .none, !targets.isEmpty, let screen = NotchMetrics.screen ?? NSScreen.main else { return }
        tile(targets, layout: layout, in: screen.visibleFrame)
        if let last = plan.apps.last { activate(last) }
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
    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position → size → position again: some apps clamp size to the current screen edge.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
    }
}
