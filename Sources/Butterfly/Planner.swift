import AppKit
import Foundation

/// Third layer, for requests nothing else understood: Gemini sees what's on screen (app, window, menus, buttons, text)
/// and writes a short plan out of primitives Butterfly already has — normal commands, URLs, typing, keys, AppleScript.
/// The plan runs step by step; when it worked, it's saved as a skill (see `SkillStore`) so the same kind of request
/// never needs planning again.
@MainActor
enum Planner {
    struct Step: Codable, Sendable {
        var `do`: String                 // command | open_url | type | keys | applescript | open_settings | wait | say | create_event | create_reminder
        var text: String?                // command / type / say
        var enter: Bool?                 // type: press return after
        var url: String?                 // open_url
        var combo: String?               // keys: "command+shift+4"
        var source: String?              // applescript
        var ms: Int?                     // wait
        var title: String?               // create_event / create_reminder
        var start: String?               // create_event: when, as words ("Friday at 7pm", "10.21 17:30")
        var durationMinutes: Int?        // create_event
        var allDay: Bool?                // create_event
        var location: String?            // create_event
        var notes: String?               // create_event
        var calendar: String?            // create_event: only if the user named one
        var due: String?                 // create_reminder: when, as words; nil for no time
    }

    struct Plan: Sendable {
        var steps: [Step]
        var summary: String
        var confirm: String?             // ask before running (destructive / irreversible)
        var clarify: String?             // model can't act: a question or a one-line answer
        var skill: (name: String, pattern: String, steps: [Step])?
        var recap: (title: String, range: String, items: [(time: String, app: String, text: String)])?   // "what did I do" timeline
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let model = "gemini-3.8-flash"

    // Set by the notch model.
    static var runCommand: (@MainActor (String) async -> String)?
    static var openURL: (@MainActor (URL) -> Void)?
    static var progress: (@MainActor (String) -> Void)?
    /// OCR of the front window from the last `plan` call, for steps that need the details written there.
    static var lastScreenText: String?

    // MARK: Plan

    /// What just happened, so "no, not that — do this" can be understood and the skill corrected.
    struct Previous: Sendable {
        var request: String
        var steps: [Step]
        var result: String          // "done", "stopped: …", "answered: …"
        var skillPattern: String?   // the skill that ran / was learned
    }

