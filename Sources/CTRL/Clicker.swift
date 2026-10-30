import AppKit
import ApplicationServices
import ScreenCaptureKit

/// "Click the send button".
/// 1. Accessibility: the window's own buttons/links are the options (exact, no screenshot).
/// 2. Fallback: screenshot the window, Jev's Box question finds the spot, we click its center.
@MainActor
enum Clicker {
    struct Element {
        let label: String
        let role: String
        let element: AXUIElement
        let frame: CGRect   // global, top-left origin
    }

    private static let clickable: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXMenuButton", "AXPopUpButton",
        "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXStaticText", "AXImage", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXList",   // labeled lists: Calendar month-view day cells ("Tuesday, 27 October")
    ]
    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "option", "AXSwitch": "switch",
        "AXMenuButton": "menu button", "AXPopUpButton": "pop-up menu", "AXTab": "tab", "AXDisclosureTriangle": "disclosure arrow",
        "AXCell": "list item", "AXRow": "row", "AXStaticText": "text", "AXImage": "image",
        "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box", "AXSearchField": "search field",
        "AXList": "day cell / list",
    ]

    /// Read clickable things in the app's focused window (and its toolbar). Bounded for speed.
    static func elements(of app: NSRunningApplication) -> [Element] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        // Chromium/Electron apps (Dia, Slack, Cursor) only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = attr(ax, kAXFocusedWindowAttribute) ?? attr(ax, kAXMainWindowAttribute) else { return [] }
        var out: [Element] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(0.6)
        let winFrame = frame(of: window) ?? .infinite
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 40, visited < 4000, out.count < 400, Date() < deadline else { return }
            visited += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            if clickable.contains(role), let f = frame(of: el), f.width > 2, f.height > 2, winFrame.intersects(f) {
                let label = label(of: el, role: role)
                if !label.isEmpty, label.count < 120 { out.append(Element(label: label, role: role, element: el, frame: f)) }
            }
            // Static text inside a button is the button's label; don't descend into it again.
            if role == "AXButton" || role == "AXLink" { if !(label(of: el, role: role).isEmpty) { return } }
            let kids: [AXUIElement] = attr(el, kAXVisibleChildrenAttribute) ?? attr(el, kAXChildrenAttribute) ?? []
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return out
    }

    /// Choice options for Jev, ranked by overlap with what was said.
    static func options(_ els: [Element], for transcript: String, limit: Int = 200) -> [String: (String, Element)] {
        // "27th" → "27" so spoken dates match "27 October".
        let words = Set(transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map {
            String($0).replacingOccurrences(of: #"^(\d+)(st|nd|rd|th)$"#, with: "$1", options: .regularExpression)
        })
        let filler: Set<String> = ["click", "press", "tap", "open", "select", "choose", "on", "the", "a", "an", "to", "in", "of", "at", "and", "for", "it", "this", "that", "please", "button", "can", "you"]
        let ranked = els.enumerated().sorted { a, b in
            func score(_ e: Element) -> Int {
                let t = Set(e.label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                return t.filter { words.contains($0) && !filler.contains($0) }.count * 3 + (e.role == "AXButton" || e.role == "AXLink" ? 1 : 0)
            }
            // Tie → the tighter label ("Tuesday, 27 October" beats an event that merely mentions the date).
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.element.label.count < b.element.label.count
        }
        var out: [String: (String, Element)] = [:]
        for (i, e) in ranked.prefix(limit) {
            let key = "e\(i)"
            out[key] = ("the \(roleNames[e.role] ?? "element") labeled “\(e.label)”", e)
        }
        return out
    }

    /// The element a "click <label>" step means, and its on/off state when it's a toggle (nil for buttons, links…).
    /// Read before and after a click so the planner can tell whether a toggle really flipped.
    static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch"]
    static func toggleState(label: String, in app: NSRunningApplication?) -> (found: Bool, value: Int?) {
        guard let app else { return (false, nil) }
        let els = elements(of: app)
        let want = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !want.isEmpty else { return (false, nil) }
        func fits(_ e: Element) -> Bool { let l = e.label.lowercased(); return l == want || l.contains(want) || want.contains(l) }
        // The switch itself over the caption next to it (SwiftUI exposes both with the same label).
        let el = els.first { toggleRoles.contains($0.role) && $0.label.lowercased() == want }
            ?? els.first { toggleRoles.contains($0.role) && fits($0) }
            ?? els.first { $0.label.lowercased() == want }
            ?? els.first(where: fits)
        guard let el else { return (false, nil) }
        guard toggleRoles.contains(el.role) else { return (true, nil) }
        let v: NSNumber? = attr(el.element, kAXValueAttribute)
        return (true, v?.intValue)
    }

    static func press(_ e: Element) {
        RunVideo.shared.ring(at: CGPoint(x: e.frame.midX, y: e.frame.midY))
        let actions: [String] = {
            var names: CFArray?
            AXUIElementCopyActionNames(e.element, &names)
            return (names as? [String]) ?? []
        }()
        // Text fields / rows / text have no reliable press: click their center like a person would.
        // A day cell's middle is covered by its events: click the empty date strip at the top.
        if e.role == "AXList" { click(at: CGPoint(x: e.frame.midX, y: e.frame.minY + 8)); return }
        if actions.contains(kAXPressAction as String), !["AXTextField", "AXTextArea", "AXStaticText", "AXCell", "AXRow", "AXImage", "AXSearchField", "AXComboBox"].contains(e.role) {
            AXUIElementPerformAction(e.element, kAXPressAction as CFString)
        } else {
            click(at: CGPoint(x: e.frame.midX, y: e.frame.midY))
        }
    }

    // MARK: Desktop widgets

    /// Desktop widgets live in Notification Centre's AX tree, not the front app's: one AXWindow per widget,
    /// holding an AXGroup titled with the app name ("Weather") and its labeled items.
    struct Widget {
        let app: String          // "Weather", "Calendar", "Things"
        let title: String        // window title: "Up Next", "List", "com.apple.weather::…"
        let group: Element
        let items: [Element]
    }

    static func widgets() -> [Widget] {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return [] }
        let ax = AXUIElementCreateApplication(nc.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        let wins: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        // Window → hosting view → titled group.
        func group(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
            guard d < 3 else { return nil }
            for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if (attr(k, kAXRoleAttribute) as String?) == "AXGroup", !label(of: k, role: "AXGroup").isEmpty { return k }
                if let g = group(k, d + 1) { return g }
            }
            return nil
        }
        func items(_ el: AXUIElement, _ d: Int, into out: inout [Element]) {
            guard d < 8, out.count < 40 else { return }
            for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                let role: String = attr(k, kAXRoleAttribute) ?? ""
                let l = label(of: k, role: role).replacingOccurrences(of: "Symbol-Checkbox, ", with: "")
                if ["AXButton", "AXCheckBox", "AXUnknown", "AXLink", "AXStaticText"].contains(role), !l.isEmpty, let kf = frame(of: k), kf.width > 1 {
                    out.append(Element(label: l, role: role, element: k, frame: kf))
                }
                items(k, d + 1, into: &out)
            }
        }
        var out: [Widget] = []
        for w in wins {
            guard let g = group(w, 0), let f = frame(of: g), f.width > 20 else { continue }
            let name = label(of: g, role: "AXGroup")
            var kids: [Element] = []
            items(g, 0, into: &kids)
            out.append(Widget(app: name, title: attr(w, kAXTitleAttribute) ?? "", group: Element(label: name + " widget", role: "AXGroup", element: g, frame: f), items: kids))
        }
        return out
    }

    private static let widgetFiller: Set<String> = ["open", "click", "press", "tap", "select", "show", "check", "uncheck", "tick", "the", "a", "an", "my",
        "on", "in", "at", "to", "of", "and", "me", "please", "widget", "widgets", "desktop", "item", "event", "one", "that", "this"]
    private static func tokens(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The widget (or an item inside one) that the spoken text names. App name beats item text.
    /// `requireName`: only when a widget's app is named (used when "widget" wasn't said).
    static func widgetTarget(for spoken: String, in list: [Widget]? = nil, requireName: Bool = false) -> Element? {
        let all = list ?? widgets()
        let said = tokens(spoken)
        let saidSet = Set(said)
        // "weather" in the app name, or the bundle id in the window title ("com.apple.weather::…").
        func names(_ w: Widget) -> Bool {
            let app = tokens(w.app)
            if !app.isEmpty, app.allSatisfy(saidSet.contains) { return true }
            guard w.title.contains(".") else { return false }   // "Up Next" / "List" are too generic
            let t = Set(tokens(w.title.components(separatedBy: "::").first ?? "")).subtracting(["com", "apple", "widget"])
            return !t.isEmpty && t.allSatisfy(saidSet.contains)
        }
        let named = all.filter(names)
        if requireName, named.isEmpty { return nil }
        let nameWords = Set(named.flatMap { tokens($0.app) + tokens($0.title) })
        let content = Set(said.filter { $0.count >= 3 && !widgetFiller.contains($0) && !nameWords.contains($0) })
        // A specific item ("check the rentgen one"): only when real words beyond the widget's name match it.
        if !content.isEmpty {
            let pool = (named.isEmpty ? all : named).flatMap(\.items)
            let scored = pool.map { e in (e, Set(tokens(e.label)).intersection(content).count) }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= min(2, content.count) { return best.0 }
        }
        return named.first?.group
    }

    // MARK: Screenshot + Box fallback

    struct Shot { let jpeg: Data; let frame: CGRect; let display: CGDirectDisplayID }   // frame: global, top-left origin

    /// Sharper shot of one region (global, top-left origin) for a second, zoomed-in Box.
    static func screenshot(region: CGRect, display id: CGDirectDisplayID) async throws -> Shot? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let bounds = CGDisplayBounds(id)
        let r = region.intersection(bounds)
        guard r.width > 10, r.height > 10 else { return nil }
        let config = SCStreamConfiguration()
        config.sourceRect = r.offsetBy(dx: -bounds.minX, dy: -bounds.minY)   // display-local points
        let scale = min(1024 / max(r.width, r.height), 3)
        config.width = Int(r.width * scale)
        config.height = Int(r.height * scale)
        config.showsCursor = false
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { try? jpeg.write(to: URL(fileURLWithPath: "/tmp/ctrl-zoom.jpg")) }
        return Shot(jpeg: jpeg, frame: r, display: id)
    }

    /// The box as a global rect.
    static func rect(in shot: Shot, box b: TypeSafeClient.BoxAnswer.Edges) -> CGRect {
        CGRect(x: shot.frame.minX + b.left * shot.frame.width, y: shot.frame.minY + b.top * shot.frame.height,
               width: (b.right - b.left) * shot.frame.width, height: (b.bottom - b.top) * shot.frame.height)
    }

    /// Screenshot of the whole display the app is on (needs Screen Recording permission).
    /// Whole screen, not just the window: widgets, the Dock, menu bar, and other windows count too.
    static func screenshot(of app: NSRunningApplication) async throws -> Shot? {
        try await screenshots(of: app).first
    }

    /// Every display, most likely first: the screen of your last action (past 2 min), else under the mouse, else the app's.
    static func screenshots(of app: NSRunningApplication) async throws -> [Shot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let appWindow = content.windows.first { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 100 }
        let appDisplay = appWindow.flatMap { Memory.display(at: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let preferred = Memory.lastDisplay ?? Memory.displayUnderMouse ?? appDisplay
        let displays = content.displays.sorted { a, _ in a.displayID == preferred }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var shots: [Shot] = []
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)   // global, top-left origin
            let config = SCStreamConfiguration()
            let scale = min(1568 / max(bounds.width, bounds.height), 2)
            config.width = max(280, Int(bounds.width * scale))
            config.height = max(280, Int(bounds.height * scale))
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { continue }
            if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { try? jpeg.write(to: URL(fileURLWithPath: "/tmp/ctrl-shot-\(shots.count).jpg")) }
            shots.append(Shot(jpeg: jpeg, frame: bounds, display: display.displayID))
        }
        return shots
    }

    static func point(in shot: Shot, box b: TypeSafeClient.BoxAnswer.Edges) -> CGPoint {
        CGPoint(x: shot.frame.minX + (b.left + b.right) / 2 * shot.frame.width,
                y: shot.frame.minY + (b.top + b.bottom) / 2 * shot.frame.height)
    }

    /// Real mouse click at a global (top-left origin) point; puts the cursor back afterwards.
    static func click(at p: CGPoint) {
        RunVideo.shared.ring(at: p)
        let back = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let back {
            usleep(60_000)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: AX helpers

    static func label(of el: AXUIElement, role: String) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let s: String = attr(el, key), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if role == "AXStaticText" || role == "AXCell" || role == "AXRow" {
            if let s: String = attr(el, kAXValueAttribute) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // Buttons often carry their label in a child text.
        if role == "AXButton" || role == "AXLink" || role == "AXCell" || role == "AXRow" {
            let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
            for k in kids.prefix(4) {
                if let s: String = attr(k, kAXValueAttribute) ?? attr(k, kAXTitleAttribute), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        return ""
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self {
            guard CFGetTypeID(v) == (T.self == AXUIElement.self ? AXUIElementGetTypeID() : AXValueGetTypeID()) else { return nil }
            return (v as! T)
        }
        return v as? T
    }
}

extension NSEvent {
    /// Mouse position in global top-left-origin coordinates (CG/AX style).
    static var mouseLocationTopLeft: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
