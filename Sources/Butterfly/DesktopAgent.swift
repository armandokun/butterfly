import AppKit
import Foundation

/// Voice command → Gemini tool loop → `agent-desktop` (vercel-labs/agent-desktop: reads and operates apps through the
/// accessibility tree). Butterfly adds a few native tools: type into the focused field, open a URL, look at the screen,
/// and screen memory ("what did I do this week").
@MainActor
enum DesktopAgent {
    static let model = "gemini-3.8-flash"
    static let maxTurns = 30

    struct Recap {
        struct Item { var time: String; var goal: String; var apps: [String]; var minutes: Int? }
        var title: String; var range: String; var items: [Item]
    }
    struct Outcome { var summary: String; var answer: String?; var recap: Recap? }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: Binary

    /// npm i -g agent-desktop / brew install agent-desktop. GUI apps don't get the shell PATH, so look in the usual places.
    static let binary: String? = {
        let home = NSHomeDirectory()
        let known = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
            .map { "\($0)/agent-desktop" }
        if let p = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let p = Process()   // nvm, asdf…: ask a login shell once
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v agent-desktop"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || !FileManager.default.isExecutableFile(atPath: s) ? nil : s
    }()

    /// Runs `agent-desktop <args>`; returns its JSON envelope (stdout, else stderr). Killed on cancel or after `timeout`.
    nonisolated static func cli(_ args: [String], stdin: String? = nil, session: String? = nil, timeout: TimeInterval = 25) async -> String {
        guard let bin = await binary else { return #"{"ok":false,"error":{"message":"agent-desktop is not installed"}}"# }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        if let session { p.environment = ProcessInfo.processInfo.environment.merging(["AGENT_DESKTOP_SESSION": session]) { $1 } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return #"{"ok":false,"error":{"message":"could not start agent-desktop"}}"# }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        // Read concurrently so a big snapshot can't fill the pipe and stall the process.
        async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Task.isCancelled || Date() > deadline { p.terminate(); break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let (od, ed) = await (o, e)
        let s = String(decoding: od.isEmpty ? ed : od, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if Task.isCancelled { return #"{"ok":false,"error":{"message":"cancelled"}}"# }
        return s.isEmpty ? #"{"ok":false,"error":{"message":"no output (timed out?)"}}"# : s
    }

    /// The tool's own guides (core loop + macOS), read once from the installed binary so they match its version.
    private static var guides: String?
    private static func loadGuides() async -> String {
        if let guides { return guides }
        var parts: [String] = []
        for g in [["skills", "get", "desktop"], ["skills", "get", "platform"]] {
            let raw = await cli(g)
            if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let c = (o["data"] as? [String: Any])?["content"] as? String { parts.append(c) }
        }
        let s = parts.joined(separator: "\n\n---\n\n")
        if !s.isEmpty { guides = s }
        return s
    }

    // MARK: Tools

    private static let tools: [[String: Any]] = [[
        "functionDeclarations": [
            ["name": "desktop",
             "description": "Run one agent-desktop CLI command, e.g. [\"snapshot\",\"--app\",\"Notes\",\"-i\",\"--compact\"] or [\"click\",\"@s8f3k2p9:e12\"]. Returns its JSON envelope.",
             "parameters": ["type": "object", "properties": [
                "args": ["type": "array", "items": ["type": "string"], "description": "Arguments after `agent-desktop`, one per item."],
                "stdin": ["type": "string", "description": "Text piped to the command (for `type --stdin`, `set-value --stdin`, `clipboard-set --stdin`)."]],
                "required": ["args"]]],
            ["name": "type_text",
             "description": "Type text with the real keyboard into whatever field has focus in the front app (works in browsers and Electron apps where the accessibility tree is empty). Use for 'type/write here'.",
             "parameters": ["type": "object", "properties": [
                "text": ["type": "string"],
                "press_enter": ["type": "boolean", "description": "Press Return after (only when the user said send/submit/enter)."]],
                "required": ["text"]]],
            ["name": "open_url",
             "description": "Open a URL in the default browser (web searches, sites, deep links). URL-encode queries.",
             "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]],
            ["name": "web_answer",
             "description": "Answer a general question from the web (Google Search): facts, news, weather, prices, how-tos, definitions. Returns a short answer. No app opens.",
             "parameters": ["type": "object", "properties": ["question": ["type": "string", "description": "The question, self-contained (resolve 'here', 'tomorrow' to concrete places and dates)."]], "required": ["question"]]],
            ["name": "look",
             "description": "Screenshot of the front window, for when the accessibility tree is empty or unclear (web pages, canvases, images).",
             "parameters": ["type": "object", "properties": [:]]],
            ["name": "screen_memory",
             "description": "What was on the user's screen in the past (on-device OCR history, last 14 days). Use for 'what did I do…', 'what was that price I saw…'. Give a period phrase and/or keywords.",
             "parameters": ["type": "object", "properties": [
                "period": ["type": "string", "description": "e.g. 'this week', 'yesterday', 'today', 'last 2 hours', 'last 3 days'."],
                "keywords": ["type": "string", "description": "Words to search for in what was seen."]]]],
            ["name": "finish",
             "description": "End the task. Always call this last.",
             "parameters": ["type": "object", "properties": [
                "summary": ["type": "string", "description": "3-6 words of what was done, e.g. 'Sent the message to Ana'."],
                "answer": ["type": "string", "description": "Text to show the user, when they asked a question. Short."],
                "keep_open": ["type": "boolean", "description": "Apps you launched get closed after an answer. Set true only when the user asked to open/show/start an app or a document, or to write or do something in it they'll keep using ('open Calculator', 'start a note'). 'Use X to work out…' → false."],
                "recap": ["type": "object", "description": "Only for 'what did I do' questions: the GOALS the user worked toward, as a timeline.",
                          "properties": [
                            "title": ["type": "string", "description": "2-3 words, e.g. 'This week', 'Yesterday'"],
                            "items": ["type": "array", "items": ["type": "object", "properties": [
                                "time": ["type": "string", "description": "When it started: HH:mm, or a 3-letter weekday for multi-day periods"],
                                "goal": ["type": "string", "description": "The outcome they were after, ≤ 36 characters, verb first: 'Shipped Butterfly agent rewrite', 'Planned Ryanair trip'. Not a click-by-click action."],
                                "apps": ["type": "array", "items": ["type": "string"], "description": "Apps used for it, exactly as named in screen memory, most used first, max 4."],
                                "minutes": ["type": "integer", "description": "Approximate total minutes spent on it."]],
                                "required": ["time", "goal", "apps"]]]],
                          "required": ["title", "items"]]],
                "required": ["summary"]]],
        ],
    ]]

    // MARK: Cleanup

    /// Quits regular apps that weren't running when the request started. `terminate()` is the polite quit:
    /// an app with unsaved work still asks.
    private static func closeLaunched(since before: Set<pid_t>) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && !before.contains(app.processIdentifier) && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            log("closing \(app.localizedName ?? "?") (opened for this answer)")
            app.terminate()
        }
    }

    // MARK: Web

    /// One grounded Gemini call (Google Search). Kept apart from the tool loop: search grounding and
    /// forced function calling don't mix in one request.
    private static func webAnswer(_ question: String, key: String) async -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": "Answer in 1–2 short sentences for a voice assistant's notch. Facts first, no preamble, no links. Now: \(f.string(from: Date())), user's time zone \(TimeZone.current.identifier)."]]],
            "contents": [["role": "user", "parts": [["text": question]]]],
            "tools": [["google_search": [:]]],
            "generationConfig": ["temperature": 0.2],
        ]
        do {
            let d = try await MeetingTranscriber.request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 30)
            let parts = ((d["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            log("web: \(question) → \(text.prefix(200))")
            return text.isEmpty ? #"{"ok":false,"error":"no answer"}"# : text
        } catch { return #"{"ok":false,"error":"search failed"}"# }
    }

    // MARK: Run

    /// `progress`: a short line for the notch ("Clicking Send…").
    static func run(_ request: String, front: NSRunningApplication?, key: String, progress: @escaping (String) -> Void) async throws -> Outcome {
        guard binary != nil else { throw Failure(message: "Install agent-desktop: npm i -g agent-desktop") }
        let guides = await loadGuides()
        let f = DateFormatter(); f.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let system = """
        You are Butterfly, a voice assistant that operates the user's Mac for them. The user spoke a request; do it, \
        then call `finish`. Act, don't chat. Be quick: few, decisive steps.

        Now: \(f.string(from: Date())). Front app: \(front?.localizedName ?? "none")\(front.map { " (window: \(ScreenReader.windowTitle($0).prefix(80)))" } ?? "").

        How to act:
        - Use the `desktop` tool (agent-desktop). Observe → act on a ref → verify, as its guide below says. Start with \
        `snapshot --app "<front app>" -i --compact` (or `--skeleton` for big apps), not a full-screen tree.
        - Several actions on refs from one snapshot (keypad presses, form fields) go in ONE call: \
        `["batch","[{\\"command\\":\\"click\\",\\"args\\":{\\"ref_id\\":\\"@s…:e4\\"}},…]","--stop-on-error"]` — \
        the JSON array is a single argument, entries use `args`, not stdin.
        - "Here" / "this" means the front app and the field that has focus. For "type/write here …" use `type_text` directly.
        - If a snapshot comes back empty or fails for a browser/Electron app, use `look` to see it and `type_text`, \
        `desktop press …`, or `open_url` instead.
        - You may use `--headed` (real mouse and keys) when a headless action can't be delivered: the user asked you to do it.
        - Never delete, send, buy, quit apps or close windows with unsaved work unless the user asked for exactly that. \
        Never pass `--force`.
        - Questions about the past ("what did I do this week", "what was that price I saw") → `screen_memory`, then \
        `finish` with `answer`, or `recap` for "what did I do". A recap lists GOALS, not actions: group everything \
        that served one purpose (a project, a task, a decision, a trip, an errand) across apps and hours into one item, \
        named by its outcome ("Shipped the Butterfly agent rewrite", not "Edited Planner.swift in Cursor"). \
        3–6 goals for a short period, 5–10 for a multi-day one, covering every day, time order. Leave out idle \
        browsing under ~10 minutes unless it was most of the period. If they want it written somewhere, \
        `type_text` the summary instead.
        - General questions that need no app (facts, news, weather, prices, how-tos) → `web_answer`, then `finish` with \
        its `answer`. Don't open apps or browsers for them unless asked.
        - Questions about what's on screen now → `look` or a snapshot, then `finish` with `answer`.
        - If it can't be done, `finish` with `answer` saying why in one sentence.

        agent-desktop guide:
        \(guides)
        """
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": "The user said: “\(request)”"]]]]
        var recapRange = ""
        // A session with the visible agent cursor, started on the first desktop action: web answers and
        // memory questions never show a cursor.
        var session: String?, sessionTried = false
        // Apps running before we start: anything new was launched by the agent.
        let before = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        defer { if let id = session { Task.detached { _ = await cli(["session", "end", id]) } } }
        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": contents,
                "tools": tools,
                "toolConfig": ["functionCallingConfig": ["mode": "ANY"]],
                "generationConfig": ["temperature": 0.2, "thinkingConfig": ["thinkingBudget": 512]],
            ]
            let d = try await MeetingTranscriber.request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 45)
            try Task.checkCancellation()
            guard let content = (d["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw Failure(message: "Gemini didn't answer") }
            contents.append(content)   // as-is: keeps thought signatures for the next turn
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            if calls.isEmpty {
                let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                return Outcome(summary: "Done", answer: text.isEmpty ? nil : text, recap: nil)
            }
            var responses: [[String: Any]] = []
            var images: [Data] = []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let args = call["args"] as? [String: Any] ?? [:]
                log("→ \(name) \(args)")
                var result: String
                switch name {
                case "finish":
                    var recap: Recap?
                    if let r = args["recap"] as? [String: Any], let items = r["items"] as? [[String: Any]], !items.isEmpty {
                        recap = Recap(title: r["title"] as? String ?? "Recap", range: recapRange, items: items.prefix(10).map {
                            Recap.Item(time: ($0["time"] as? String) ?? "", goal: ($0["goal"] as? String) ?? ($0["text"] as? String) ?? "",
                                       apps: ($0["apps"] as? [String]) ?? [], minutes: ($0["minutes"] as? NSNumber)?.intValue) })
                    }
                    let answer = (args["answer"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    if args["keep_open"] as? Bool != true, answer != nil || recap != nil { closeLaunched(since: before) }
                    return Outcome(summary: args["summary"] as? String ?? "Done", answer: answer, recap: recap)
                case "desktop":
                    var a = (args["args"] as? [String]) ?? []
                    if a.first == "agent-desktop" { a.removeFirst() }
                    a.removeAll { $0 == "--force" }
                    progress(describe(a))
                    bringForward(a)
                    if !sessionTried { sessionTried = true; session = await startSession() }
                    result = ScreenReader.redact(await cli(a, stdin: args["stdin"] as? String, session: session))
                    if a.first == "launch" { bringForward(a) }
                case "type_text":
                    let text = args["text"] as? String ?? ""
                    progress("Typing…")
                    let app = NSWorkspace.shared.frontmostApplication
                    app?.activate()
                    try? await Task.sleep(for: .milliseconds(120))
                    await Typer.type(text)
                    if args["press_enter"] as? Bool == true { try? await Task.sleep(for: .milliseconds(60)); Keys.press(36, flags: []) }
                    result = #"{"ok":true}"#
                case "open_url":
                    if let s = args["url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
                        progress("Opening \(u.host() ?? s)…")
                        NSWorkspace.shared.open(u)
                        try? await Task.sleep(for: .milliseconds(1200))
                        result = #"{"ok":true}"#
                    } else { result = #"{"ok":false,"error":"bad url"}"# }
                case "web_answer":
                    progress("Searching…")
                    result = await webAnswer(args["question"] as? String ?? request, key: key)
                case "look":
                    progress("Looking…")
                    // Same masking as screen memory: what you typed and sensitive fields never leave as pixels.
                    if let app = NSWorkspace.shared.frontmostApplication, let shot = try? await ScreenReader.windowCapture(app),
                       let jpg = jpeg(ScreenReader.mask(shot.image, window: shot.frame, fields: await ScreenReader.inputFrames(pid: app.processIdentifier))) {
                        images.append(jpg)
                        result = #"{"ok":true,"note":"screenshot of the front window attached"}"#
                    } else { result = #"{"ok":false,"error":"no screenshot (Screen Recording permission?)"}"# }
                case "screen_memory":
                    progress("Remembering…")
                    let (text, range) = memory(period: args["period"] as? String, keywords: args["keywords"] as? String)
                    if let range { recapRange = range }
                    result = text
                default:
                    result = #"{"ok":false,"error":"unknown tool"}"#
                }
                log("← \(result.prefix(300))")
                responses.append(["functionResponse": ["name": name, "response": ["result": String(result.prefix(14000))]]])
            }
            var userParts = responses
            for img in images { userParts.append(["inlineData": ["mimeType": "image/jpeg", "data": img.base64EncodedString()]]) }
            contents.append(["role": "user", "parts": userParts])
        }
        throw Failure(message: "Took too many steps")
    }

    // MARK: Screen memory

    private static func memory(period: String?, keywords: String?) -> (String, String?) {
        var out = ""
        var range: String?
        if let period, let w = ScreenMemory.window(in: period) ?? ScreenMemory.window(in: "last " + period) {
            let multi = ScreenMemory.multiDay(w.from, w.to)
            range = ScreenMemory.range(w.from, w.to)
            let spans = ScreenMemory.shared.timeline(from: w.from, to: w.to, limit: multi ? 120 : 40)
            let stamp: (Date) -> String = multi ? ScreenMemory.dayClock : ScreenMemory.clock
            out += spans.isEmpty ? "Nothing recorded for \(w.label) (\(range!)): Mac idle, locked, or memory off.\n"
                : "On screen during \(w.label) (\(range!)), time order, OCR excerpts:\n" + spans.map { s in
                    let mins = Int(s.to.timeIntervalSince(s.from)) / 60
                    let excerpt = s.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }.joined(separator: " | ").prefix(multi ? 120 : 220)
                    return "- \(stamp(s.from))–\(ScreenMemory.clock(s.to))\(mins > 0 ? " (\(mins) min)" : "") \(s.app)\(s.title.isEmpty ? "" : " · " + s.title.prefix(60)): \(excerpt)"
                }.joined(separator: "\n")
        }
        if let keywords, !keywords.isEmpty {
            let hits = ScreenMemory.shared.search(keywords)
            out += hits.isEmpty ? "\nNo matches for “\(keywords)”." : "\nMatches for “\(keywords)”:\n" + hits.map {
                "- [\(ScreenMemory.when($0.entry.t)) · \($0.entry.app)\($0.entry.title.isEmpty ? "" : " · " + $0.entry.title.prefix(50))] \($0.snippet)"
            }.joined(separator: "\n")
        }
        return (out.isEmpty ? "Give a period or keywords." : out, range)
    }

    // MARK: Helpers

    /// `session start --no-trace` + our styled overlay (no `--cursor`: that flashes the default arrow first) → its id; nil if it can't start (the agent still works, just unseen).
    private static func startSession() async -> String? {
        let raw = await cli(["session", "start", "--no-trace", "--name", "butterfly"], timeout: 10)
        guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let id = (o["data"] as? [String: Any])?["session_id"] as? String else { log("no session: \(raw.prefix(200))"); return nil }
        // Butterfly style: violet→pink arrow, pink ripple and highlight, a short pause on each target so the click is visible.
        var overlay = ["cursor-overlay", "enable", "--accent", "#FF6BAD", "--dwell-ms", "220", "--travel-ms", "120,400", "--bow", "1.4"]
        if let art = cursorArt() { overlay += ["--image", art.path, "--hotspot", "4,3", "--size", "1.2"] } else { overlay += ["--fill", "#8C78F7", "--rim", "#FFFFFF", "--size", "1.4"] }
        log("overlay: " + (await cli(overlay, session: id, timeout: 10)).prefix(300))
        return id
    }

    /// The agent cursor PNG (drawn once into Application Support): Design.violet → Design.pink, white rim, pink glow.
    private static func cursorArt() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Butterfly")
        let url = dir.appendingPathComponent("agent-cursor-v2.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pt = NSSize(width: 28, height: 32), scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pt.width * scale), pixelsHigh: Int(pt.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = pt
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: pt.height * scale); ctx.scaleBy(x: scale, y: -scale)   // top-left origin, in points
        let p = CGMutablePath()
        // Arrowhead only, no stem: tip, left edge, inner notch, right wing.
        p.addLines(between: [CGPoint(x: 4, y: 3), CGPoint(x: 4, y: 22), CGPoint(x: 9.5, y: 16.5), CGPoint(x: 18.5, y: 16.5)])
        p.closeSubpath()
        let violet = CGColor(red: 0.55, green: 0.47, blue: 0.97, alpha: 1), pink = CGColor(red: 1, green: 0.42, blue: 0.68, alpha: 1)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: pink.copy(alpha: 0.75))
        ctx.addPath(p); ctx.setFillColor(pink); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [violet, pink] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 4, y: 3), end: CGPoint(x: 15, y: 20), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(p); ctx.setStrokeColor(.white); ctx.setLineWidth(1.6); ctx.setLineJoin(.round); ctx.strokePath()
        gc.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    /// Actions are headless (no focus change): bring the app being worked on to the front so you can watch it.
    private static func bringForward(_ a: [String]) {
        var name: String?
        if a.first == "launch", a.count > 1 { name = a[1] }
        if let i = a.firstIndex(of: "--app"), i + 1 < a.count { name = a[i + 1] }
        guard let name else { return }
        let app = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name
        }
        if let app, !app.isActive { app.activate() }
    }

    private static func describe(_ a: [String]) -> String {
        guard let cmd = a.first else { return "Working…" }
        switch cmd {
        case "snapshot", "find", "get", "is", "list-windows", "list-apps", "list-surfaces": return "Reading the screen…"
        case "click", "double-click", "right-click", "batch": return "Clicking…"
        case "type", "set-value": return "Typing…"
        case "press": return "Pressing \(a.dropFirst().first ?? "keys")…"
        case "launch": return "Opening \(a.dropFirst().first ?? "app")…"
        case "scroll", "scroll-to": return "Scrolling…"
        default: return "\(cmd.capitalized)…"
        }
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        // Half size is plenty to read UI and keeps the request small.
        let w = img.width / 2, h = img.height / 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) }
    }

    /// ~/Library/Logs/Butterfly/agent.log
    private static func log(_ s: String) {
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] == "1" { print("agent:", s) }
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("agent.log")
        let line = Data("\(Date().formatted(.iso8601)) \(s.prefix(2000))\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }
}

/// Synthesized key presses (needs Accessibility, which Butterfly already has).
enum Keys {
    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// System output volume (for ducking music while you talk).
@MainActor
enum SystemAudio {
    static var volume: Int { Int(osa("output volume of (get volume settings)") ?? "") ?? 50 }
    @discardableResult static func setVolume(_ v: Int) -> Int {
        let v = min(100, max(0, v))
        _ = osa("set volume output volume \(v) without output muted")
        return v
    }
    private static func osa(_ source: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
    }
}
