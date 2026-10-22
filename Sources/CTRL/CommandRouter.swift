import AppKit

/// Turns a transcript into an action, using one Jev request (all questions run in parallel).
struct CommandRouter {
    enum Outcome {
        case open(WindowManager.Plan)
        case media(MediaController.Action, preferred: String?, query: String? = nil)
        case settings(SettingsController.Page, SettingsController.Action)
        case system(SystemController.Action, level: Int?)
        case timer(Timers.Action, seconds: TimeInterval?)
        case focus(String)                       // mode name, or "off"
        case bluetooth(name: String, address: String, connect: Bool)
        case joinWiFi(String)
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
        case calendar(Agenda.Action)
        case navigate(KeyCommands.Nav)
        case edit(KeyCommands.Edit)
        case screen(ScreenReader.Action, request: String)
        case undo                                // CTRL's own last action, else ⌘Z
        case quickSetting(String, on: Bool)
        case audioOutput(AudioOutput.Device)
        case audioOutputBluetooth(name: String, address: String)   // paired but not connected yet
        case pasteHistory(Clipboard.Item)
        case clipboardList
        case agent(String)                       // second layer: the on-device LLM plans and does it
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
        let transcript = catalog.resolvingGenericNames(transcript)
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
                "now_playing": "ask what song/track is playing, who sings this, or to show the music player / now playing",
                "timer": "set, start, cancel, or check a timer / countdown (e.g. 'set a timer for 5 minutes', 'how long is left on my timer', 'remind me in 10 minutes')",
                "focus": "turn a Focus mode on or off (not Stage Manager): Do Not Disturb, Work, Sleep, Personal, Gaming… ('don't disturb me', 'focus mode', 'turn off do not disturb')",
                "connect": "connect or disconnect a specific Bluetooth device (AirPods, headphones, speaker, keyboard, controller) or join a specific Wi-Fi network by name",
                "settings": "open a specific System Settings page, check or change a Mac setting (menu bar always shown or auto-hidden, Dock auto-hide, Stage Manager, battery percentage in the menu bar, Night Shift, Bluetooth on/off, desktop icons, hidden files, Wi-Fi, Bluetooth, dark mode, battery settings, storage, display settings, notifications, privacy, keyboard, updates, etc.)",
                "system": "change the volume (louder, quieter, mute, unmute) or screen brightness, lock the screen, put the Mac to sleep, turn the display off, take a screenshot, empty the Trash, or ask how much battery is left / whether it's charging",
                "window": "move, snap, resize, center, maximize, minimize, close, or full-screen the current window (or a named app's window), send it to another screen, or hide or quit an app that's already open, or hide all other apps",
                "click": "click, press, tap, or select something visible on screen: a button, link, tab, field, message, item, desktop widget, Dock icon, or menu bar icon (e.g. 'click send', 'press the blue button', 'click the first result', 'click the weather widget')",
                "files": "open a folder (Downloads, Desktop, Documents, iCloud), open the latest download or screenshot, or find / open a specific file or document on the Mac. 'Show me the desktop' means the Desktop folder",
                "calendar": "only ASK about the existing calendar (not adding anything), schedule, meetings, or events (what's next, what's on today/tomorrow, am I free), or join the current/next meeting or video call",
                "navigate": "scroll up or down, go to the top or bottom of the page, go back or forward a page, next or previous tab, reopen the closed tab, or switch back to the previous app",
                "edit": "edit text in the current text field: select or delete the last word, sentence, or line, 'scratch that', select all, copy (also 'copy that', 'copy this'), cut, paste, redo, new line, new paragraph, go to the end/start",
                "screen": "summarize, explain, or read aloud what's on screen (page, article, email, error, document), answer a question about it, write a reply to the message on screen, or stop reading aloud",
                "task": "a request that needs understanding content and doing something with it, or several steps: take something on screen (a message, email, invite, page) and put it somewhere — calendar, reminders, a note — e.g. 'grab the last message and put it in my calendar', 'add this to my reminders', 'make an event from this email', 'remind me to call mom tomorrow at 5'. Any request to ADD, create, or schedule a calendar event or reminder ('add a dentist appointment on Nov 3 to my calendar')",
                "undo": "undo, revert, or take back the last thing that was done: 'undo', 'undo that', 'put it back', 'revert that', 'never mind'",
                "audio_output": "switch, change, or route the sound / audio output to a device: AirPods, headphones, speakers, the MacBook speakers, the TV / monitor ('play sound through my AirPods', 'switch audio to speakers', 'output to headphones')",
                "clipboard": "paste or bring back something copied EARLIER (not just 'paste'): 'paste the link I copied before', 'paste what I copied 2 things ago', 'paste the address from earlier', or show / list clipboard history ('what did I copy')",
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
            "target1": .choice("Which application or website does the user mention first in `spoken_command`? Only names actually said now count, not ones from `recent_actions`.", options: options),
            // Settings branch, asked speculatively in the same request.
            "settings_page": SettingsController.pageQuestion,
            "settings_action": SettingsController.actionQuestion,
            "settings_theme": SettingsController.themeQuestion,
            "system_action": SystemController.actionQuestion,
            "timer_action": Timers.actionQuestion,
            "timer_duration": Timers.durationQuestion,
            "window_action": WindowCommands.question,
            "files_action": Files.actionQuestion,
            "folder": Files.folderQuestion,
            "reveal": Files.revealQuestion,
            "level": SystemController.levelQuestion,
            "calendar_action": Agenda.actionQuestion,
            "quick_setting": QuickSettings.question,
            "quick_on": .noul("Does the user want that setting on / shown / enabled / always (yes), rather than off / hidden / disabled / auto-hidden (no)?"),
            "nav_action": KeyCommands.navQuestion,
            "edit_action": KeyCommands.editQuestion,
            "screen_action": ScreenReader.actionQuestion,
        ]
        if let q = RoutineStore.shared.question { questions["routine"] = q }
        let outputs = AudioOutput.devices
        let audioPaired = Bluetooth.shared.paired.filter { d in
            !d.connected && ["airpods", "headphones", "hifispeaker"].contains { d.symbol.hasPrefix($0) } && !outputs.contains { $0.name == d.name }
        }
        if !outputs.isEmpty {
            var o = ["none": "none of these: the device the user named isn't listed"]
            for (i, d) in outputs.enumerated() { o["a\(i)"] = "the audio output “\(d.name)”" + (d.bluetooth ? " (Bluetooth)" : "") + (d.id == AudioOutput.current ? " (current)" : "") }
            for d in audioPaired.prefix(20) { o["b:" + d.address] = "the Bluetooth audio device “\(d.name)” (paired, not connected yet)" }
            questions["audio_target"] = .choice("Which audio output device does the user want the sound to go to? Speech-to-text may misspell names.", options: o)
        }
        let clips = Clipboard.shared.options
        if !clips.isEmpty {
            questions["clip_item"] = .choice("Which previously copied item does the user want pasted? Match its content ('the link' = a URL, 'the address' = a street address) or its order ('before' / 'the previous one' = copied just before the current one).", options: clips)
            questions["clip_list"] = .noul("Does the user want to SEE / list the clipboard history (yes), rather than paste an item (no)?")
        }
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

