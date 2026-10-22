import AppKit

/// Play / pause / next / previous for Apple Music and Spotify (AppleScript),
/// with system media keys as a fallback for any other player (browser, etc.).
@MainActor
enum MediaController {
    enum Action: String { case play = "play_music", pause = "pause_music", next = "next_track", previous = "previous_track", show = "now_playing" }

    struct Result {
        let player: InstalledApp?
        let title: String
        let detail: String?
        var suggestions: [String] = []   // no playlist matched: a few to pick from next
    }

    private static let players: [(name: String, bundle: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
    ]

    /// `preferred`: the player named in the command, if any ("play music on Spotify").
    /// `query`: words that name a playlist ("play focus music" → "focus"); played from Music if one matches.
    static func perform(_ action: Action, preferred: String?, query: String? = nil) async -> Result {
        if action == .play, let query, preferred != "Spotify", let r = await playPlaylist(matching: query) { return r }
        let player = pickPlayer(for: action, preferred: preferred)

        guard let player else {
            // No scriptable player: use media keys (works for whatever is in Now Playing).
            pressMediaKey(action)
            return Result(player: nil, title: label(action), detail: nil)
        }

        let app = AppCatalog.shared.app(named: player.name)
        if !isRunning(player.bundle), let app {
            _ = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: background)
            _ = await waitUntil(timeout: 6) { isRunning(player.bundle) }
            try? await Task.sleep(for: .milliseconds(600))   // let it finish loading before scripting it
        }

        let ok = run(script(action, player.name)) != nil
        if !ok { pressMediaKey(action) }

        try? await Task.sleep(for: .milliseconds(250))
        let track = action == .pause ? nil : run("tell application \"\(player.name)\" to get (name of current track) & \" — \" & (artist of current track)")
        return Result(player: app, title: track ?? label(action), detail: track == nil ? nil : label(action))
    }

    // MARK: Picking a player

    private static func pickPlayer(for action: Action, preferred: String?) -> (name: String, bundle: String)? {
        let installed = players.filter { AppCatalog.shared.app(named: $0.name) != nil }
        // Something else owns Now Playing (YouTube in a browser…): control that, not Music.
        if preferred == nil, let t = NowPlaying.shared.track, t.playing || action != .play,
           !players.contains(where: { $0.bundle == t.bundleID }) { return nil }
        if let preferred, let p = installed.first(where: { $0.name.caseInsensitiveCompare(preferred) == .orderedSame }) {
            return p
        }
        let running = installed.filter { isRunning($0.bundle) }
        // The one currently playing wins, then any running one.
        if let playing = running.first(where: { state($0.name) == "playing" }) { return playing }
        if let any = running.first { return any }
        // Nothing running: only "play" should launch something.
        return action == .play ? installed.last : nil   // Music is always installed; Spotify if you have it
    }

    private static func state(_ name: String) -> String? {
        run("tell application \"\(name)\" to get player state as text")
    }

    private static func script(_ action: Action, _ name: String) -> String {
        switch action {
        case .play where name == "Music":
            // Nothing queued → shuffle something from your library.
            return """
            tell application "Music"
                if player state is stopped then
                    set shuffle enabled to true
                    play (some track of library playlist 1)
                else
                    play
                end if
            end tell
            """
        case .play: return "tell application \"\(name)\" to play"
        case .pause: return "tell application \"\(name)\" to pause"
        case .next: return "tell application \"\(name)\" to next track"
        case .previous: return "tell application \"\(name)\" to previous track"
        case .show: return ""
        }
    }

    // MARK: Playlists

    /// Words from "play (my) focus music (playlist)" that could name a playlist; nil for plain "play music".
    static func playlistQuery(_ spoken: String) -> String? {
        let filler: Set<String> = ["play", "start", "put", "on", "some", "my", "the", "a", "music", "playlist", "songs", "song",
                                   "please", "in", "from", "apple", "app", "resume", "me", "for", "list", "tracks", "and"]
        let words = spoken.lowercased().components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Best Music playlist for the query: every query word must appear in the name; shortest name wins.
    /// No match → a few suggestions (partial word matches first, then your own playlists).
    private static func playPlaylist(matching query: String) async -> Result? {
        guard let list = run("tell application \"Music\" to get name of every playlist") else { return nil }
        let names = list.components(separatedBy: ", ")
        let words = query.split(separator: " ").map(String.init)
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard let name = names.filter({ n in words.allSatisfy { fold(n).contains(fold($0)) } })
            .min(by: { $0.count < $1.count }) else {
            let builtIn: Set<String> = ["Library", "Music", "Music Videos", "Favourite Songs", "Favorite Songs", "Downloaded", "Recently Added", "Top 25 Most Played"]
            let own = names.filter { !builtIn.contains($0) }
            let partial = own.filter { n in words.contains { $0.count > 2 && fold(n).contains(fold($0)) } }
            let pick = Array((partial + own.filter { !partial.contains($0) }.shuffled()).prefix(4))
            guard !pick.isEmpty else { return nil }
            return Result(player: AppCatalog.shared.app(named: "Music"), title: "No “\(query)” playlist", detail: nil, suggestions: pick)
        }
        return play(playlist: name)
    }

    /// Plays a playlist by exact name, shuffled.
    static func play(playlist name: String) -> Result? {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard run("tell application \"Music\"\nset shuffle enabled to true\nplay playlist \"\(quoted)\"\nend tell") != nil else { return nil }
        return Result(player: AppCatalog.shared.app(named: "Music"), title: name, detail: "Playing playlist")
    }

    // MARK: Helpers

    private static var background: NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false   // music starts without stealing focus
        return c
    }

    private static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            print("AppleScript error:", error[NSAppleScript.errorNumber] ?? "?", error[NSAppleScript.errorMessage] ?? "")
            return nil
        }
        return out?.stringValue ?? ""
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func label(_ action: Action) -> String {
        switch action {
        case .play: "Playing"
        case .pause: "Paused"
        case .next: "Next track"
        case .previous: "Previous track"
        case .show: "Now playing"
        }
    }

    /// Whatever app owns Now Playing (browser, Podcasts…): exact MediaRemote commands, else media keys.
    /// Play and pause share one toggle key.
    private static func pressMediaKey(_ action: Action) {
        if NowPlaying.shared.track != nil {
            switch action {
            case .play: return NowPlaying.send(0)
            case .pause: return NowPlaying.send(1)
            case .next: return NowPlaying.send(4)
            case .previous: return NowPlaying.send(5)
            case .show: return
            }
        }
        let key: Int32 = switch action {
        case .play, .pause, .show: 16
        case .next: 17
        case .previous: 18
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | (down ? 0xA00 : 0xB00))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
