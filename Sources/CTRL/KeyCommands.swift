import AppKit
import ApplicationServices

/// Scrolling, back/forward, tabs, app switching, and text editing — all as key presses or scroll events,
/// so they work in almost any app without touching the mouse.
@MainActor
enum KeyCommands {
    enum Nav: String {
        case scrollDown = "scroll_down", scrollUp = "scroll_up", pageDown = "page_down", pageUp = "page_up"
        case top = "scroll_top", bottom = "scroll_bottom"
        case back, forward
        case nextTab = "next_tab", previousTab = "previous_tab", reopenTab = "reopen_tab"
        case previousApp = "previous_app"
        case showDesktop = "show_desktop", copyLink = "copy_link"
    }

    enum Edit: String {
        case undo, redo, selectAll = "select_all", copy, cut, paste
        case deleteWord = "delete_word", deleteSentence = "delete_sentence", deleteLine = "delete_line"
        case selectWord = "select_word", selectSentence = "select_sentence", selectLine = "select_line"
        case scratch = "scratch_that"
        case newLine = "new_line", newParagraph = "new_paragraph"
        case end = "go_to_end", start = "go_to_start"
    }

    static let navQuestion = TypeSafeClient.Question.choice("How does the user want to move around?", options: [
        "scroll_down": "scroll down a bit",
        "scroll_up": "scroll up a bit",
        "page_down": "scroll down a lot / a page / way down",
        "page_up": "scroll up a lot / a page / way up",
        "scroll_top": "go / scroll to the very top",
        "scroll_bottom": "go / scroll to the very bottom, the end of the page",
        "back": "go back to the previous page",
        "forward": "go forward a page",
        "next_tab": "the next tab, the tab to the right",
        "previous_tab": "the previous tab, the tab to the left",
        "reopen_tab": "reopen / bring back the tab that was just closed",
        "previous_app": "switch back to the previous app, the last app, the other app (no app named)",
        "show_desktop": "show the desktop: get every window out of the way, hide everything, clear the screen",
        "copy_link": "copy the link / URL / web address of the current page or tab",
    ])

    static let editQuestion = TypeSafeClient.Question.choice("What text editing does the user want in the current text field?", options: [
        "undo": "undo the last edit",
        "redo": "redo",
        "select_all": "select all / everything",
        "copy": "copy the selection",
        "cut": "cut the selection",
        "paste": "paste",
        "delete_word": "delete / remove the last word or the previous word",
        "delete_sentence": "delete / remove the last sentence",
        "delete_line": "delete / clear the whole line or the current line",
        "select_word": "select the last word / previous word",
        "select_sentence": "select the last sentence",
        "select_line": "select the line / current line",
        "scratch_that": "delete what was just typed or dictated: 'scratch that', 'delete that', 'remove what I just said'",
        "new_line": "new line, line break, go to the next line",
        "new_paragraph": "new paragraph",
        "go_to_end": "move the cursor to the end of the text",
        "go_to_start": "move the cursor to the beginning of the text",
    ])

    // Key codes
    private static let kLeft: CGKeyCode = 123, kRight: CGKeyCode = 124, kDown: CGKeyCode = 125, kUp: CGKeyCode = 126
    private static let kDelete: CGKeyCode = 51, kReturn: CGKeyCode = 36, kTab: CGKeyCode = 48