        // Focus / connect branches: your own modes, devices, and networks are the options.
        let focusModes = Focus.modes
        var fm = ["off": "turn Focus / Do Not Disturb off, stop focusing, allow notifications again"]
        for m in focusModes { fm[m.name] = "the \(m.name) Focus mode" }
        questions["focus_mode"] = .choice("Which Focus mode does the user want turned on, or off?", options: fm)
        var connectOptions: [String: String] = [:]
        var co: [String: String] = [:]
        for d in Bluetooth.shared.paired.prefix(60) {
            let k = "bt:" + d.address; connectOptions[k] = d.name
            co[k] = "the Bluetooth device “\(d.name)”" + (d.connected ? " (connected now)" : "")
        }
        for n in WiFi.shared.known.prefix(60) {
            let k = "wifi:" + n; connectOptions[k] = n
            co[k] = "the Wi-Fi network “\(n)”"
        }
        if !co.isEmpty {
            questions["connect_target"] = .choice("Which Bluetooth device or Wi-Fi network does the user mean? Speech-to-text may misspell names (e.g. 'air pods').", options: co)
            questions["connect_on"] = .noul("Does the user want to connect (yes) rather than disconnect (no)?")
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
        if let recent = Memory.summary { state["recent_actions"] = recent }
        if dictating { state["mode"] = "the user is dictating text; the last command was a type command" }
        if state["recent_actions"] != nil {
            state["note"] = "`recent_actions` is what the user did in the last 2 minutes. Words like 'it', 'that', 'back', 'the other one' usually refer to it."
        }
        if !sites.isEmpty { state["web_addresses_detected"] = sites.joined(separator: ", ") }
        if !known.isEmpty { state["users_known_sites"] = known.joined(separator: ", ") }

        let response = try await client.systemOne(state: state, questions: questions)

        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            for k in ["intent", "routine", "target1", "windows", "layout", "settings_page", "settings_action", "menu_item", "system_action", "timer_action", "timer_duration", "focus_mode", "connect_target", "window_action", "click_target", "calendar_action", "quick_setting", "audio_target", "clip_item", "nav_action", "edit_action", "screen_action", "files_action", "folder", "level"] {
                if let a = response.choice(k) { print("  \(k): \(a.choice) (\(String(format: "%.2f", a.confidence)))") }
            }
            for (q, option) in checks.sorted(by: { $0.key < $1.key }) {
                print("  \(option): \(String(format: "%.2f", response.noul(q) ?? -1))")
            }
        }

