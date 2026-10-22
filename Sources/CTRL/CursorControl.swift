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
            let name = project ?? s.currentProject
            guard let name, let folder = ProjectRunner.folder(named: name) else {
                return Result(symbol: "questionmark.folder", title: "Which project?", detail: "Open its chat, then say it again")
            }
            guard let run = ProjectRunner.detect(in: folder) else {
                return Result(symbol: "questionmark.app", title: "Don’t know how to run \(name)", detail: "Add a routine named “test \(name) locally”")
            }
            await openTerminal(menu: menu)
            let before = run.web ? ProjectRunner.listeningPorts() : []
            await Typer.type("cd \(shellQuote(folder.path)) && \(run.command)", pressReturn: true)
            if run.web {
                Task { await openBrowserWhenReady(known: run.port, before: before, menu: menu, app: s.app) }
            }
            return Result(symbol: "play.rectangle", title: run.command, detail: name + (run.web ? " · opens in the browser when ready" : ""))
        }
    }

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

    private static func openTerminal(menu: MenuReader.Snapshot?) async {
        if let item = menu?.items.first(where: { $0.path.last == "New Terminal" }), let app = menu?.app { _ = await MenuReader.press(item, in: app) }
        else { Keys.press(50, flags: [.maskControl, .maskShift]) }   // ⌃⇧` (VS Code's new terminal)
        try? await Task.sleep(for: .milliseconds(1200))
    }

    /// Waits for the dev server: the port we know about, or whichever new local port opens first (monorepos).
    private static func openBrowserWhenReady(known: Int?, before: Set<Int>, menu: MenuReader.Snapshot?, app: NSRunningApplication) async {
        let deadline = Date().addingTimeInterval(120)
        var port: Int?
        while Date() < deadline, port == nil {
            try? await Task.sleep(for: .seconds(1))
            let fresh = ProjectRunner.listeningPorts().subtracting(before).filter { $0 >= 1024 }
            if let k = known, fresh.contains(k) { port = k }
            else if let p = fresh.sorted().first { port = p }
        }
        guard let port else { return }
        try? await Task.sleep(for: .milliseconds(800))   // let it finish booting
        app.activate()
        let url = "http://localhost:\(port)"
        if let item = menu?.items.first(where: { $0.path.last == "New Browser" }) { _ = await MenuReader.press(item, in: app) }
        else { NSWorkspace.shared.open(URL(string: url)!); return }
        try? await Task.sleep(for: .milliseconds(900))
        Keys.press(37, flags: .maskCommand)   // ⌘L: address bar
        try? await Task.sleep(for: .milliseconds(150))
        await Typer.type(url, pressReturn: true)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func press(_ el: AXUIElement) { AXUIElementPerformAction(el, kAXPressAction as CFString) }

    private static func focus(_ el: AXUIElement) {
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

/// Where a project lives and how to start it. Read from the project's own files: no guessing, no model call.
enum ProjectRunner {
    struct Run { let command: String; let port: Int?; var web = false }

    /// Local TCP ports something is listening on right now.
    static func listeningPorts() -> Set<Int> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var ports: Set<Int> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":"), let n = Int(line[line.index(after: colon)...]) { ports.insert(n) }
        }
        return ports
    }

    /// Cursor's own record of opened folders, matched by folder name (real checkouts before worktrees).
    static func folder(named name: String) -> URL? {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Cursor/User/workspaceStorage")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        var hits: [URL] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appending(path: "workspace.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = json["folder"] as? String, let url = URL(string: s), url.isFileURL else { continue }
            if url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame, FileManager.default.fileExists(atPath: url.path) { hits.append(url) }
        }
        if let h = hits.first(where: { !$0.path.contains("/worktrees/") }) ?? hits.first { return h }
        let guess = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/\(name)")
        return FileManager.default.fileExists(atPath: guess.path) ? guess : nil
    }

    static func detect(in dir: URL) -> Run? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: dir.appending(path: p).path) }

        if let data = try? Data(contentsOf: dir.appending(path: "package.json")),
           let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = pkg["scripts"] as? [String: String] ?? [:]
            if let name = ["dev", "start", "serve", "preview"].first(where: { scripts[$0] != nil }) {
                let pm = has("pnpm-lock.yaml") ? "pnpm" : (has("bun.lockb") || has("bun.lock")) ? "bun" : has("yarn.lock") ? "yarn" : "npm"
                let command = pm == "npm" && name != "start" ? "npm run \(name)" : "\(pm) \(pm == "npm" ? "start" : name)"
                return Run(command: command, port: port(script: scripts[name]!, pkg: pkg), web: isWeb(pkg: pkg, dir: dir))
            }
        }
        for s in ["scripts/dev.sh", "scripts/run.sh", "scripts/install.sh", "dev.sh", "run.sh"] where has(s) { return Run(command: "./" + s, port: nil) }
        if let mk = try? String(contentsOf: dir.appending(path: "Makefile"), encoding: .utf8) {
            for t in ["dev", "run", "serve", "start"] where mk.range(of: "(?m)^\(t):", options: .regularExpression) != nil { return Run(command: "make \(t)", port: nil) }
        }
        if has("manage.py") { return Run(command: "python manage.py runserver", port: 8000, web: true) }
        if has("Package.swift") { return Run(command: "swift run", port: nil) }
        if has("Cargo.toml") { return Run(command: "cargo run", port: nil) }
        if has("go.mod") { return Run(command: "go run .", port: nil) }
        return nil
    }

    /// Serves pages: a web framework here or in any workspace package, or a server library.
    private static func isWeb(pkg: [String: Any], dir: URL) -> Bool {
        let web = ["next", "nuxt", "vite", "astro", "@sveltejs/kit", "react-scripts", "@remix-run/dev", "express", "hono", "fastify", "koa", "@nestjs/core", "wrangler", "@angular/core", "gatsby", "@remotion/cli"]
        func deps(_ p: [String: Any]) -> Set<String> {
            Set((p["dependencies"] as? [String: Any] ?? [:]).keys).union((p["devDependencies"] as? [String: Any] ?? [:]).keys)
        }
        if !deps(pkg).isDisjoint(with: web) { return true }
        // Monorepo: look one level into apps/* and packages/*.
        for sub in ["apps", "packages", "services"] {
            let base = dir.appending(path: sub)
            for d in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                if let data = try? Data(contentsOf: d.appending(path: "package.json")),
                   let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !deps(p).isDisjoint(with: web) { return true }
            }
        }
        return false
    }

    /// Port from the script ("--port 3001", "-p 4000", "PORT=8080"), else the framework's default. Nil: not a web app.
    private static func port(script: String, pkg: [String: Any]) -> Int? {
        let pattern = #"(--port[ =]|-p\s+|PORT=)([0-9]{2,5})"#
        if let r = script.range(of: pattern, options: .regularExpression),
           let p = Int(script[r].reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) { return p }
        let deps = (pkg["dependencies"] as? [String: Any] ?? [:]).merging(pkg["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        if deps["next"] != nil || deps["nuxt"] != nil || deps["react-scripts"] != nil || deps["@remix-run/dev"] != nil { return 3000 }
        if deps["astro"] != nil { return 4321 }
        if deps["vite"] != nil || deps["@sveltejs/kit"] != nil { return 5173 }
        if deps["expo"] != nil || deps["react-native"] != nil { return nil }
        if script.contains("wrangler") { return 8787 }
        return nil
    }
}
