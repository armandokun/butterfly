import AppKit
import ApplicationServices
import Network

/// Voice control for Cursor's agent window: conversations, new agents, asking the agent, running the project.
/// Everything is read from the sidebar (Accessibility) while you talk, so it adds no time after you stop.
@MainActor
enum CursorControl {
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    struct Chat {
        let title: String
        let project: String?
        let minutesAgo: Double
        let element: AXUIElement
        var current = false
    }
    struct Snapshot {
        let app: NSRunningApplication
        var chats: [Chat]
        var newAgent: [String: AXUIElement]   // project → its "New Agent" button
        var composer: AXUIElement?
        var currentProject: String? { chats.first { $0.current }?.project ?? chats.min { $0.minutesAgo < $1.minutesAgo }?.project }
    }

    enum Action: String {
        case lastChat = "last_chat", openChat = "open_chat", newAgent = "new_agent", ask = "ask_agent", testLocally = "test_locally"
    }

    static let actionQuestion = TypeSafeClient.Question.choice("What does the user want done in Cursor?", options: [
        "last_chat": "go back to the last / previous / most recent conversation or chat (no specific one named)",
        "open_chat": "open a specific conversation or chat, named by its topic or project",
        "new_agent": "start a new agent / new chat / new conversation (optionally in a named project)",
        "ask_agent": "ask, tell, or instruct the Cursor agent to do something ('ask cursor to fix the build', 'tell the agent to add tests')",
        "test_locally": "test, run, start, or preview the project locally: start the dev server, run the app, open it from the terminal",
    ])

    // MARK: Reading the window

