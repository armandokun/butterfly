import AppKit
import ApplicationServices

/// Reads the frontmost app's menu bar via Accessibility and presses items.
/// Lets Jev drive any app without per-app code: the menus ARE the options.
@MainActor
enum MenuReader {
    struct Item {
        let path: [String]       // ["File", "New Tab"]
        let shortcut: String?    // "⌘T"
        let element: AXUIElement
        var title: String { path.last ?? "" }
        var key: String { path.joined(separator: " > ") }
    }

    struct Snapshot {
        let app: NSRunningApplication
        let items: [Item]
    }

    /// Menus we never want to trigger by a fuzzy voice match.
    private static let skipTop: Set<String> = ["Apple", "Help"]
    private static let dangerous = ["quit", "log out", "shut down", "restart", "erase", "delete all", "empty trash", "force quit"]

    static func snapshot(of app: NSRunningApplication) -> Snapshot? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = attribute(ax, kAXMenuBarAttribute) else { return nil }
        var items: [Item] = []
        let tops: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        for (i, top) in tops.enumerated() {
            guard i > 0, let title: String = attribute(top, kAXTitleAttribute), !skipTop.contains(title) else { continue }
            walk(top, path: [title], depth: 0, into: &items)
        }
        return Snapshot(app: app, items: items)
    }

    private static func walk(_ el: AXUIElement, path: [String], depth: Int, into items: inout [Item]) {
        guard depth < 4, items.count < 1500 else { return }
        let children: [AXUIElement] = attribute(el, kAXChildrenAttribute) ?? []
        for child in children {
            let role: String? = attribute(child, kAXRoleAttribute)
            if role == kAXMenuRole as String { walk(child, path: path, depth: depth + 1, into: &items); continue }
            guard role == kAXMenuItemRole as String,
                  let title: String = attribute(child, kAXTitleAttribute), !title.isEmpty else { continue }
            let sub: [AXUIElement] = attribute(child, kAXChildrenAttribute) ?? []
            if !sub.isEmpty {
                walk(child, path: path + [title], depth: depth + 1, into: &items)
                continue
            }
            // Include disabled items: enabled state is often stale until the menu is opened.
            items.append(Item(path: path + [title], shortcut: shortcut(child), element: child))
        }
    }

    static func isDangerous(_ item: Item) -> Bool {
        let t = item.key.lowercased()
        return dangerous.contains { t.contains($0) }
    }

    /// Up to `limit` items, ranked by word overlap with the transcript.
    static func candidates(_ items: [Item], for transcript: String, limit: Int) -> [Item] {
        let words = Set(tokens(transcript))
        let scored = items.map { item -> (Item, Int) in
            let t = tokens(item.key)
            return (item, t.filter(words.contains).count * 3 + t.filter { w in words.contains { $0.count > 3 && w.hasPrefix($0.prefix(4)) } }.count)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Brings the app to front (menu actions act on its key window), waits until it really is, then presses.
    /// False when the press didn't go through.
    @discardableResult
    static func press(_ item: Item, in app: NSRunningApplication) async -> Bool {
        app.activate()
        for _ in 0..<25 where NSWorkspace.shared.frontmostApplication != app { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(120))   // key window settles
        let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        return r == .success
    }

    // MARK: AX helpers

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func shortcut(_ el: AXUIElement) -> String? {
        guard let ch: String = attribute(el, kAXMenuItemCmdCharAttribute), !ch.isEmpty else { return nil }
        let mods: Int = attribute(el, kAXMenuItemCmdModifiersAttribute) ?? 0
        var s = ""
        if mods & 4 != 0 { s += "⌃" }   // kAXMenuItemModifierControl
        if mods & 2 != 0 { s += "⌥" }   // Option
        if mods & 1 != 0 { s += "⇧" }   // Shift
        if mods & 8 == 0 { s += "⌘" }   // NoCommand flag not set
        return s + ch
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