    /// The app that was in front before the current one (for "switch back").
    private static var previous: NSRunningApplication?
    private static var current: NSRunningApplication?
    static func startTracking() {
        current = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in
                if app != current { previous = current; current = app }
            }
        }
    }

    struct Result { let symbol: String; let title: String; let detail: String? }

    static func perform(_ a: Nav, in app: NSRunningApplication?) async -> Result {
        app?.activate()
        try? await Task.sleep(for: .milliseconds(60))
        switch a {
        case .scrollDown, .scrollUp, .pageDown, .pageUp:
            let big = a == .pageDown || a == .pageUp
            let down = a == .scrollDown || a == .pageDown
            let h = app.flatMap(windowFrame)?.height ?? 900
            await scroll(by: (down ? -1 : 1) * h * (big ? 0.85 : 0.4), in: app)
            return Result(symbol: down ? "arrow.down" : "arrow.up", title: down ? "Scrolled down" : "Scrolled up", detail: nil)
        case .top: Keys.press(kUp, flags: .maskCommand); return Result(symbol: "arrow.up.to.line", title: "Top", detail: nil)
        case .bottom: Keys.press(kDown, flags: .maskCommand); return Result(symbol: "arrow.down.to.line", title: "Bottom", detail: nil)
        case .back: Keys.press(33, flags: .maskCommand); return Result(symbol: "chevron.backward", title: "Back", detail: nil)        // ⌘[
        case .forward: Keys.press(30, flags: .maskCommand); return Result(symbol: "chevron.forward", title: "Forward", detail: nil)   // ⌘]
        case .nextTab: Keys.press(kTab, flags: .maskControl); return Result(symbol: "arrow.right.square", title: "Next tab", detail: nil)
        case .previousTab: Keys.press(kTab, flags: [.maskControl, .maskShift]); return Result(symbol: "arrow.left.square", title: "Previous tab", detail: nil)
        case .reopenTab: Keys.press(17, flags: [.maskCommand, .maskShift]); return Result(symbol: "arrow.uturn.backward.square", title: "Reopened tab", detail: nil)   // ⌘⇧T
        case .previousApp:
            guard let p = previous, !p.isTerminated, p != app else { return Result(symbol: "rectangle.2.swap", title: "No previous app", detail: nil) }
            p.activate()
            return Result(symbol: "rectangle.2.swap", title: p.localizedName ?? "Switched", detail: nil)
        case .showDesktop:
            // Hide every regular app (Finder's windows minimize), so only the desktop is left.
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && !a.isHidden {
                if a.bundleIdentifier == "com.apple.finder" { continue }
                a.hide()
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            return Result(symbol: "menubar.dock.rectangle", title: "Desktop", detail: nil)
        case .copyLink:
            // Address bar: focus it, copy, put focus back. Works in Safari, Chrome, Dia, Arc, Firefox…
            Keys.press(37, flags: .maskCommand)                    // ⌘L
            try? await Task.sleep(for: .milliseconds(120))
            Keys.press(8, flags: .maskCommand)                     // ⌘C
            try? await Task.sleep(for: .milliseconds(80))
            Keys.press(53, flags: [])                              // Esc
            try? await Task.sleep(for: .milliseconds(80))
            let link = NSPasteboard.general.string(forType: .string)
            return Result(symbol: "link", title: "Copied link", detail: link.flatMap { URL(string: $0)?.host() } ?? link.map { String($0.prefix(40)) })
        }
    }

    /// `typed`: what CTRL last typed (for "scratch that").
    static func perform(_ a: Edit, in app: NSRunningApplication?, typed: String?) async -> Result {
        app?.activate()
        try? await Task.sleep(for: .milliseconds(60))
        switch a {
        case .undo: Keys.press(6, flags: .maskCommand); return Result(symbol: "arrow.uturn.backward", title: "Undo", detail: nil)
        case .redo: Keys.press(6, flags: [.maskCommand, .maskShift]); return Result(symbol: "arrow.uturn.forward", title: "Redo", detail: nil)
        case .selectAll: Keys.press(0, flags: .maskCommand); return Result(symbol: "selection.pin.in.out", title: "Selected all", detail: nil)
        case .copy: Keys.press(8, flags: .maskCommand); return Result(symbol: "doc.on.doc", title: "Copied", detail: nil)
        case .cut: Keys.press(7, flags: .maskCommand); return Result(symbol: "scissors", title: "Cut", detail: nil)
        case .paste: Keys.press(9, flags: .maskCommand); return Result(symbol: "doc.on.clipboard", title: "Pasted", detail: nil)
        case .deleteWord: Keys.press(kDelete, flags: .maskAlternate); return Result(symbol: "delete.left", title: "Deleted word", detail: nil)
        case .deleteLine: Keys.press(kDelete, flags: .maskCommand); return Result(symbol: "delete.left", title: "Deleted line", detail: nil)
        case .selectWord: Keys.press(kLeft, flags: [.maskAlternate, .maskShift]); return Result(symbol: "character.cursor.ibeam", title: "Selected word", detail: nil)
        case .selectLine: Keys.press(kLeft, flags: [.maskCommand, .maskShift]); return Result(symbol: "character.cursor.ibeam", title: "Selected line", detail: nil)
        case .selectSentence, .deleteSentence:
            let ok = selectLastSentence()
            if !ok { Keys.press(kLeft, flags: [.maskCommand, .maskShift]) }   // can't read the field: the line is the next best thing
            if a == .deleteSentence {
                try? await Task.sleep(for: .milliseconds(40))
                Keys.press(kDelete, flags: [])
                return Result(symbol: "delete.left", title: "Deleted sentence", detail: ok ? nil : "Removed the line")
            }
            return Result(symbol: "character.cursor.ibeam", title: "Selected sentence", detail: ok ? nil : "Selected the line")
        case .scratch:
            guard let typed, !typed.isEmpty else { return Result(symbol: "delete.left", title: "Nothing to remove", detail: nil) }
            for _ in 0..<typed.count { Keys.press(kDelete, flags: []); try? await Task.sleep(for: .milliseconds(2)) }
            return Result(symbol: "delete.left", title: "Removed", detail: "“\(typed.prefix(40))”")
        case .newLine: Keys.press(kReturn, flags: .maskShift); return Result(symbol: "return", title: "New line", detail: nil)
        case .newParagraph:
            Keys.press(kReturn, flags: .maskShift); Keys.press(kReturn, flags: .maskShift)
            return Result(symbol: "return", title: "New paragraph", detail: nil)
        case .end: Keys.press(kDown, flags: .maskCommand); return Result(symbol: "text.line.last.and.arrowtriangle.forward", title: "End", detail: nil)
        case .start: Keys.press(kUp, flags: .maskCommand); return Result(symbol: "text.line.first.and.arrowtriangle.forward", title: "Start", detail: nil)
        }
    }

    // MARK: Scrolling

    /// Smooth pixel scroll over the front window (the mouse can be anywhere; it's moved there and back).
    static func scroll(by pixels: CGFloat, in app: NSRunningApplication?) async {
        let mouse = CGEvent(source: nil)?.location ?? .zero
        // Scroll events go to the window under the pointer: put it over the front window if it isn't.
        var moved = false
        if let f = app.flatMap(windowFrame), !f.contains(mouse) {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
            moved = true
        }
        let steps = 12
        for _ in 0..<steps {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(pixels / CGFloat(steps)), wheel2: 0, wheel3: 0)
            e?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
        }
        if moved {
            try? await Task.sleep(for: .milliseconds(40))
            CGWarpMouseCursorPosition(mouse)
        }
    }

    /// Focused window frame, global top-left coordinates.
    static func windowFrame(_ app: NSRunningApplication) -> CGRect? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &w) == .success
                || AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &w) == .success, let w else { return nil }
        let win = w as! AXUIElement
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    // MARK: Sentences (Accessibility: read the field, select the range)

    /// Selects the sentence before the cursor in the focused text field. False when the field can't be read.
    private static func selectLastSentence() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f else { return false }
        let field = f as! AXUIElement
        var v: CFTypeRef?, r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &v) == .success, let text = v as? String,
              AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let r else { return false }
        var sel = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &sel)
        let ns = text as NSString
        let caret = min(ns.length, sel.location + sel.length)
        guard caret > 0 else { return false }
        // Last sentence ending at or before the caret (skip trailing spaces).
        var end = caret
        while end > 0, let c = Unicode.Scalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { end -= 1 }
        guard end > 0 else { return false }
        var start = end - 1
        while start > 0 {
            let c = ns.character(at: start - 1)
            if let u = Unicode.Scalar(c), ".!?\n".unicodeScalars.contains(u) { break }
            start -= 1
        }
        while start < end, let u = Unicode.Scalar(ns.character(at: start)), CharacterSet.whitespaces.contains(u) { start += 1 }
        // Include the space before it, so deleting leaves "A. B." → "A."
        if start > 0, let u = Unicode.Scalar(ns.character(at: start - 1)), u == " " { start -= 1 }
        var range = CFRange(location: start, length: caret - start)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
