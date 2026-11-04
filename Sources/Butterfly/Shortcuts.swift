import AppKit

/// "press escape", "press command shift t", "hit enter twice" → one key + modifiers.
enum KeyPress {
    struct Combo { let key: CGKeyCode; let flags: CGEventFlags; let label: String; let times: Int }

    private static let modifiers: [String: (CGEventFlags, String)] = [
        "command": (.maskCommand, "⌘"), "cmd": (.maskCommand, "⌘"), "commander": (.maskCommand, "⌘"),
        "shift": (.maskShift, "⇧"),
        "option": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"),
        "control": (.maskControl, "⌃"), "ctrl": (.maskControl, "⌃"),
    ]
    private static let named: [String: (CGKeyCode, String)] = [
        "escape": (53, "esc"), "esc": (53, "esc"), "enter": (36, "↩"), "return": (36, "↩"), "tab": (48, "⇥"),
        "space": (49, "space"), "spacebar": (49, "space"), "delete": (51, "⌫"), "backspace": (51, "⌫"),
        "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"), "right": (124, "→"),
        "home": (115, "↖"), "end": (119, "↘"), "pageup": (116, "⇞"), "pagedown": (121, "⇟"),
        "comma": (43, ","), "period": (47, "."), "dot": (47, "."), "slash": (44, "/"), "minus": (27, "-"), "plus": (24, "="), "equals": (24, "="),
        "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"), "f5": (96, "F5"), "f6": (97, "F6"),
        "f7": (98, "F7"), "f8": (100, "F8"), "f9": (101, "F9"), "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12"),
    ]
    private static let letters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    // Speech-to-text spells single letters as words.
    private static let spelled: [String: Character] = [
        "tea": "t", "tee": "t", "see": "c", "sea": "c", "bee": "b", "be": "b", "why": "y", "you": "u", "are": "r",
        "queue": "q", "cue": "q", "eye": "i", "oh": "o", "jay": "j", "kay": "k", "pee": "p", "vee": "v", "double u": "w",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "zero": "0",
    ]

    static func parse(_ spoken: String) -> Combo? {
        var words = spoken.lowercased()
            .replacingOccurrences(of: "page up", with: "pageup").replacingOccurrences(of: "page down", with: "pagedown")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let start = words.firstIndex(where: { ["press", "hit", "tap", "push"].contains($0) }) else { return nil }
        words = Array(words[(start + 1)...])
        var times = 1
        if let i = words.firstIndex(where: { ["twice", "two"].contains($0) && $0 == words.last }) { times = 2; words.remove(at: i) }
        if words.last == "times", words.count >= 2, let n = Int(words[words.count - 2]) ?? ["three": 3, "four": 4, "five": 5][words[words.count - 2]] {
            times = min(n, 10); words.removeLast(2)
        }
        if words.count > 1 { words = words.filter { !["the", "key", "button", "and", "plus", "then"].contains($0) } }

        var flags: CGEventFlags = []
        var label = ""
        var key: (CGKeyCode, String)?
        for w in words {
            if let m = modifiers[w] { flags.insert(m.0); label += m.1; continue }
            guard key == nil else { return nil }   // two keys: not a single shortcut
            if let n = named[w] { key = n }
            else if w.count == 1, let c = w.first, let code = letters[c] { key = (code, c.uppercased()) }
            else if let c = spelled[w], let code = letters[c] { key = (code, c.uppercased()) }
            else { return nil }   // a word that isn't a key: "press the blue button" is a click, not a key
        }
        guard let key else { return nil }
        return Combo(key: key.0, flags: flags, label: label + key.1, times: times)
    }

    static func perform(_ c: Combo, in app: NSRunningApplication?) async {
        app?.activate()
        try? await Task.sleep(for: .milliseconds(80))
        for _ in 0..<c.times {
            Keys.press(c.key, flags: c.flags)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
}

/// "search google for flights to paris", "google best pizza", "search chaseit on linkedin" → that site's results page.
enum WebSearch {
    /// Spoken names → results URL. Google is the fallback when no platform is named.
    static let engines: [(names: [String], label: String, base: String)] = [
        (["youtube", "you tube"], "YouTube", "https://www.youtube.com/results?search_query="),
        (["amazon"], "Amazon", "https://www.amazon.com/s?k="),
        (["google maps", "maps"], "Maps", "https://www.google.com/maps/search/"),
        (["google images", "images"], "Google Images", "https://www.google.com/search?tbm=isch&q="),
        (["wikipedia"], "Wikipedia", "https://en.wikipedia.org/w/index.php?search="),
        (["linkedin", "linked in"], "LinkedIn", "https://www.linkedin.com/search/results/all/?keywords="),
        (["twitter", "x.com", "on x"], "X", "https://x.com/search?q="),
        (["github", "git hub"], "GitHub", "https://github.com/search?q="),
        (["reddit"], "Reddit", "https://www.reddit.com/search/?q="),
        (["instagram", "insta"], "Instagram", "https://www.instagram.com/explore/search/keyword/?q="),
        (["tiktok", "tik tok"], "TikTok", "https://www.tiktok.com/search?q="),
        (["facebook"], "Facebook", "https://www.facebook.com/search/top/?q="),
        (["pinterest"], "Pinterest", "https://www.pinterest.com/search/pins/?q="),
        (["stack overflow", "stackoverflow"], "Stack Overflow", "https://stackoverflow.com/search?q="),
        (["hacker news"], "Hacker News", "https://hn.algolia.com/?q="),
        (["product hunt", "producthunt"], "Product Hunt", "https://www.producthunt.com/search?q="),
        (["crunchbase"], "Crunchbase", "https://www.crunchbase.com/textsearch?q="),
        (["npm"], "npm", "https://www.npmjs.com/search?q="),
        (["ebay", "e-bay"], "eBay", "https://www.ebay.com/sch/i.html?_nkw="),
        (["imdb"], "IMDb", "https://www.imdb.com/find/?q="),
        (["medium"], "Medium", "https://medium.com/search?q="),
        (["dribbble", "dribble"], "Dribbble", "https://dribbble.com/search/"),
        (["behance"], "Behance", "https://www.behance.net/search/projects?search="),
        (["unsplash"], "Unsplash", "https://unsplash.com/s/photos/"),
        (["spotify"], "Spotify", "https://open.spotify.com/search/"),
        (["twitch"], "Twitch", "https://www.twitch.tv/search?term="),
        (["gmail", "my email", "my mail"], "Gmail", "https://mail.google.com/mail/u/0/#search/"),
        (["google drive", "drive"], "Google Drive", "https://drive.google.com/drive/search?q="),
        (["perplexity"], "Perplexity", "https://www.perplexity.ai/search?q="),
        (["chatgpt", "chat gpt"], "ChatGPT", "https://chatgpt.com/?q="),
        (["duckduckgo", "duck duck go"], "DuckDuckGo", "https://duckduckgo.com/?q="),
        (["bing"], "Bing", "https://www.bing.com/search?q="),
        (["google", "the web", "web", "online", "the internet"], "Google", "https://www.google.com/search?q="),
    ]

    static func parse(_ spoken: String) -> (url: URL, query: String, engine: String)? {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = s.lowercased()
        // Longest names first so "google maps" beats "google", "stack overflow" beats nothing.
        let names = engines.flatMap(\.names).sorted { $0.count > $1.count }
        let engine = engines.first { e in e.names.contains { lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: .regularExpression) != nil } } ?? engines.last!
        let alt = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // Strip the command words around the query.
        var q = " " + lower + " "
        let patterns = [
            #"^\s*(ok(ay)?,?\s+)?(please\s+)?(can you\s+|could you\s+)?(go\s+to\s+(?:"# + alt + #")\s+and\s+)?(search|look\s+up|google|find|look\s+for|show\s+me)\s+(on\s+|in\s+|at\s+)?(?:"# + alt + #")?\s*(for\s+)?"#,
            #"\s+(on|in|at|using|with|via)\s+(?:"# + alt + #")\s*(,?\s*(and\s+)?show\s+me\s+(the\s+)?results)?\s*$"#,
            #"\s+online\s*$"#,
            #",?\s*(and\s+)?show\s+me\s+(the\s+)?results\s*$"#,
        ]
        for p in patterns { q = q.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != lower.trimmingCharacters(in: .whitespaces),
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: engine.base + enc) else { return nil }
        return (url, q, engine.label)
    }
}

/// The default browser (Dia): searches open as a new tab; questions get typed into a new tab's bar so its AI answers.
@MainActor
enum BrowserTab {
    static func open(_ url: URL) {
        guard let app = AppCatalog.shared.defaultBrowser else { NSWorkspace.shared.open(url); return }
        let c = NSWorkspace.OpenConfiguration(); c.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: c)
    }

    @discardableResult
    static func ask(_ question: String) async -> InstalledApp? {
        let app = AppCatalog.shared.defaultBrowser
        guard let app else {
            open(URL(string: "https://www.google.com/search?q=" + (question.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))!)
            return nil
        }
        let id = Bundle(url: app.url)?.bundleIdentifier ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        if let running { running.activate() }
        else { _ = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) }
        // Wait until it's frontmost (cold launch takes longer), then ⌘T and type into the new tab's bar.
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != id {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(running == nil ? 900 : 150))
        Keys.press(17, flags: .maskCommand)   // ⌘T
        try? await Task.sleep(for: .milliseconds(350))
        await Typer.type(question, pressReturn: true)
        return app
    }
}
