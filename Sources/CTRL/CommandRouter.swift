import AppKit

/// Turns a transcript into an action, using one Jev request (all questions run in parallel).
struct CommandRouter {
    enum Outcome {
        case open(WindowManager.Plan)
        case media(MediaController.Action, preferred: String?)
        case settings(SettingsController.Page, SettingsController.Action)
        case system(SystemController.Action, level: Int?)
        case window(WindowCommands.Action, NSRunningApplication)
        case click(Clicker.Element)
        case file(URL, reveal: Bool)
        case type(String, pressReturn: Bool)
        case startDictation                      // just "type" — the words come next (locked mode)
        case continueTyping(String)              // more dictation after a type command
        case repeatLast                          // "this one too", "again"
        case fileNotFound(String)
        case clickVisual(NSRunningApplication, what: String)   // not in the accessibility tree: find it on a screenshot
        case menu(MenuReader.Item, NSRunningApplication)
        case routine(Routine)
        case unsure(best: InstalledApp?)
        case needAddress
        case notACommand
    }

    static let appThreshold = 0.6     // first app: below this, ask "did you mean…?"
    static let extraThreshold = 0.5   // each extra app/site yes/no
    static let maxSlots = 4

    let client: TypeSafeClient

    /// `menu`: the menu bar of the app that was in front when you pressed Option.
    /// `front`: that app (window commands act on it).
    /// `elements`: clickable things in its window, read while you spoke.
    /// `previous`: the last command you gave (for "this one too"). `dictating`: a type command is in progress.
    @MainActor
    func route(_ transcript: String, menu: MenuReader.Snapshot? = nil, front: NSRunningApplication? = nil, elements: [Clicker.Element] = [],
               previous: String? = nil, dictating: Bool = false) async throws -> Outcome {
        let catalog = AppCatalog.shared
        // Spotlight runs while Jev decides; only used if the answer is "find a file".
        let fileSearch = Task.detached { await Files.search(transcript) }
        defer { fileSearch.cancel() }

        let normalized = URLExtractor.normalize(transcript)
        let regexHits = URLExtractor.candidates(in: transcript)
        // Your vocabulary wins over raw regex hits ("mail.sh" when you said "openmail.sh")…
        let known = Vocabulary.matches(in: transcript).filter { v in
            guard v.contains(".") else { return false }
            // …unless it only appears inside a longer address ("openmail.sh" in "console.openmail.sh").
            let insideLonger = regexHits.contains { $0.hasSuffix("." + v) }
            return !insideLonger || Self.position(of: "site:" + v, in: normalized, strict: true) != nil
        }
        var sites = known
        for s in regexHits where !sites.contains(s) {
            if known.contains(where: { $0.hasSuffix(s) && $0 != s && !$0.hasSuffix("." + s) }) { continue }   // drop fragments like "mail.sh"
            sites.append(s)
        }
        sites = Array(sites.prefix(40))

        // One option list for every slot: apps and websites side by side. Keys are prefixed so they can't collide.
        let apps = catalog.candidates(for: transcript, limit: 254 - sites.count)
        var options: [String: String] = [:]
        for app in apps { options["app:" + app.name] = "the \(app.name) application installed on the Mac" }
        for site in sites { options["site:" + site] = "the website \(site), opened in the browser" }
        guard !options.isEmpty else { return .notACommand }

        var questions: [String: TypeSafeClient.Question] = [
            "intent": .choice("What does the user want the computer to do?", options: [
                "open": "open, launch, show, put, place, or arrange applications and/or websites on screen (domains with any ending such as .com, .sh, .ai, .io)",
                "play_music": "play, start, resume, or put on music, a song, or a podcast",
                "pause_music": "pause, stop, or silence the music or whatever is playing",
                "next_track": "skip to the next song or track",
                "previous_track": "go back to the previous song, or replay the last track",
                "settings": "open a specific System Settings page, check or change a Mac setting (Wi-Fi, Bluetooth, dark mode, battery, storage, display settings, notifications, privacy, keyboard, updates, etc.)",
                "system": "change the volume (louder, quieter, mute, unmute) or screen brightness, lock the screen, put the Mac to sleep, turn the display off, take a screenshot, or empty the Trash",
                "window": "move, snap, resize, center, maximize, minimize, close, or full-screen the current window (or a named app's window), send it to another screen, or hide or quit an app that's already open, or hide all other apps",
                "click": "click, press, tap, or select something visible on screen: a button, link, tab, field, message, item, desktop widget, Dock icon, or menu bar icon (e.g. 'click send', 'press the blue button', 'click the first result', 'click the weather widget')",
                "files": "open a folder (Downloads, Desktop, Documents, iCloud), open the latest download or screenshot, or find / open a specific file or document on the Mac. 'Show me the desktop' means the Desktop folder",
                "type": "type, write, or enter specific words/text into the current text field (e.g. 'type see you at 5', 'write hello world and press enter')",
                "none": "anything else, or nothing actionable",
            ]),
            "windows": .choice("How many windows of the same app does the user ask for? Speech-to-text often writes 'two' as 'to' or 'too'.", options: [
                "1": "one window, or no number mentioned",
                "2": "two windows",
                "3": "three windows",
                "4": "four windows",
            ]),
            "layout": .choice("How does the user want the windows arranged on screen?", options: [
                "none": "no arrangement mentioned",
                "side_by_side": "side by side, next to each other, split screen, left and right",
                "stacked": "stacked, one above the other, top and bottom",
                "maximize": "full screen, maximized, as big as possible",
            ]),
            "target1": .choice("Which application or website does the user mention first?", options: options),
            // Settings branch, asked speculatively in the same request.
            "settings_page": SettingsController.pageQuestion,
            "settings_action": SettingsController.actionQuestion,
            "settings_theme": SettingsController.themeQuestion,
            "system_action": SystemController.actionQuestion,
            "window_action": WindowCommands.question,
            "files_action": Files.actionQuestion,
            "folder": Files.folderQuestion,
            "reveal": Files.revealQuestion,
            "level": SystemController.levelQuestion,
        ]
        if let q = RoutineStore.shared.question { questions["routine"] = q }
        if case .choice(let text, var intents) = questions["intent"]! {
            if let previous {
                intents["repeat"] = "do the previous command (“\(previous)”) again, e.g. 'this one too', 'this one as well', 'again', 'one more time', 'same here', 'do it again'"
            }
            if dictating {
                intents["continue_typing"] = "more words to type: the user is still dictating text after a type command. Anything that isn't clearly a new command for the computer"
            }
            questions["intent"] = .choice(text, options: intents)
        }
        let typeStart = Typer.hasTrigger(transcript) ? Typer.startQuestion(transcript) : nil
        if let typeStart { questions["type_start"] = typeStart.0 }

        // Click branch: the window's own buttons/links are the options.
        var clickOptions: [String: Clicker.Element] = [:]
        if !elements.isEmpty {
            var opts = ["none": "none of these: the thing to click is somewhere else on screen (desktop widget, Dock, menu bar, another window) or not in this list"]
            for (key, (desc, el)) in Clicker.options(elements, for: transcript) {
                clickOptions[key] = el
                opts[key] = desc
            }
            questions["click_target"] = .choice("Which element of the front app's window (\(front?.localizedName ?? "current app")) does the user want to click?", options: opts)
        }

        // Menu branch: the front app's own menu items are the options.
        var menuOptions: [String: MenuReader.Item] = [:]
        if let menu, !menu.items.isEmpty {
            let appName = menu.app.localizedName ?? "the current app"
            let safe = menu.items.filter { !MenuReader.isDangerous($0) }
            var opts: [String: String] = [:]
            for item in MenuReader.candidates(safe, for: transcript, limit: 255) {
                menuOptions[item.key] = item
                opts[item.key] = "the menu command \(item.path.joined(separator: " → "))" + (item.shortcut.map { " (\($0))" } ?? "")
            }
            questions["menu_item"] = .choice("Which \(appName) menu command does the user want to run?", options: opts)
            if case .choice(let text, var intents) = questions["intent"]! {
                intents["menu_command"] = "do an action inside \(appName), the app currently in front, like a menu command (new tab, close tab, save, find, reload, zoom, bold, show sidebar, export, duplicate)"
                questions["intent"] = .choice(text, options: intents)
            }
        }

        // Every other plausible item gets its own yes/no question (parallel, independent).
        // Ordinal "second/third" slots don't work: the model repeats the first item.
        let spoken = normalized
        // App names only count outside web addresses ("console.openmail.sh" ≠ Console + Mail).
        let outsideURLs = URLExtractor.removingAddresses(from: spoken)
        let mentionedApps = apps.filter { Self.mentions(outsideURLs, $0.name) }.prefix(20)
        var checks: [String: String] = [:]   // question key → option key
        for app in mentionedApps { checks["m\(checks.count)"] = "app:" + app.name }
        for site in sites { checks["m\(checks.count)"] = "site:" + site }
        for (q, option) in checks {
            let label = option.hasPrefix("site:") ? "the website \(option.dropFirst(5))" : "the \(option.dropFirst(4)) app"
            questions[q] = .noul("Does the user want \(label) opened, shown, or placed on screen?")
        }

        var state = ["spoken_command": transcript, "normalized": URLExtractor.normalize(transcript)]
        if let previous { state["previous_command"] = previous }
        if dictating { state["mode"] = "the user is dictating text; the last command was a type command" }
        if !sites.isEmpty { state["web_addresses_detected"] = sites.joined(separator: ", ") }
        if !known.isEmpty { state["users_known_sites"] = known.joined(separator: ", ") }

        let response = try await client.systemOne(state: state, questions: questions)

        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            for k in ["intent", "routine", "target1", "windows", "layout", "settings_page", "settings_action", "menu_item", "system_action", "window_action", "click_target", "files_action", "folder", "level"] {
                if let a = response.choice(k) { print("  \(k): \(a.choice) (\(String(format: "%.2f", a.confidence)))") }
            }
            for (q, option) in checks.sorted(by: { $0.key < $1.key }) {
                print("  \(option): \(String(format: "%.2f", response.noul(q) ?? -1))")
            }
        }