        var intent = response.choice("intent")?.choice
        // Two or more apps/sites + an arrangement is always "arrange these", never "move this one window".
        if intent == "window", response.choice("layout").map({ $0.choice != "none" }) == true,
           checks.filter({ (response.noul($0.key) ?? 0) >= Self.extraThreshold }).count >= 2 {
            intent = "open"
        }
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
        if intent == "undo" { return .undo }
        if intent == "audio_output", let a = response.choice("audio_target") {
            // "none" vs a device whose name you actually said: the name wins.
            var pick = a.choice
            if pick == "none" {
                let named = a.probabilities.filter { $0.key != "none" && $0.value >= 0.2 }.sorted { $0.value > $1.value }.first { p in
                    let name = p.key.hasPrefix("b:") ? audioPaired.first { "b:" + $0.address == p.key }?.name : Int(p.key.dropFirst()).flatMap { outputs.indices.contains($0) ? outputs[$0].name : nil }
                    return name.map { Self.mentions(spoken.replacingOccurrences(of: "air pods", with: "airpods"), $0) } ?? false
                }
                if let named { pick = named.key }
            }
            if pick.hasPrefix("b:"), let d = audioPaired.first(where: { "b:" + $0.address == pick }) {
                return .audioOutputBluetooth(name: d.name, address: d.address)
            }
            if pick.hasPrefix("a"), let i = Int(pick.dropFirst()), outputs.indices.contains(i) { return .audioOutput(outputs[i]) }
            return .notACommand
        }
        if intent == "clipboard" {
            if (response.noul("clip_list") ?? 0) >= 0.5 || clips.isEmpty { return .clipboardList }
            if let a = response.choice("clip_item"), let item = Clipboard.shared.item(a.choice) { return .pasteHistory(item) }
        }
        if intent == "task" { return .agent(transcript) }
        if intent == "calendar", let a = response.choice("calendar_action"), let action = Agenda.Action(rawValue: a.choice) { return .calendar(action) }
        if intent == "navigate", let a = response.choice("nav_action"), let action = KeyCommands.Nav(rawValue: a.choice) { return .navigate(action) }
        if intent == "edit", let a = response.choice("edit_action"), let action = KeyCommands.Edit(rawValue: a.choice) {
            return action == .undo ? .undo : .edit(action)
        }
        if intent == "screen", let a = response.choice("screen_action"), let action = ScreenReader.Action(rawValue: a.choice) {
            return .screen(action, request: transcript)
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
            // "quit slack" → Slack; "quit it" right after "open slack" → Slack; "snap this left" → the app in front.
            let named = mentionedApps.compactMap { app in
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
            }.first
            let refersBack = normalized.firstMatch(of: #/\b(it|that|them|back)\b/#) != nil
            let remembered = refersBack ? Memory.recent.last?.app.flatMap { name in
                NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
            } : nil
            guard let app = named ?? remembered ?? front ?? menu?.app else { return .notACommand }
            return .window(action, app)
        }
        if intent == "focus", let m = response.choice("focus_mode") {
            return .focus(m.choice)
        }
        if intent == "connect", let t = response.choice("connect_target"), let name = connectOptions[t.choice] {
            if t.choice.hasPrefix("wifi:") { return .joinWiFi(name) }
            return .bluetooth(name: name, address: String(t.choice.dropFirst(3)), connect: (response.noul("connect_on") ?? 1) >= 0.5)
        }
        if intent == "timer" {
            let action = response.choice("timer_action").flatMap { Timers.Action(rawValue: $0.choice) } ?? .start
            let jev = response.choice("timer_duration").flatMap { $0.choice == "none" ? nil : Double($0.choice) }
            return .timer(action, seconds: Timers.seconds(in: normalized) ?? jev)
        }
        if intent == "system", let a = response.choice("system_action"), let action = SystemController.Action(rawValue: a.choice) {
            // "show battery percentage" is the menu bar setting, not a question.
            if action == .battery, normalized.firstMatch(of: #/\b(show|hide|display|turn (on|off))\b.*\bpercent/#) != nil {
                return .quickSetting("battery_percent", on: normalized.firstMatch(of: #/\b(hide|turn off)\b/#) == nil)
            }
            let jevLevel = response.choice("level").flatMap { $0.choice == "none" ? nil : $0.choice }
            return .system(action, level: SystemController.level(in: normalized, jev: jevLevel))
        }
        if intent == "settings", let q = response.choice("quick_setting"), q.choice != "none", q.confidence >= 0.55, QuickSettings.setting(q.choice) != nil {
            return .quickSetting(q.choice, on: (response.noul("quick_on") ?? 1) >= 0.5)
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
            return .media(action, preferred: preferred, query: action == .play ? MediaController.playlistQuery(spoken) : nil)
        }
        guard intent == "open" else { return .notACommand }

        // First item: the choice question (works even when speech misspells the name).
        var picked: [(option: String, position: Int)] = []
        if let a = response.choice("target1") {
            let appName = a.choice.hasPrefix("app:") ? String(a.choice.dropFirst(4)) : nil
            let onlyInsideURL = appName.map { !sites.isEmpty && !Self.mentions(outsideURLs, $0) } ?? false
            // A name that's only in recent memory, not in what you just said ("open cursor" after "open slack").
            let onlyFromMemory = appName.map { name in
                !Self.mentions(spoken, name) && Memory.recent.contains { $0.said.lowercased().contains(name.lowercased()) || ($0.app == name) }
            } ?? false
            if onlyInsideURL || onlyFromMemory {
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
        // Most likely screen alone first (fast); the others only if it isn't there.
        if let p = try await locate(what, on: Array(shots.prefix(1))) { return p }
        guard shots.count > 1 else { return nil }
        return try await locate(what, on: Array(shots.dropFirst()))
    }

    /// One request: a Box + "is it here?" per screen, then the most likely screen.
    @MainActor
    private func locate(_ what: String, on shots: [Clicker.Shot]) async throws -> CGPoint? {
        var state = ["spoken_command": what]
        if let recent = Memory.summary { state["recent_actions"] = recent }
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
                print("  display \(shots[i].display): visible=\(String(format: "%.2f", response.noul("visible_\(i)") ?? -1)) box=\(response.box("target_\(i)").map { "\($0.box) conf=\(String(format: "%.2f", $0.confidence))" } ?? "-")")
            }
        }
        // Both must agree: "it's here" alone gives false positives (found a "purple elephant").
        guard let b = response.box("target_\(best)"), (response.noul("visible_\(best)") ?? 0) >= 0.5, b.confidence >= 0.3 else { return nil }
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
