import AppKit

struct InstalledApp: Hashable {
    let name: String
    let url: URL
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Scans standard app folders once, then answers lookups from memory.
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()
    private(set) var apps: [InstalledApp] = []

    private let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    func reload() {
        var seen = Set<String>()
        var found: [InstalledApp] = []
        let fm = FileManager.default
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard seen.insert(name.lowercased()).inserted else { continue }
                found.append(InstalledApp(name: name, url: URL(fileURLWithPath: root).appendingPathComponent(item)))
            }
        }
        apps = found.sorted { $0.name < $1.name }
    }

    func app(named name: String) -> InstalledApp? {
        apps.first { $0.name == name }
    }

    /// Jev's Choice takes at most 255 options. Rank by word overlap with the
    /// transcript so the right app is always in the list.
    func candidates(for transcript: String, limit: Int = 255) -> [InstalledApp] {
        guard apps.count > limit else { return apps }
        let words = Set(Self.tokens(transcript))
        return apps
            .map { app in (app, Self.tokens(app.name).filter(words.contains).count) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Your default web browser (Dia, Chrome, Safari…), so "the browser" means yours.
    var defaultBrowser: InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return app(named: name) ?? InstalledApp(name: name, url: url)
    }

    /// "put the browser and discord…" → "put Dia and discord…".
    func resolvingGenericNames(_ transcript: String) -> String {
        guard let b = defaultBrowser else { return transcript }
        return transcript.replacingOccurrences(of: #"\b(my |the )?(web )?browser\b"#, with: b.name, options: [.regularExpression, .caseInsensitive])
    }

    /// Offline fallback: exact name match in the transcript.
    func localMatch(_ transcript: String) -> InstalledApp? {
        let t = transcript.lowercased()
        return apps
            .filter { t.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
