import AppKit
import ApplicationServices

/// What an app can do, learned from the app itself and kept per version: every menu item, every control in its
/// Settings window (walked tab by tab, nothing toggled), its AppleScript commands and URL schemes.
/// The planner gets only the entries that match the request, so "hide the Slack icon from the menu bar" comes with
/// `Settings > Advanced > Show Slack in menu bar (checkbox, on)` instead of a guess.
/// Saved to ~/Library/Application Support/CTRL/apps/<bundle id>.json.
@MainActor
final class AppMap {
    static let shared = AppMap()

    struct Entry: Codable {
        var kind: String      // menu | setting | script | url
        var path: String      // "Settings > Advanced > Show Slack in menu bar", "File > New Window"
        var role: String?     // checkbox, pop-up menu, button, text field…
        var value: String?    // current value when read (checkbox on/off, pop-up choice)
        var detail: String?   // shortcut, script syntax, url example
        var line: String {
            var s = path
            if let r = role { s += " (\(r)" + (value.map { ", \($0)" } ?? "") + ")" }
            if let d = detail, !d.isEmpty { s += " · \(d)" }
            return s
        }
    }

    struct Map: Codable {
        var bundleID: String
        var name: String
        var version: String
        var builtAt: Date
        var settingsCrawled: Bool
        var entries: [Entry]
    }

    private var cache: [String: Map] = [:]
    private var building: Set<String> = []
    static let folder = Vocabulary.fileURL.deletingLastPathComponent().appendingPathComponent("apps")

    private static func url(_ bundleID: String) -> URL { folder.appendingPathComponent(bundleID + ".json") }

    func map(for app: NSRunningApplication) -> Map? {
        guard let id = app.bundleIdentifier else { return nil }
        if let m = cache[id] { return m }
        guard let d = try? Data(contentsOf: Self.url(id)), let m = try? JSONDecoder().decode(Map.self, from: d) else { return nil }
        cache[id] = m
        return m
    }