        var intent = response.choice("intent")?.choice
        // "Type …" / "Dictate …" at the start is always typing, however long the text is.
        if Typer.startsWithTrigger(transcript) { intent = "type" }
        if intent == "repeat" { return previous == nil ? .notACommand : .repeatLast }
        if intent == "continue_typing" {
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .notACommand : .continueTyping(text)
        }
        // Routines first: your own phrases beat generic intents.
        if let r = response.choice("routine"), r.choice != "none", r.confidence >= 0.6, let routine = RoutineStore.shared.routine(named: r.choice) {
            return .routine(routine)
        }
        if intent == "menu_command", let menu, let a = response.choice("menu_item"), let item = menuOptions[a.choice] {
            return a.confidence >= 0.4 ? .menu(item, menu.app) : .notACommand
        }
        if intent == "type", dictating, !Typer.hasTrigger(transcript) {
            return .continueTyping(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if intent == "type" {
            if let a = response.choice("type_start"), a.confidence >= 0.5, let i = typeStart?.1[a.choice],
               let t = Typer.extract(transcript, from: i) {
                return .type(t.text, pressReturn: t.pressReturn)
            }
            guard let t = Typer.extract(transcript) else { return Typer.hasTrigger(transcript) ? .startDictation : .notACommand }
            return .type(t.text, pressReturn: t.pressReturn)
        }
        if intent == "files", let a = response.choice("files_action"), let action = Files.Action(rawValue: a.choice) {
            let reveal = (response.noul("reveal") ?? 0) >= 0.5
            let folder = response.choice("folder").flatMap { Files.folder($0.choice) }
            switch action {
            case .openFolder:
                guard let folder, let url = folder.url() else { return .notACommand }
                return .file(url, reveal: false)
            case .latest:
                guard let folder else { return .notACommand }
                guard let url = Files.latest(in: folder) else { return .fileNotFound("Nothing in \(folder.title)") }
                return .file(url, reveal: reveal)
            case .search:
                let hits = await fileSearch.value
                guard !hits.isEmpty else { return .fileNotFound("No file matches") }
                return try await pickFile(transcript, from: hits, reveal: reveal)
            }
        }
        if intent == "click" {
            if let a = response.choice("click_target"), a.choice != "none", a.confidence >= 0.5, let el = clickOptions[a.choice] { return .click(el) }
            guard let app = front ?? menu?.app else { return .notACommand }
            return .clickVisual(app, what: transcript)
        }
        if intent == "window", let a = response.choice("window_action"), let action = WindowCommands.Action(rawValue: a.choice) {
            // "quit slack" → Slack; "snap this left" → the app in front.
            let named = mentionedApps.compactMap { app in
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
            }.first
            guard let app = named ?? front ?? menu?.app else { return .notACommand }
            return .window(action, app)
        }
        if intent == "system", let a = response.choice("system_action"), let action = SystemController.Action(rawValue: a.choice) {
            let jevLevel = response.choice("level").flatMap { $0.choice == "none" ? nil : $0.choice }
            return .system(action, level: SystemController.level(in: normalized, jev: jevLevel))
        }
        if intent == "settings", let p = response.choice("settings_page"), let page = SettingsController.page(p.choice) {
            // "open system settings" / "open settings" with nothing else → just the app.
            let rest = spoken.replacingOccurrences(of: #"\b(open|launch|show|me|the|my|system|settings?|preferences|app|please)\b"#, with: "", options: .regularExpression)
            if rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty, let app = SettingsController.settingsApp {
                return .open(.init(targets: [.app(app)], windowsEach: 1, layout: .none))
            }
            var action = SettingsController.Action(rawValue: response.choice("settings_action")?.choice ?? "open") ?? .open
            if page.toggle == .darkMode {
                switch response.choice("settings_theme")?.choice {
                case "dark": action = .turnOn
                case "light": action = .turnOff
                case "auto": action = .auto
                default: break
                }
            }
            return .settings(page, action)
        }
        if let intent, let action = MediaController.Action(rawValue: intent) {
            let preferred = spoken.contains("spotify") ? "Spotify" : (spoken.contains("apple music") || spoken.contains("music app")) ? "Music" : nil
            return .media(action, preferred: preferred)
        }
        guard intent == "open" else { return .notACommand }

        // First item: the choice question (works even when speech misspells the name).
        var picked: [(option: String, position: Int)] = []
        if let a = response.choice("target1") {
            let appName = a.choice.hasPrefix("app:") ? String(a.choice.dropFirst(4)) : nil
            let onlyInsideURL = appName.map { !sites.isEmpty && !Self.mentions(outsideURLs, $0) } ?? false
            if onlyInsideURL {
                // e.g. "Console" picked from "console.openmail.sh": ignore, the sites below decide.
            } else if let appName, a.confidence < Self.appThreshold {
                return .unsure(best: catalog.app(named: appName))
            } else {
                picked.append((a.choice, Self.position(of: a.choice, in: spoken) ?? -1))
            }
        }
        // Everything else the user asked for.
        for (q, option) in checks where (response.noul(q) ?? 0) >= Self.extraThreshold {
            guard !picked.contains(where: { $0.option == option }) else { continue }
            picked.append((option, Self.position(of: option, in: spoken) ?? Int.max))
        }
        picked.sort { $0.position < $1.position }   // spoken order = left → right

        var targets: [WindowManager.Target] = []
        for (option, _) in picked.prefix(Self.maxSlots) {
            if option.hasPrefix("site:"), let url = URLExtractor.url(for: String(option.dropFirst(5))) {
                targets.append(.site(url))
            } else if let app = catalog.app(named: String(option.dropFirst(4))) {
                targets.append(.app(app))
            }
        }

        if targets.isEmpty {
            if let site = sites.first, let url = URLExtractor.url(for: site) { targets = [.site(url)] }
            else { return .needAddress }
        }

        let windows = Int(response.choice("windows")?.choice ?? "1") ?? 1
        let layout = WindowManager.Layout(rawValue: response.choice("layout")?.choice ?? "none") ?? .none
        return .open(.init(targets: targets, windowsEach: windows, layout: layout))
    }

    /// Is this app name (or one of its words, 3+ letters) in the spoken text?
    /// Second quick request: which Spotlight hit is the file they meant?
    @MainActor
    private func pickFile(_ transcript: String, from hits: [Files.Hit], reveal: Bool) async throws -> Outcome {
        var opts = ["none": "none of these files is what the user asked for"]
        for (i, h) in hits.enumerated() { opts["f\(i)"] = Files.describe(h.url) }
        let r = try await client.systemOne(
            state: ["spoken_command": transcript],
            questions: ["file": .choice("Which file does the user want? If several match equally (e.g. many invoices), pick the most recently modified one.", options: opts)])
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1", let a = r.choice("file") {
            print("  file: \(a.choice) (\(String(format: "%.2f", a.confidence))) of \(hits.count) hits")
        }
        guard let a = r.choice("file"), a.choice != "none",
              let i = Int(a.choice.dropFirst()), hits.indices.contains(i) else { return .fileNotFound("Couldn't find that file") }
        // Low confidence usually means "several fit": take the newest of what Jev considered.
        if a.confidence < 0.4 {
            let likely = a.probabilities.filter { $0.key != "none" && $0.value >= 0.1 }.compactMap { Int($0.key.dropFirst()) }.filter(hits.indices.contains)
            func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
            if let best = likely.map({ hits[$0].url }).max(by: { modified($0) < modified($1) }) { return .file(best, reveal: reveal) }
        }
        return .file(hits[i].url, reveal: reveal)
    }

    /// Second step for clicks not in the accessibility tree: screenshot + Jev Box.
    /// Returns a global (top-left origin) point, or nil when Jev says it isn't visible.
    @MainActor
    func locate(_ what: String, in app: NSRunningApplication) async throws -> CGPoint? {
        let shots = try await Clicker.screenshots(of: app)
        guard !shots.isEmpty else { return nil }
        // Every display in one request: a Box + "is it here?" per screen, then click the most likely.
        var state = ["spoken_command": what]
        var questions: [String: TypeSafeClient.Question] = [:]
        var images: [TypeSafeClient.Image] = []
        for (i, shot) in shots.enumerated() {
            let ref = "img-\(i)-" + UUID().uuidString
            state["screen_\(i)"] = ref
            images.append(.init(ref: ref, jpeg: shot.jpeg))
            questions["target_\(i)"] = .box("the on-screen element in `screen_\(i)` that the user wants to click, per `spoken_command`. `screen_\(i)` is a whole display: windows, desktop widgets, Dock, and menu bar")
            questions["visible_\(i)"] = .noul("Is the thing the user wants to click (per `spoken_command`) visible in `screen_\(i)`?")
        }
        let response = try await client.systemOne(state: state, questions: questions, images: images)
        let best = shots.indices.max { (response.noul("visible_\($0)") ?? 0) < (response.noul("visible_\($1)") ?? 0) }!
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            for i in shots.indices {
                print("  screen \(i): visible=\(String(format: "%.2f", response.noul("visible_\(i)") ?? -1)) box=\(response.box("target_\(i)").map { "\($0.box)" } ?? "-")")
            }
        }
        guard let b = response.box("target_\(best)"), (response.noul("visible_\(best)") ?? 0) >= 0.5 else { return nil }
        return Clicker.point(in: shots[best], box: b.box)
    }

    private static func mentions(_ spoken: String, _ name: String) -> Bool {
        let words = Set(spoken.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let nameWords = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return spoken.contains(name.lowercased()) || nameWords.contains { $0.count >= 3 && words.contains($0) }
    }

    /// Where an option appears in the spoken text, for left → right ordering.
    /// Matches whole tokens so "openmail.sh" isn't found inside "console.openmail.sh".
    private static func position(of option: String, in spoken: String, strict: Bool = false) -> Int? {
        let needle = String(option.drop { $0 != ":" }.dropFirst()).lowercased()
        let pattern = #"(?<![a-z0-9.])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![a-z0-9])"#
        guard let r = spoken.range(of: pattern, options: .regularExpression) else {
            if strict { return nil }
            return spoken.range(of: needle).map { spoken.distance(from: spoken.startIndex, to: $0.lowerBound) }
        }
        return spoken.distance(from: spoken.startIndex, to: r.lowerBound)
    }
}
