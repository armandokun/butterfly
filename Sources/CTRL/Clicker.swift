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
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
        "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow", "AXStaticText", "AXImage", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "option",
        "AXMenuButton": "menu button", "AXPopUpButton": "pop-up menu", "AXTab": "tab", "AXDisclosureTriangle": "disclosure arrow",
        "AXCell": "list item", "AXRow": "row", "AXStaticText": "text", "AXImage": "image",
        "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box", "AXSearchField": "search field",
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
        let words = Set(transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let ranked = els.enumerated().sorted { a, b in
            func score(_ e: Element) -> Int {
                let t = e.label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                return t.filter(words.contains).count * 3 + (e.role == "AXButton" || e.role == "AXLink" ? 1 : 0)
            }
            return score(a.element) > score(b.element)
        }
        var out: [String: (String, Element)] = [:]
        for (i, e) in ranked.prefix(limit) {
            let key = "e\(i)"
            out[key] = ("the \(roleNames[e.role] ?? "element") labeled “\(e.label)”", e)
        }
        return out
    }

    static func press(_ e: Element) {
        let actions: [String] = {
            var names: CFArray?
            AXUIElementCopyActionNames(e.element, &names)
            return (names as? [String]) ?? []
        }()
        // Text fields / rows / text have no reliable press: click their center like a person would.
        if actions.contains(kAXPressAction as String), !["AXTextField", "AXTextArea", "AXStaticText", "AXCell", "AXRow", "AXImage", "AXSearchField", "AXComboBox"].contains(e.role) {
            AXUIElementPerformAction(e.element, kAXPressAction as CFString)
        } else {
            click(at: CGPoint(x: e.frame.midX, y: e.frame.midY))
        }
    }

    // MARK: Screenshot + Box fallback

    struct Shot { let jpeg: Data; let frame: CGRect }   // frame: global, top-left origin

    /// Screenshot of the app's front window (needs Screen Recording permission).
    static func screenshot(of app: NSRunningApplication) async throws -> Shot? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let win = content.windows
            .filter({ $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 })
            .first   // front-to-back order
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(1568 / max(win.frame.width, win.frame.height), 2)
        config.width = max(280, Int(win.frame.width * scale))
        config.height = max(280, Int(win.frame.height * scale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return Shot(jpeg: jpeg, frame: win.frame)
    }

    static func point(in shot: Shot, box b: TypeSafeClient.BoxAnswer.Edges) -> CGPoint {
        CGPoint(x: shot.frame.minX + (b.left + b.right) / 2 * shot.frame.width,
                y: shot.frame.minY + (b.top + b.bottom) / 2 * shot.frame.height)
    }

    /// Real mouse click at a global (top-left origin) point; puts the cursor back afterwards.
    static func click(at p: CGPoint) {
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

    private static func label(of el: AXUIElement, role: String) -> String {
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

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self {
            guard CFGetTypeID(v) == (T.self == AXUIElement.self ? AXUIElementGetTypeID() : AXValueGetTypeID()) else { return nil }
            return (v as! T)
        }
        return v as? T
    }
}