    static func plan(_ request: String, app: NSRunningApplication?, menu: MenuReader.Snapshot?, elements: [Clicker.Element], previous: Previous? = nil, key: String) async throws -> Plan {
        let screen = await ScreenReader.text(of: app)
        lastScreenText = screen?.text
        try Task.checkCancellation()   // started speculatively beside the router; stop here when the router won
        let f = DateFormatter(); f.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let apps = AppCatalog.shared.apps.map(\.name).prefix(120).joined(separator: ", ")
        let menus = (menu?.items ?? []).map(\.key).prefix(160).joined(separator: " | ")
        let buttons = elements.map { "\($0.label) (\($0.role.replacingOccurrences(of: "AX", with: "")))" }.prefix(80).joined(separator: " | ")
        let window = app.map { windowTitle($0) } ?? ""
        let learned = SkillStore.shared.skills.prefix(20).map { "“\($0.pattern)”" }.joined(separator: ", ")
        // The app the request is about: the one named in it ("…the Slack icon…"), else the one in front.
        let named = NSWorkspace.shared.runningApplications.first { a in
            guard let n = a.localizedName, n.count > 2, a.activationPolicy == .regular else { return false }
            return request.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: n) + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let target = named ?? app
        let known = AppMap.shared.relevant(request, in: target)
        var knownBlock = ""
        if let target, let m = AppMap.shared.map(for: target), m.settingsCrawled {
            var panes: [String] = []
            for p in m.entries where p.kind == "setting" { if let n = p.path.components(separatedBy: " > ").dropFirst().first, !panes.contains(n), panes.count < 30 { panes.append(n) } }
            knownBlock = "\n\(m.name)'s Settings were read completely (\(m.entries.filter { $0.kind == "setting" }.count) controls in panes: \(panes.joined(separator: ", "))). "
            knownBlock += known.isEmpty ? "None of them match this request: the app has no such setting — do not invent one."
                : "Entries matching the request (they are NOT on screen now; reach a \"Settings > …\" entry with open_settings first):\n" + known.map { "- " + $0 }.joined(separator: "\n")
            knownBlock += "\nClick only control labels that appear verbatim in the entries above. If the setting the user wants is not among them, it does not exist in \(m.name): leave steps empty and use \"clarify\" to say so, naming the closest real option or a macOS-level alternative (e.g. a menu-bar manager app).\n"
        } else if !known.isEmpty {
            knownBlock = "\nKnown in \(target?.localizedName ?? "this app") (from a past read of its menus and scripting):\n" + known.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        if let named, named != app { knownBlock += "The request is about \(named.localizedName ?? "another app"), which is not in front: start with {\"do\":\"command\",\"text\":\"open \(named.localizedName ?? "")\"} and a wait.\n" }
        var previousBlock = ""
        if let w = ScreenMemory.window(in: request) {
            let spans = ScreenMemory.shared.timeline(from: w.from, to: w.to)
            if spans.isEmpty {
                previousBlock += "\nScreen memory has nothing for \(w.label) (\(ScreenMemory.clock(w.from))–\(ScreenMemory.clock(w.to))): the Mac was idle, locked, or memory was off. Say so in one \"say\" step.\n"
            } else {
                previousBlock += "\nWhat was on screen during \(w.label) (\(ScreenMemory.clock(w.from))–\(ScreenMemory.clock(w.to))), in time order; OCR text is a noisy excerpt:\n"
                previousBlock += spans.map { s in
                    let secs = Int(s.to.timeIntervalSince(s.from))
                    let dur = secs < 60 ? "" : " (\(secs / 60) min)"
                    let excerpt = s.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 3 }.joined(separator: " | ").prefix(220)
                    return "- \(ScreenMemory.clock(s.from))–\(ScreenMemory.clock(s.to))\(dur) \(s.app)\(s.title.isEmpty ? "" : " · " + s.title.prefix(60)): \(excerpt)"
                }.joined(separator: "\n")
                previousBlock += "\nFor \"what did I do / what was I working on\": instead of steps, fill \"recap\": {\"title\":\"Last 5 minutes\",\"items\":[{\"time\":\"14:27\",\"app\":\"Dia\",\"text\":\"Reviewed OpenMail pull requests on GitHub\"}, …]} — 3 to 7 items in time order, merge adjacent moments in the same app into one activity, \"app\" exactly as named in the list, \"text\" ≤ 55 characters, concrete (which page, chat, file), no filler. Leave \"steps\" empty. If they ask about one specific thing in that period, answer that with a \"say\" step instead.\n"
            }
        }
        let overview = ScreenMemory.window(in: request) != nil && request.range(of: #"(?i)(what did i do|what was i doing|been doing|working on|what have i done|summar|what happened)"#, options: .regularExpression) != nil
        let seen = overview ? [] : ScreenMemory.shared.search(request)
        var frames: [Data] = []
        if !seen.isEmpty {
            previousBlock += "\nSeen on screen earlier (screen memory; OCR, may be noisy) — for questions about something the user saw, answer from this with one \"say\" step, quoting the value and when/where it was seen:\n"
            previousBlock += seen.enumerated().map { "- (\($0.offset + 1)) [\(ScreenMemory.when($0.element.entry.t)) · \($0.element.entry.app)\($0.element.entry.title.isEmpty ? "" : " · " + $0.element.entry.title.prefix(50))] \($0.element.snippet)" }.joined(separator: "\n") + "\n"
            // The frames themselves: the model reads the exact value from the picture, not from OCR.
            for h in seen.prefix(3) { if let d = ScreenMemory.frame(h.entry) { frames.append(d) } }
            if !frames.isEmpty { previousBlock += "The actual screenshots of entries (1)…(\(frames.count)) are attached in that order. Read exact values (prices, numbers, names) from the screenshot; the OCR text above is only a guide.\n" }
        }
        if let p = previous {
            previousBlock = """

            A moment ago the user asked: “\(p.request)”
            What was done: \(p.steps.isEmpty ? "nothing" : p.steps.map(describe).joined(separator: " → ")) (\(p.result))
            The new sentence is a correction or follow-up to that. Work out what they want now (e.g. "no, the other one", "not Advanced, Notifications", "do it in Discord instead", "undo that"). \
            If they say the previous action was wrong and it changed something, first revert it (toggle the same control back) and then do the right thing. \
            For "skill", use the ORIGINAL request wording (“\(p.request)”) as the pattern with the CORRECTED steps, so next time that request goes right at once.

            """
        }

        let prompt = """
        You control the user's Mac. Turn the spoken request into a short plan of steps. Act, don't explain. Reply with JSON only.

        Now: \(f.string(from: Date())). Front app: \(app?.localizedName ?? "none"). Window: \(window)
        Installed apps: \(apps)
        Menu items of the front app: \(menus.isEmpty ? "-" : menus)
        Clickable elements in the front window: \(buttons.isEmpty ? "-" : buttons)
        \(knownBlock)\(previousBlock)
        Text on screen (OCR, may be noisy):
        ---
        \(screen.map { String($0.text.prefix(3500)) } ?? "-")
        ---

        Step types (one object each):
        {"do":"command","text":"…"}  a plain Mac voice command the assistant already understands: "open Slack", "open the Downloads folder", \
        "click Send", "click the search field", "press enter", "new tab", "close this tab", "switch to Safari", "move this window to the left half", \
        "set volume to 30", "play music", "set a timer for 5 minutes", "show desktop", "lock the screen", "take a screenshot", menu items by name ("File > Export…"), \
        "scroll down", "go back", "select all", "copy", "paste", "search for X on Google / YouTube / LinkedIn".
        {"do":"open_url","url":"https://…"}  open a page in the default browser (good for site searches and deep links; URL-encode queries).
        {"do":"type","text":"…","enter":false}  type into the focused field.
        {"do":"keys","combo":"command+shift+4"}  a keyboard shortcut (modifiers: command, shift, option, control; keys: letters, digits, enter, escape, tab, space, delete, arrows, f1-f12).
        {"do":"applescript","source":"…"}  only when nothing above can do it (Finder/system scripting, app automation, reading data). Never `do shell script` (it is removed), and never delete, empty trash, send mail/messages, or pay unless the user explicitly asked for exactly that.
        {"do":"open_settings"}  opens the front app's Settings/Preferences window (always use this instead of clicking a Settings menu).
        {"do":"wait","ms":800}  let an app/page open before the next step (apps ~1000, web pages ~1500).
        {"do":"say","text":"…"}  tell the user something short (an answer, a result).
        {"do":"create_event","title":"Dinner with Tom","start":"Friday at 7pm","durationMinutes":60,"allDay":false,"location":"","notes":"","calendar":""}  add to the user's calendar (meetings, invites, appointments, flights — anything with a date). "start": copy the date/time WORDS from the request or the screen exactly as written ("10.21 17:30", "rytoj 17:30", "tomorrow at 5") — never compute dates yourself; the app does. "allDay" only for birthdays/holidays. "calendar" only if the user named one. Title in the message's language.
        {"do":"create_reminder","title":"Call mom","due":"tomorrow at 5"}  add a to-do to Reminders ("remind me to…", "add to my list"); "due" as words, or "" for no time.
        For "put this/the last message/this email in my calendar", take the details (what, when, where, who) from the text on screen: the item the user means is the one they named, else the newest message (bottom-most in a chat). Ignore menus and buttons in the OCR text.

        Rules:
        - Prefer "command" steps; they're robust. Use open_url over clicking around a website. Add a wait after opening apps/pages.
        - To change a setting listed under "Known in …" as "Settings > <pane> > <control>", the Settings window is NOT open yet — the plan must start with {"do":"open_settings"} → wait 900 → {"do":"command","text":"click <pane>"} → wait 400 → {"do":"command","text":"click <control>"}; for pop-ups, click the pop-up, wait 300, then click the wanted choice. Finish with {"do":"keys","combo":"escape"} only for apps whose settings are a dialog inside the window (Slack, Discord).
        - The request is one unit: a sentence like "open Notes and write hello" is open Notes → wait → type.
        - If it's a question about what's on screen, answer with one "say" step. If it can't be done or is unclear, leave steps empty and set "clarify" to a short question or reason.
        - If a step is destructive or irreversible (deleting, sending, purchases, emptying trash, quitting with unsaved work), set "confirm" to a one-line description; the user will say yes first.
        - If the user is teaching rather than asking ("when I say X, do Y", "from now on X means Y", "remember: X is Y"), return the skill with pattern X and the steps for Y, and leave "steps" empty unless they also want it done now.
        - Generalise what you did into a reusable skill: "pattern" is the request in its shortest natural wording with every variable part as a {slot} (the thing searched, the app, the text, the person, the amount — anything that could differ next time). Drop filler like "once you're there", "please", "for me". "steps" is the same plan with {slot} in place of the values. Use {slot|url} inside URLs for URL-encoding. Omit "skill" if the request is one-off (depends on exactly what's on screen now) or is already covered by a learned skill: \(learned.isEmpty ? "none" : learned).

        Output JSON: {"summary":"3-6 words of what you did","steps":[…],"confirm":null,"clarify":null,"skill":{"name":"…","pattern":"…","steps":[…]} or null,"recap":null}

        The user said: “\(request)”
        """
        var reqParts: [[String: Any]] = [["text": prompt]]
        for d in frames { reqParts.append(["inlineData": ["mimeType": "image/jpeg", "data": d.base64EncodedString()]]) }
        let body: [String: Any] = [
            "contents": [["parts": reqParts]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 4096, "responseMimeType": "application/json", "thinkingConfig": ["thinkingBudget": 512]],
        ]
        try Task.checkCancellation()
        let d = try await MeetingTranscriber.request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 40)
        try Task.checkCancellation()
        let parts = (((d["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] == "1" { print("  planner raw:", text); try? prompt.write(toFile: "/tmp/butterfly-plan-prompt.txt", atomically: true, encoding: .utf8) }
        let obj = Self.json(text)
        guard !obj.isEmpty else { throw Failure(message: "The planner didn't answer") }
        var plan = try parse(obj)
        if let w = ScreenMemory.window(in: request), plan.recap != nil { plan.recap?.range = "\(ScreenMemory.clock(w.from))–\(ScreenMemory.clock(w.to))" }
        return harden(plan, request: request)
    }

    // MARK: Safety

    /// Values for a learned skill's {slots} from a request the regex didn't catch: one tiny Gemini call, no thinking.
    static func fillSlots(_ slots: [String], pattern: String, request: String, key: String) async throws -> [String: String] {
        guard !slots.isEmpty else { return [:] }
        let prompt = """
        A learned voice skill has the pattern “\(pattern)”. The user now said: “\(request)”.
        Give the value of each slot as the user meant it (verbatim words where possible, in their language). Reply with JSON only: {\(slots.map { "\"\($0)\":\"…\"" }.joined(separator: ","))}
        """
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 256, "responseMimeType": "application/json", "thinkingConfig": ["thinkingBudget": 0]],
        ]
        let d = try await MeetingTranscriber.request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 15)
        let parts = (((d["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let obj = json(parts.compactMap { $0["text"] as? String }.joined())
        var out: [String: String] = [:]
        for s in slots { if let v = (obj[s] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { out[s] = v } }
        guard out.count == slots.count else { throw Failure(message: "Couldn't work out the details") }
        return out
    }

    /// Why a step counts as destructive, or nil. Code decides this, not the prompt: a model that forgets to set
    /// "confirm" must still not quit apps, send mail or empty the trash unasked.
    nonisolated static func danger(of s: Step) -> String? {
        switch s.do {
        case "applescript":
            guard let src = s.source?.lowercased() else { return nil }
            if src.contains("do shell script") { return "runs a shell command" }
            for w in ["delete", "empty trash", "empty the trash", "send", "remove", "erase", "quit", "shutdown", "shut down", "restart", "kill"] where src.range(of: #"\b"# + w + #"\b"#, options: .regularExpression) != nil { return "script: \(w)" }
            if src.range(of: #"\brm\b"#, options: .regularExpression) != nil { return "script: rm" }
        case "command":
            guard let t = s.text?.lowercased() else { return nil }
            for w in ["delete", "empty trash", "empty the trash", "send", "log out", "quit", "shut down", "shutdown", "pay", "purchase", "buy"] where t.range(of: #"\b"# + w + #"\b"#, options: .regularExpression) != nil { return "\(w)" }
        case "keys":
            let c = (s.combo ?? "").lowercased().replacingOccurrences(of: "cmd", with: "command").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "backspace", with: "delete")
            if c == "command+q" || c == "command+delete" || c == "command+shift+delete" { return "press \(c)" }
        default: break
        }
        return nil
    }

    /// Shell scripts are out unless the user literally asked for a terminal/shell/script; anything else destructive
    /// gets a confirmation question if the model didn't add one.
    nonisolated static func harden(_ plan: Plan, request: String) -> Plan {
        var p = plan
        let shellAllowed = request.range(of: #"(?i)\b(terminal|shell|script)\b"#, options: .regularExpression) != nil
        let stripped = p.steps.filter { $0.do == "applescript" && !shellAllowed && ($0.source?.lowercased().contains("do shell script") ?? false) }
        if !stripped.isEmpty {
            p.steps.removeAll { s in stripped.contains { $0.source == s.source } }
            p.summary += " · skipped a shell command"
            if p.steps.isEmpty, p.clarify == nil { p.clarify = "That needs a shell command; say “in the terminal” if you really want it run." }
        }
        if let skill = p.skill { p.skill = (skill.name, skill.pattern, skill.steps.filter { !($0.do == "applescript" && !shellAllowed && ($0.source?.lowercased().contains("do shell script") ?? false)) }) }
        let risky = p.steps.compactMap { s in danger(of: s).map { (s, $0) } }
        if !risky.isEmpty, p.confirm == nil {
            p.confirm = "This will " + risky.prefix(3).map { describe($0.0) }.joined(separator: ", then ") + (risky.count > 3 ? " and more" : "") + ". Go ahead?"
        }
        return p
    }

    static func windowTitle(_ app: NSRunningApplication) -> String {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return "" }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return (title as? String) ?? ""
    }

    /// Lenient: strips ```json fences, finds the outer braces.
    private static func json(_ s: String) -> [String: Any] {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b,
              let d = String(s[a...b]).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    nonisolated static func steps(_ any: Any?) -> [Step] {
        guard let arr = any as? [[String: Any]], let d = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return (try? JSONDecoder().decode([Step].self, from: d)) ?? []
    }
    /// `--plan-check`: a JSON array of steps from the command line.
    nonisolated static func steps(json s: String) -> [Step] {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return [] }
        return steps(o)
    }

    private static func parse(_ o: [String: Any]) throws -> Plan {
        var plan = Plan(steps: steps(o["steps"]), summary: (o["summary"] as? String ?? "Done").trimmingCharacters(in: .whitespacesAndNewlines))
        plan.confirm = (o["confirm"] as? String)?.nilIfEmpty
        plan.clarify = (o["clarify"] as? String)?.nilIfEmpty
        if let sk = o["skill"] as? [String: Any], let name = sk["name"] as? String, let pattern = sk["pattern"] as? String, pattern.contains("{") || !steps(sk["steps"]).isEmpty {
            let s = steps(sk["steps"])
            if !s.isEmpty { plan.skill = (name, pattern, s) }
        }
        if let r = o["recap"] as? [String: Any], let items = r["items"] as? [[String: Any]], !items.isEmpty {
            let list = items.compactMap { i -> (String, String, String)? in
                guard let text = (i["text"] as? String)?.nilIfEmpty else { return nil }
                return ((i["time"] as? String ?? "").trimmingCharacters(in: .whitespaces), (i["app"] as? String ?? "").trimmingCharacters(in: .whitespaces), text)
            }
            if !list.isEmpty { plan.recap = ((r["title"] as? String)?.nilIfEmpty ?? "Recap", "", list.prefix(7).map { $0 }) }
        }
        return plan
    }

    // MARK: Run

    /// `verified`: every click step was checked against the accessibility tree (a toggle flipped, a button existed),
    /// or there were no clicks. Only a verified run is worth saving as a skill.
    struct Outcome { var ok: Bool; var said: [String]; var failed: String?; var verified = true; var created: [String] = [] }

    /// Set by the notch model: the state of the control a "click X" step names (found? on/off value for toggles).
    static var readToggle: (@MainActor (String) -> (found: Bool, value: Int?))?

    /// "click Dark mode" / "turn on Notifications" → the label; nil for commands that aren't clicks.
    nonisolated static func clickLabel(_ command: String) -> String? {
        guard let m = command.firstMatch(of: #/(?i)^\s*(?:click|press|tap|toggle|check|uncheck|tick|untick|select|enable|disable|turn on|turn off)\s+(?:the\s+)?(.+?)\s*(?:\s(?:button|checkbox|check box|toggle|switch|option|tab))?\s*$/#) else { return nil }
        let label = String(m.1).trimmingCharacters(in: .whitespaces)
        // "press enter", "select all" are keys/edits, not controls.
        if label.range(of: #"(?i)^(enter|return|escape|tab|space|delete|all|command.*|cmd.*|option.*|control.*|shift.*|f\d+|up|down|left|right)$"#, options: .regularExpression) != nil { return nil }
        return label.isEmpty ? nil : label
    }

    static func run(_ steps: [Step], app: NSRunningApplication?, request: String = "") async -> Outcome {
        var said: [String] = []
        var verified = true
        var created: [String] = []
        // The screen text the plan was made from: create_event reads a time the model may have dropped from it.
        var screenText: String? = lastScreenText
        if screenText == nil, steps.contains(where: { $0.do == "create_event" || $0.do == "create_reminder" }) { screenText = await ScreenReader.text(of: app)?.text }
        for (i, s) in steps.enumerated() {
            if Task.isCancelled { return Outcome(ok: false, said: said, failed: "cancelled", verified: false, created: created) }
            progress?("\(i + 1)/\(steps.count) · \(describe(s))")
            switch s.do {
            case "command":
                guard let t = s.text?.nilIfEmpty, let run = runCommand else { continue }
                let label = clickLabel(t)
                let before = label.flatMap { readToggle?($0) }
                let r = await run(t)
                if r.hasPrefix("failed") { return Outcome(ok: false, said: said, failed: "\(t): \(r)", verified: false, created: created) }
                if let label, let before {
                    if !before.found { verified = false }   // clicked by sight or elsewhere: can't be sure
                    else if let was = before.value {
                        try? await Task.sleep(for: .milliseconds(250))
                        let after = readToggle?(label)
                        if after?.value == was { return Outcome(ok: false, said: said, failed: "“\(label)” didn't change", verified: false, created: created) }
                    }
                }
            case "open_url":
                guard let u = s.url.flatMap(URL.init) else { return Outcome(ok: false, said: said, failed: "bad URL", verified: false, created: created) }
                openURL?(u)
                try? await Task.sleep(for: .milliseconds(600))
            case "type":
                guard let t = s.text else { continue }
                try? await Task.sleep(for: .milliseconds(150))
                await Typer.type(t, pressReturn: s.enter ?? false)
            case "keys":
                guard let c = s.combo, let combo = KeyPress.parse("press " + c.replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: "-", with: " ")) else {
                    return Outcome(ok: false, said: said, failed: "unknown keys \(s.combo ?? "")", verified: false, created: created)
                }
                await KeyPress.perform(combo, in: NSWorkspace.shared.frontmostApplication)
            case "applescript":
                guard let src = s.source?.nilIfEmpty else { continue }
                var err: NSDictionary?
                let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
                if let err { return Outcome(ok: false, said: said, failed: (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error", verified: false, created: created) }
                if let v = out?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, steps.count == 1 { said.append(v) }
            case "open_settings":
                let front = NSWorkspace.shared.frontmostApplication ?? app
                var done = false
                if let front, let snap = MenuReader.snapshot(of: front),
                   let item = snap.items.first(where: { $0.path.count == 2 && ($0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences")) }) {
                    done = await MenuReader.press(item, in: front)
                }
                if !done { front?.activate(); try? await Task.sleep(for: .milliseconds(120)); Keys.press(43, flags: .maskCommand) }   // ⌘,
                try? await Task.sleep(for: .milliseconds(700))
            case "wait":
                try? await Task.sleep(for: .milliseconds(min(5000, max(100, s.ms ?? 800))))
            case "say":
                if let t = s.text?.nilIfEmpty { said.append(t) }
            case "create_event", "create_reminder":
                let source = screenText ?? ""
                do {
                    let c = s.do == "create_event"
                        ? try await CalendarWriter.createEvent(title: s.title ?? "", start: s.start ?? "", durationMinutes: s.durationMinutes, location: s.location, notes: s.notes, calendar: s.calendar, allDay: s.allDay ?? false, source: source, request: request)
                        : try await CalendarWriter.createReminder(title: s.title ?? "", due: s.due, source: source)
                    created.append(c.id)
                    said.append(c.text)
                } catch {
                    return Outcome(ok: false, said: said, failed: error.localizedDescription, verified: false, created: created)
                }
            default:
                continue
            }
        }
        return Outcome(ok: true, said: said, failed: nil, verified: verified, created: created)
    }

    /// Every field a step carries, for debug printing.
    nonisolated static func detail(_ s: Step) -> String {
        switch s.do {
        case "create_event": "“\(s.title ?? "")” start=\(s.start ?? "") \(s.durationMinutes ?? 60)m" + (s.allDay == true ? " all-day" : "") + (s.location?.nilIfEmpty.map { " @ \($0)" } ?? "") + (s.calendar?.nilIfEmpty.map { " cal=\($0)" } ?? "") + (s.notes?.nilIfEmpty.map { " notes=\($0.prefix(40))" } ?? "")
        case "create_reminder": "“\(s.title ?? "")” due=\(s.due ?? "")"
        default: s.text ?? s.url ?? s.combo ?? s.source ?? s.ms.map(String.init) ?? ""
        }
    }

    nonisolated static func describe(_ s: Step) -> String {
        switch s.do {
        case "command": s.text ?? ""
        case "open_url": URL(string: s.url ?? "")?.host ?? "open page"
        case "type": "type “\((s.text ?? "").prefix(30))”"
        case "keys": "press \(s.combo ?? "")"
        case "applescript": "run script"
        case "wait": "wait"
        case "open_settings": "open settings"
        case "say": s.text ?? ""
        case "create_event": "add “\(s.title ?? "event")” to the calendar"
        case "create_reminder": "remind “\(s.title ?? "")”"
        default: s.do
        }
    }
}