    static func snapshot(of app: NSRunningApplication) -> Snapshot? {
        guard app.bundleIdentifier == bundleID else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = attr(ax, kAXFocusedWindowAttribute) ?? attr(ax, kAXMainWindowAttribute) else { return nil }
        var s = Snapshot(app: app, chats: [], newAgent: [:], composer: nil)
        let deadline = Date().addingTimeInterval(0.8)
        var visited = 0
        var section = ""
        var project: String?
        var sidebarMaxX: CGFloat = 0
        let winFrame = frame(window) ?? .zero
        var openTabs: Set<String> = []
        var fields: [(AXUIElement, CGRect)] = []

        var pending: (label: String, el: AXUIElement, frame: CGRect?)?   // a sidebar button waiting for its age text

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 45, visited < 6000, Date() < deadline else { return }
            visited += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let f = frame(el)
            if role == "AXButton" {
                let label = [attr(el, kAXTitleAttribute) as String?, attr(el, kAXDescriptionAttribute) as String?].compactMap { $0 }.first { !$0.isEmpty } ?? texts(el).first ?? ""
                if ProcessInfo.processInfo.environment["CTRL_DUMP"] == "3" { print("  btn[\(section)] \(label)") }
                if ["Projects", "Pinned", "Workspaces"].contains(label) { section = label; pending = nil }
                else if label == "New Agent" {
                    // The button before "New Agent" was a project header.
                    if let p = pending { project = p.label; pending = nil }
                    if let project { s.newAgent[project] = el }
                } else if ["Pin", "Unpin", "Archive", "Expand Project", "New Project", ""].contains(label) {
                    // controls inside a row
                } else if section == "Pinned" || section == "Workspaces" {
                    if let p = pending, section == "Workspaces" { project = p.label }   // no age came: it was a header
                    pending = (label, el, f)
                }
            }
            if role == "AXRadioButton", let t: String = attr(el, kAXTitleAttribute) ?? attr(el, kAXDescriptionAttribute), !t.isEmpty {
                // Chat tabs above the conversation: the selected one is the chat that's open.
                let on = (attr(el, kAXValueAttribute) as NSNumber?)?.boolValue ?? false
                if on { openTabs.insert(t) }
            }
            if role == "AXStaticText", let v: String = attr(el, kAXValueAttribute) {
                if let p = pending, let age = minutes(v) {
                    s.chats.append(Chat(title: p.label, project: section == "Workspaces" ? project : nil, minutesAgo: age, element: p.el))
                    if let pf = p.frame { sidebarMaxX = max(sidebarMaxX, pf.maxX) }
                    pending = nil
                }
            }
            if role == "AXTextArea" || role == "AXTextField", let f, f.minX > sidebarMaxX { fields.append((el, f)) }
            // Long transcripts: skip what's scrolled out of the window.
            if let f, depth > 6, !f.intersects(winFrame) { return }
            for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth: depth + 1) }
        }
        walk(window, depth: 0)
        for i in s.chats.indices where openTabs.contains(s.chats[i].title) { s.chats[i].current = true }
        if ProcessInfo.processInfo.environment["CTRL_DUMP"] == "3" {
            print("  projects:", Set(s.chats.compactMap(\.project)), "newAgent:", Array(s.newAgent.keys), "tabs:", openTabs)
        }
        s.composer = fields.max { $0.1.minY < $1.1.minY }?.0   // the chat box sits at the bottom
        return s.chats.isEmpty ? nil : s
    }

    /// Options for "which conversation": title, project, how long ago.
    static func chatOptions(_ s: Snapshot) -> [String: String] {
        var o = ["none": "none of these / no specific conversation named"]
        for (i, c) in s.chats.prefix(120).enumerated() {
            o["c\(i)"] = "the conversation “\(c.title)”" + (c.project.map { " in the \($0) project" } ?? "") + ", active \(ago(c.minutesAgo))" + (c.current ? " (open now)" : "")
        }
        return o
    }

    // MARK: Doing it

    struct Result { let symbol: String; let title: String; let detail: String? }

    static func perform(_ action: Action, chat: Chat?, project: String?, message: String, snapshot s: Snapshot, menu: MenuReader.Snapshot?) async -> Result {
        s.app.activate()
        try? await Task.sleep(for: .milliseconds(80))
        switch action {
        case .lastChat:
            // The most recent one you're not already in.
            guard let c = s.chats.filter({ !$0.current }).min(by: { $0.minutesAgo < $1.minutesAgo }) else {
                return Result(symbol: "bubble.left.and.bubble.right", title: "No other conversation", detail: nil)
            }
            press(c.element)
            return Result(symbol: "bubble.left.and.bubble.right", title: c.title, detail: c.project)
        case .openChat:
            guard let c = chat else { return Result(symbol: "questionmark.bubble", title: "Which conversation?", detail: nil) }
            press(c.element)
            return Result(symbol: "bubble.left.and.bubble.right", title: c.title, detail: c.project)
        case .newAgent:
            if let project, let b = s.newAgent[project] { press(b) } else { Keys.press(45, flags: .maskCommand) }   // ⌘N
            return Result(symbol: "plus.bubble", title: "New agent", detail: project)
        case .ask:
            if let c = s.composer { focus(c) } else { Keys.press(37, flags: .maskCommand) }   // ⌘L
            try? await Task.sleep(for: .milliseconds(150))
            await Typer.type(message, pressReturn: true)
            return Result(symbol: "paperplane", title: "Asked Cursor", detail: "“\(message.prefix(50))”")
        case .testLocally:
            // Cursor's agent knows the project; we just ask it. Another project named: go to its latest chat first.
            if let project, project != s.currentProject {
                if let c = s.chats.filter({ $0.project == project }).min(by: { $0.minutesAgo < $1.minutesAgo }) { press(c.element) }
                else if let b = s.newAgent[project] { press(b) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let c = s.composer, project == nil || project == s.currentProject { focus(c) } else { Keys.press(37, flags: .maskCommand) }   // ⌘L
            try? await Task.sleep(for: .milliseconds(150))
            await Typer.type(Self.testPrompt, pressReturn: true)
            return Result(symbol: "play.rectangle", title: "Asked Cursor to run it", detail: project ?? s.currentProject)
        }
    }

    static let testPrompt = "Run this project locally so I can test it: start whatever it needs in the terminal, and when it's up, open it in Cursor's browser."

    /// A conversation whose title you mostly said (at least 3 of its words, ≥ 75% of them).
    static func chatNamed(in spoken: String, snapshot s: Snapshot) -> Chat? {
        let words: (String) -> [String] = { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 } }
        let said = Set(words(spoken))
        let scored = s.chats.map { c -> (Chat, Double, Int) in
            let w = words(c.title)
            let hit = w.filter(said.contains).count
            return (c, w.isEmpty ? 0 : Double(hit) / Double(w.count), hit)
        }
        return scored.filter { $0.1 >= 0.75 && $0.2 >= 3 }.max { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    /// "new agent in openmail mcp" → "openmail-mcp": the longest project name said (spaces, dashes ignored).
    static func projectNamed(in spoken: String, snapshot s: Snapshot) -> String? {
        let squash: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        let said = " " + spoken.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        let names = Set(s.chats.compactMap(\.project)).union(s.newAgent.keys)
        return names.filter { n in
            let words = n.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
            return said.contains(" \(words) ") || said.replacingOccurrences(of: " ", with: "").contains(squash(n)) && squash(n).count > 5
        }.max { $0.count < $1.count }
    }

    /// "ask cursor to fix the build" → "fix the build".
    static func message(from spoken: String) -> String {
        let s = spoken.trimmingCharacters(in: .whitespaces)
        let p = #"^\s*(please\s+)?(ask|tell|have|get|let)\s+(cursor|the agent|agent|claude|the ai)\s+(to\s+|that\s+)?"#
        let m = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        guard let first = m.first else { return s }
        return first.uppercased() + m.dropFirst()
    }

    // MARK: Helpers

    private static func press(_ el: AXUIElement) { AXUIElementPerformAction(el, kAXPressAction as CFString) }

    static func focus(_ el: AXUIElement) {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let f = frame(el) { Clicker.click(at: CGPoint(x: f.midX, y: f.midY)) }
    }

    /// "6d" → minutes. Cursor's sidebar ages: now, 5m, 3h, 2d, 1w, 2mo, 1y.
    private static func minutes(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "now" || t == "just now" { return 0 }
        guard let r = t.range(of: #"^(\d+)\s*(min|mo|m|h|d|w|y)$"#, options: .regularExpression) else { return nil }
        let token = String(t[r])
        let digits = token.prefix { $0.isNumber }
        guard let n = Double(digits) else { return nil }
        let u = token.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let unit: Double = switch u { case "m", "min": 1; case "h": 60; case "d": 1440; case "w": 10080; case "mo": 43200; default: 525600 }
        return n * unit
    }

    private static func ago(_ minutes: Double) -> String {
        switch minutes {
        case ..<1: "just now"
        case ..<60: "\(Int(minutes)) min ago"
        case ..<1440: "\(Int(minutes / 60)) h ago"
        default: "\(Int(minutes / 1440)) days ago"
        }
    }

    private static func texts(_ el: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        var out: [String] = []
        for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (attr(k, kAXRoleAttribute) as String?) == "AXStaticText", let v: String = attr(k, kAXValueAttribute), !v.isEmpty { out.append(v) }
            out += texts(k, depth: depth + 1)
        }
        return out
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return (v as! T) }
        if T.self == AXValue.self { guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }; return (v as! T) }
        return v as? T
    }
}