    static func version(of app: NSRunningApplication) -> String {
        app.bundleURL.flatMap(Bundle.init).flatMap { $0.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
    }

    /// Up to date for this app version, settings included?
    func isCurrent(for app: NSRunningApplication) -> Bool {
        guard let m = map(for: app) else { return false }
        return m.version == Self.version(of: app) && m.settingsCrawled
    }

    /// Builds (or refreshes) the map. The settings crawl opens the app's Settings for a few seconds and closes it again.
    /// `progress` gets short status lines for the notch.
    func build(for app: NSRunningApplication, crawlSettings: Bool, progress: ((String) -> Void)? = nil) async -> Map? {
        guard let id = app.bundleIdentifier, !building.contains(id) else { return map(for: app) }
        building.insert(id); defer { building.remove(id) }
        let name = app.localizedName ?? id
        var entries: [Entry] = []

        progress?("menus")
        if let snap = MenuReader.snapshot(of: app) {
            for item in snap.items where item.path.count < 2 || item.path[1] != "Services" { entries.append(Entry(kind: "menu", path: item.key, role: nil, value: nil, detail: item.shortcut)) }
        }
        if let bundle = app.bundleURL.flatMap(Bundle.init) {
            for t in bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
                for s in t["CFBundleURLSchemes"] as? [String] ?? [] where !s.hasPrefix("com.") && !s.hasPrefix("x-") {
                    entries.append(Entry(kind: "url", path: "URL scheme \(s)://", role: nil, value: nil, detail: "open with open_url, e.g. \(s)://"))
                }
            }
            entries += await Self.scripting(bundle.bundleURL, name: name)
        }
        var crawled = false
        if crawlSettings {
            progress?("settings")
            let s = await Self.crawlSettings(of: app)
            entries += s.entries
            crawled = s.opened
        } else if let old = map(for: app), old.version == Self.version(of: app), old.settingsCrawled {
            entries += old.entries.filter { $0.kind == "setting" }   // keep what the last crawl found
            crawled = true
        }
        let m = Map(bundleID: id, name: name, version: Self.version(of: app), builtAt: Date(), settingsCrawled: crawled, entries: entries)
        cache[id] = m
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: Self.url(id), options: .atomic) }
        return m
    }

    // MARK: Search

    /// The entries most related to the request, as prompt lines.
    func relevant(_ request: String, in app: NSRunningApplication?, limit: Int = 14) -> [String] {
        guard let app, let m = map(for: app), !m.entries.isEmpty else { return [] }
        // The app's own name matches every menu ("Slack > Hide Slack"); it's not a signal.
        let words = Set(Self.tokens(request)).subtracting(Self.stop).subtracting(Self.tokens(m.name))
        guard !words.isEmpty else { return [] }
        let scored: [(Entry, Int)] = m.entries.map { e in
            if e.path.hasPrefix("\(m.name) > Services") { return (e, 0) }
            let t = Set(Self.tokens(e.line)).subtracting(Self.tokens(m.name))
            var score = t.filter(words.contains).count * 3
            score += t.filter { w in words.contains { $0.count > 3 && w.hasPrefix($0.prefix(4)) } }.count
            if e.kind == "setting" { score += 1 }   // the thing menus don't show
            return (e, score)
        }
        return scored.filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0.line)
    }

    nonisolated static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
    nonisolated static let stop: Set<String> = ["the", "and", "to", "in", "on", "of", "for", "me", "my", "it", "this", "that", "from", "can", "you", "please", "with", "an", "is", "at", "up", "do", "i"]

    // MARK: Scripting dictionary

    /// `sdef App.app` → command names and their syntax (only apps that are scriptable).
    nonisolated private static func scripting(_ bundle: URL, name: String) async -> [Entry] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
                p.arguments = [bundle.path]
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                guard (try? p.run()) != nil else { return cont.resume(returning: []) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0, let xml = try? XMLDocument(data: data) else { return cont.resume(returning: []) }
                var entries: [Entry] = []
                for suite in (try? xml.nodes(forXPath: "//suite")) as? [XMLElement] ?? [] {
                    let suiteName = suite.attribute(forName: "name")?.stringValue ?? ""
                    if ["Standard Suite", "Text Suite"].contains(suiteName) { continue }
                    for cmd in (try? suite.nodes(forXPath: "command")) as? [XMLElement] ?? [] {
                        guard let n = cmd.attribute(forName: "name")?.stringValue else { continue }
                        let params = ((try? cmd.nodes(forXPath: "parameter")) as? [XMLElement] ?? []).compactMap { $0.attribute(forName: "name")?.stringValue }
                        let desc = cmd.attribute(forName: "description")?.stringValue ?? ""
                        entries.append(Entry(kind: "script", path: "AppleScript: tell application \"\(name)\" to \(n)" + (params.isEmpty ? "" : " … " + params.joined(separator: " … ")),
                                             role: nil, value: nil, detail: desc.isEmpty ? nil : String(desc.prefix(100))))
                        if entries.count >= 120 { break }
                    }
                    for cls in (try? suite.nodes(forXPath: "class")) as? [XMLElement] ?? [] {
                        guard let n = cls.attribute(forName: "name")?.stringValue else { continue }
                        let props = ((try? cls.nodes(forXPath: "property")) as? [XMLElement] ?? []).compactMap { $0.attribute(forName: "name")?.stringValue }
                        guard !props.isEmpty else { continue }
                        entries.append(Entry(kind: "script", path: "AppleScript class \(n) of \"\(name)\"", role: nil, value: nil, detail: "properties: " + props.prefix(25).joined(separator: ", ")))
                    }
                }
                cont.resume(returning: entries)
            }
        }
    }

    // MARK: Settings crawl

    private static let controlRoles: [String: String] = [
        "AXCheckBox": "checkbox", "AXPopUpButton": "pop-up menu", "AXRadioButton": "option", "AXButton": "button",
        "AXTextField": "text field", "AXSlider": "slider", "AXComboBox": "combo box", "AXMenuButton": "menu button", "AXSwitch": "switch", "AXLink": "link",
    ]

    /// Opens Settings, presses each tab in turn and records the controls, then closes it. Never toggles a control.
    private static func crawlSettings(of app: NSRunningApplication) async -> (entries: [Entry], opened: Bool) {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.0)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let focusedBefore: AXUIElement? = Clicker.attr(ax, kAXFocusedWindowAttribute) ?? Clicker.attr(ax, kAXMainWindowAttribute)
        var before = windows(ax)
        if before.isEmpty, let f = focusedBefore { before = [f] }   // some apps answer AXWindows late/empty
        let beforeIDs = Set(before.map { CFHash($0) })
        let dbg = ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1"
        if dbg { print("  crawl: \(before.count) windows before, focused \(focusedBefore != nil)") }
        guard !before.isEmpty else { return ([], false) }   // no window to open settings from (closed to the menu bar)

        // Open: the app menu's Settings…/Preferences… item, else ⌘,
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
        var opened = false
        if let snap = MenuReader.snapshot(of: app),
           let item = snap.items.first(where: { $0.path.count == 2 && ($0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences")) }) {
            opened = await MenuReader.press(item, in: app)
        }
        if !opened { Keys.press(43, flags: .maskCommand); opened = true }   // ⌘,
        if dbg { print("  crawl: opened via menu item: \(opened)") }

        // Wait for a new window, or (Electron: Slack, Discord) a dialog inside the existing one.
        var root: AXUIElement?
        var newWindow = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(150))
            if let w = windows(ax).first(where: { !beforeIDs.contains(CFHash($0)) }) { root = w; newWindow = true; break }
            if let f: AXUIElement = Clicker.attr(ax, kAXFocusedWindowAttribute) {
                if !beforeIDs.contains(CFHash(f)), isSettingsWindow(f) { root = f; newWindow = true; break }
                if let d = dialog(in: f) { root = d; break }
            }
        }
        if dbg { print("  crawl: root \(root == nil ? "not found" : newWindow ? "new window" : "dialog"), windows now \(windows(ax).count)") }
        guard let root else { return ([], false) }
        try? await Task.sleep(for: .milliseconds(400))

        var entries: [Entry] = []
        var seen = Set<String>()
        let tabs = tabCandidates(in: root)
        let tabNames = Set(tabs.map(\.label))
        func record(tab: String?) {
            for c in controls(in: root) where !tabNames.contains(c.label) || c.role == "checkbox" {
                let path = (["Settings", tab, c.label].compactMap { $0 }).joined(separator: " > ")
                guard seen.insert(path).inserted else { continue }
                entries.append(Entry(kind: "setting", path: path, role: c.role, value: c.value, detail: nil))
            }
        }
        if dbg { print("  crawl: tabs:", tabs.map(\.label)) }
        if tabs.isEmpty { record(tab: nil) }
        for t in tabs.prefix(24) {
            guard Self.isAlive(app) else { break }
            AXUIElementPerformAction(t.element, kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(350))
            record(tab: t.label)
        }

        // Close what we opened: the window's close button, else the dialog's own Close/Done button, else Escape, else ⌘W.
        func stillOpen() -> Bool {
            if newWindow { return windows(ax).contains { !beforeIDs.contains(CFHash($0)) } }
            guard let f: AXUIElement = Clicker.attr(ax, kAXFocusedWindowAttribute) else { return false }
            return dialog(in: f) != nil
        }
        if newWindow, let close: AXUIElement = Clicker.attr(root, kAXCloseButtonAttribute) { AXUIElementPerformAction(close, kAXPressAction as CFString) }
        else if let close = controls(in: root).first(where: { $0.role == "button" && ["close", "done", "×", "x"].contains($0.label.lowercased()) }) {
            AXUIElementPerformAction(close.element, kAXPressAction as CFString)
        }
        try? await Task.sleep(for: .milliseconds(350))
        if stillOpen() { app.activate(); try? await Task.sleep(for: .milliseconds(120)); Keys.press(53, flags: []); try? await Task.sleep(for: .milliseconds(350)) }   // Escape
        if stillOpen(), newWindow { Keys.press(13, flags: .maskCommand) }   // ⌘W
        if dbg { print("  crawl: closed: \(!stillOpen())") }
        if let f = focusedBefore { AXUIElementPerformAction(f, kAXRaiseAction as CFString) }

        // Chrome that shows on every pane (sidebar links, search field, close button) is kept once, without a pane.
        if tabs.count >= 3 {
            var byLabel: [String: Int] = [:]
            for e in entries { byLabel[e.path.components(separatedBy: " > ").last ?? "", default: 0] += 1 }
            var kept: [Entry] = []
            var once = Set<String>()
            for e in entries {
                let label = e.path.components(separatedBy: " > ").last ?? ""
                if byLabel[label, default: 0] >= 3 {
                    if once.insert(label).inserted, !tabNames.contains(label) { kept.append(Entry(kind: e.kind, path: "Settings > \(label)", role: e.role, value: e.value, detail: nil)) }
                } else { kept.append(e) }
            }
            entries = kept
        }
        return (entries, true)
    }

    private static func isAlive(_ app: NSRunningApplication) -> Bool { !app.isTerminated }

    private static func isSettingsWindow(_ w: AXUIElement) -> Bool {
        let title: String = Clicker.attr(w, kAXTitleAttribute) ?? ""
        let sub: String = Clicker.attr(w, kAXSubroleAttribute) ?? ""
        return title.localizedCaseInsensitiveContains("settings") || title.localizedCaseInsensitiveContains("preferences") || sub == "AXDialog" || sub == "AXSystemDialog"
            || (Clicker.attr(w, "AXToolbar") as AXUIElement?) != nil
    }

    private static func windows(_ ax: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success, let arr = v, CFGetTypeID(arr) == CFArrayGetTypeID() else { return [] }
        let cf = arr as! CFArray
        return (0..<CFArrayGetCount(cf)).map { unsafeBitCast(CFArrayGetValueAtIndex(cf, $0), to: AXUIElement.self) }
    }

    /// Electron apps show Settings as a dialog/modal group inside the main window.
    private static func dialog(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard found == nil, depth < 12, visited < 600 else { return }
            visited += 1
            let role: String = Clicker.attr(el, kAXRoleAttribute) ?? ""
            let sub: String = Clicker.attr(el, kAXSubroleAttribute) ?? ""
            if role == "AXSheet" || role == "AXDialog" || sub == "AXDialog" || sub == "AXApplicationDialog" { found = el; return }
            let kids: [AXUIElement] = Clicker.attr(el, kAXChildrenAttribute) ?? []
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }

    struct Control { let label: String; let role: String; let value: String?; let element: AXUIElement }

    /// Tabs / sidebar entries of a settings window: toolbar buttons, tab groups, and any column of links/buttons/rows down the left edge
    /// (Electron apps like Discord and Slack draw their settings sidebar that way).
    private static func tabCandidates(in root: AXUIElement) -> [Control] {
        guard let rf = Clicker.frame(of: root) else { return [] }
        var out: [Control] = []
        var column: [(Control, CGRect)] = []
        var visited = 0
        let skip = ["log out", "sign out", "logout", "delete", "quit", "exit", "remove account", "deactivate", "privacy policy", "terms", "learn more", "help", "support", "feedback",
                    "what's new", "release notes", "upgrade", "subscribe", "buy", "gift", "invite", "download", "edit profile", "close"]
        func walk(_ el: AXUIElement, depth: Int, inToolbar: Bool, inTabs: Bool) {
            guard depth < 18, visited < 2500, out.count < 40 else { return }
            visited += 1
            let role: String = Clicker.attr(el, kAXRoleAttribute) ?? ""
            let sub: String = Clicker.attr(el, kAXSubroleAttribute) ?? ""
            let label = ["AXTab", "AXRadioButton", "AXButton", "AXLink", "AXRow", "AXCell"].contains(role) ? Clicker.label(of: el, role: role) : ""
            // Links that leave the app (privacy policy, help centre) carry a URL: never press those.
            let external = role == "AXLink" && (Clicker.attr(el, kAXURLAttribute) as URL?) != nil
            let ok = !label.isEmpty && label.count < 40 && !external && !skip.contains { label.lowercased().contains($0) }
            let isTab = role == "AXTab" || sub == "AXTabButton" || (role == "AXRadioButton" && (inToolbar || inTabs)) || (role == "AXButton" && inToolbar)
            if isTab, ok, !out.contains(where: { $0.label == label }) { out.append(Control(label: label, role: role, value: nil, element: el)); return }
            if ok, let f = Clicker.frame(of: el), f.minX < rf.minX + rf.width * 0.35, f.height < 60, f.width < rf.width * 0.4 {
                column.append((Control(label: label, role: role, value: nil, element: el), f))
                if role != "AXRow" && role != "AXCell" { return }
            }
            let kids: [AXUIElement] = Clicker.attr(el, kAXChildrenAttribute) ?? []
            for k in kids { walk(k, depth: depth + 1, inToolbar: inToolbar || role == "AXToolbar", inTabs: inTabs || role == "AXTabGroup") }
        }
        walk(root, depth: 0, inToolbar: false, inTabs: false)
        if !out.isEmpty { return out }
        // Left column: ≥4 items sharing the same left edge, stacked vertically.
        var best: [(Control, CGRect)] = []
        for (_, f) in column {
            let group = column.filter { abs($0.1.minX - f.minX) < 10 }
            if group.count > best.count { best = group }
        }
        guard best.count >= 4 else { return [] }
        var seen = Set<String>()
        return best.sorted { $0.1.minY < $1.1.minY }.compactMap { seen.insert($0.0.label).inserted ? $0.0 : nil }
    }

    /// Every labelled control under `root`, with its current value.
    private static func controls(in root: AXUIElement) -> [Control] {
        var out: [Control] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(1.2)
        func walk(_ el: AXUIElement, depth: Int, context: String) {
            guard depth < 30, visited < 2500, out.count < 300, Date() < deadline else { return }
            visited += 1
            let role: String = Clicker.attr(el, kAXRoleAttribute) ?? ""
            var ctx = context
            if role == "AXGroup" || role == "AXStaticText", let t: String = Clicker.attr(el, kAXTitleAttribute) ?? Clicker.attr(el, kAXValueAttribute), (3...60).contains(t.count) { ctx = t }
            if let name = controlRoles[role] {
                var label = Clicker.label(of: el, role: role)
                if label.isEmpty || role == "AXPopUpButton" || role == "AXSlider" || role == "AXTextField" || role == "AXComboBox" {
                    // Pop-ups, sliders and fields carry their caption in a separate text ("Dock unread count:").
                    if let t: AXUIElement = Clicker.attr(el, kAXTitleUIElementAttribute) {
                        let cap = Clicker.label(of: t, role: "AXStaticText").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                        if !cap.isEmpty { label = label.isEmpty ? cap : "\(cap): \(label)" }
                    }
                }
                if label.isEmpty, (role == "AXPopUpButton" || role == "AXSlider" || role == "AXTextField" || role == "AXComboBox"), !context.isEmpty { label = context }
                if label.isEmpty, role == "AXCheckBox" || role == "AXSwitch", !context.isEmpty { label = context }   // Electron: the text sits next to the switch
                if !label.isEmpty, label.count < 90 {
                    var value: String?
                    if role == "AXCheckBox" || role == "AXSwitch" || role == "AXRadioButton" {
                        if let v: Int = Clicker.attr(el, kAXValueAttribute) { value = v == 1 ? "on" : "off" }
                        else if let v: Bool = Clicker.attr(el, kAXValueAttribute) { value = v ? "on" : "off" }
                    } else if role == "AXPopUpButton" || role == "AXComboBox", let v: String = Clicker.attr(el, kAXValueAttribute), !v.isEmpty { value = String(v.prefix(40)) }
                    out.append(Control(label: label, role: name, value: value, element: el))
                    if role == "AXButton" || role == "AXLink" { return }
                }
            }
            let kids: [AXUIElement] = Clicker.attr(el, kAXChildrenAttribute) ?? []
            // "Unread count:" sits beside its pop-up as a sibling text: remember the last caption and hand it to the next unlabeled control on the same row.
            var caption: (String, CGRect)?
            for k in kids {
                let kr: String = Clicker.attr(k, kAXRoleAttribute) ?? ""
                if kr == "AXStaticText", let t: String = Clicker.attr(k, kAXValueAttribute), (2...70).contains(t.count), let f = Clicker.frame(of: k) {
                    caption = (t.trimmingCharacters(in: CharacterSet(charactersIn: ": ")), f)
                    continue
                }
                var kctx = ctx
                if let c = caption, let f = Clicker.frame(of: k), abs(c.1.midY - f.midY) < 14 || kr == "AXCheckBox" || kr == "AXSwitch" { kctx = c.0 }
                walk(k, depth: depth + 1, context: kctx)
            }
        }
        walk(root, depth: 0, context: "")
        return out
    }
}
