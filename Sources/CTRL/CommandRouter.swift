import AppKit

/// Turns a transcript into an action, using one Jev request (all questions run in parallel).
struct CommandRouter {
    enum Outcome {
        case open(WindowManager.Plan)
        case media(MediaController.Action, preferred: String?)
        case settings(SettingsController.Page, SettingsController.Action)
        case system(SystemController.Action, level: Int?)
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
    @MainActor
    func route(_ transcript: String, menu: MenuReader.Snapshot? = nil) async throws -> Outcome {
        let catalog = AppCatalog.shared

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
            "level": SystemController.levelQuestion,
        ]
        if let q = RoutineStore.shared.question { questions["routine"] = q }

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
        if !sites.isEmpty { state["web_addresses_detected"] = sites.joined(separator: ", ") }
        if !known.isEmpty { state["users_known_sites"] = known.joined(separator: ", ") }

        let response = try await client.systemOne(state: state, questions: questions)

        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            for k in ["intent", "routine", "target1", "windows", "layout", "settings_page", "settings_action", "menu_item", "system_action", "level"] {
                if let a = response.choice(k) { print("  \(k): \(a.choice) (\(String(format: "%.2f", a.confidence)))") }
            }
            for (q, option) in checks.sorted(by: { $0.key < $1.key }) {
                print("  \(option): \(String(format: "%.2f", response.noul(q) ?? -1))")
            }
        }

        let intent = response.choice("intent")?.choice
        // Routines first: your own phrases beat generic intents.
        if let r = response.choice("routine"), r.choice != "none", r.confidence >= 0.6, let routine = RoutineStore.shared.routine(named: r.choice) {
            return .routine(routine)
        }
        if intent == "menu_command", let menu, let a = response.choice("menu_item"), let item = menuOptions[a.choice] {
            return a.confidence >= 0.4 ? .menu(item, menu.app) : .notACommand
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
