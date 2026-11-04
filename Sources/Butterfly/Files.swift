import AppKit

/// "Open my downloads", "open my latest screenshot", "find the invoice PDF".
@MainActor
enum Files {
    enum Action: String { case openFolder = "open_folder", latest, search }

    struct Folder {
        let key: String
        let title: String
        let description: String
        let url: () -> URL?
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let folders: [Folder] = [
        Folder(key: "downloads", title: "Downloads", description: "the Downloads folder, downloaded files") { home.appending(path: "Downloads") },
        Folder(key: "desktop", title: "Desktop", description: "the Desktop") { home.appending(path: "Desktop") },
        Folder(key: "documents", title: "Documents", description: "the Documents folder") { home.appending(path: "Documents") },
        Folder(key: "home", title: "Home", description: "the home / user folder") { home },
        Folder(key: "icloud", title: "iCloud Drive", description: "iCloud Drive") { home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs") },
        Folder(key: "screenshots", title: "Screenshots", description: "where screenshots are saved; screenshots, screen recordings") { screenshotFolder },
        Folder(key: "pictures", title: "Pictures", description: "the Pictures folder, photos, images") { home.appending(path: "Pictures") },
        Folder(key: "movies", title: "Movies", description: "the Movies folder, videos") { home.appending(path: "Movies") },
        Folder(key: "music", title: "Music", description: "the Music folder") { home.appending(path: "Music") },
        Folder(key: "applications", title: "Applications", description: "the Applications folder") { URL(filePath: "/Applications") },
        Folder(key: "trash", title: "Trash", description: "the Trash / bin") { home.appending(path: ".Trash") },
    ]

    static let actionQuestion = TypeSafeClient.Question.choice("What does the user want to do with files?", options: [
        "open_folder": "open or show a folder (Downloads, Desktop, Documents, iCloud, Screenshots, etc.), e.g. 'open my downloads', 'show me the desktop folder'",
        "latest": "open the latest / last / newest / most recent file in a place, e.g. the last download or latest screenshot",
        "search": "find, search for, or open a specific file or document by its name or topic",
    ])

    static var folderQuestion: TypeSafeClient.Question {
        var opts: [String: String] = [:]
        for f in folders { opts[f.key] = f.description }
        return .choice("Which folder or place does the user mean? For 'latest screenshot' pick screenshots; for 'last download' pick downloads.", options: opts)
    }

    static let revealQuestion = TypeSafeClient.Question.noul("Does the user want the file shown/revealed in Finder (rather than opened in its app)?")

    static func folder(_ key: String) -> Folder? { folders.first { $0.key == key } }

    /// Your screenshot location (Screenshot app → Options → Save to), Desktop by default.
    static var screenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        return home.appending(path: "Desktop")
    }

    // MARK: Latest file

    /// Newest file in a folder. Screenshots: only real screen captures.
    static func latest(in folder: Folder) -> URL? {
        guard let dir = folder.url() else { return nil }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let files = items.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true || url.pathExtension == "app" else { return false }
            if folder.key == "screenshots" { return isScreenCapture(url) }
            return true
        }
        func date(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        return files.max { date($0) < date($1) }
    }

    private static func isScreenCapture(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let n = url.lastPathComponent
        return n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot") || n.hasPrefix("Screen Recording")
    }

    // MARK: Search (Spotlight, by file name)

    nonisolated private static let stop: Set<String> = [
        "open", "find", "search", "show", "me", "my", "the", "a", "an", "file", "files", "document", "doc", "for", "called",
        "named", "please", "can", "you", "i", "want", "to", "in", "on", "of", "that", "this", "it", "up", "pull", "get", "where", "is",
        "folder", "finder", "reveal", "latest", "last", "recent", "with", "about", "and", "from", "dot",
    ]
    nonisolated private static let kinds: [String: Set<String>] = [
        "pdf": ["pdf"], "image": ["png", "jpg", "jpeg", "heic", "gif", "webp"], "photo": ["png", "jpg", "jpeg", "heic"],
        "picture": ["png", "jpg", "jpeg", "heic"], "video": ["mov", "mp4", "m4v"], "spreadsheet": ["xlsx", "csv", "numbers"],
        "presentation": ["key", "pptx", "pdf"], "deck": ["key", "pptx", "pdf"], "slides": ["key", "pptx", "pdf"],
        "zip": ["zip"], "word": ["docx", "pages"],
    ]

    struct Hit { let url: URL; let score: Double }

    /// Name-matching files under home + iCloud, ranked by words matched and recency.
    nonisolated static func search(_ transcript: String) async -> [Hit] {
        let words = transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let wantedExt = words.compactMap { kinds[$0] }.reduce(into: Set<String>()) { $0.formUnion($1) }
        let terms = Array(Set(words.filter { !stop.contains($0) && kinds[$0] == nil && $0.count > 1 })).prefix(6)
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "kMDItemFSName == \"*\($0)*\"cd" }.joined(separator: " || ")
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", FileManager.default.homeDirectoryForCurrentUser.path, query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(3000)

        let now = Date()
        var hits: [Hit] = []
        for path in paths where !isNoise(path) {
            let url = URL(filePath: String(path))
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let matched = terms.filter { name.contains($0) }.count
            guard matched > 0 else { continue }
            var score = Double(matched) * 10
            if !wantedExt.isEmpty { score += wantedExt.contains(url.pathExtension.lowercased()) ? 6 : -6 }
            let used = (try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]))
            let date = used?.contentAccessDate ?? used?.contentModificationDate ?? .distantPast
            score += max(0, 5 - now.timeIntervalSince(date) / 86_400 / 30)   // up to +5 for this month
            hits.append(Hit(url: url, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(40))
    }

    nonisolated private static func isNoise(_ path: Substring) -> Bool {
        let p = String(path)
        if p.contains("/Library/") && !p.contains("/Library/Mobile Documents/") { return true }
        for bad in ["/node_modules/", "/.git/", "/__pycache__/", "/.build/", "/build/", "/DerivedData/", ".app/", "/venv/", "/.venv/", "/site-packages/", "/Caches/"] where p.contains(bad) { return true }
        return p.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Short description of a file for Jev: name, place, age.
    static func describe(_ url: URL) -> String {
        let home = home.path
        var place = url.deletingLastPathComponent().path
        place = place.replacingOccurrences(of: home + "/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive")
        place = place.replacingOccurrences(of: home, with: "~")
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let age = mod.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? ""
        return "\(url.lastPathComponent) in \(place), modified \(age)"
    }

    static func open(_ url: URL, reveal: Bool) {
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
    }
}
