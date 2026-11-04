import AppKit

/// What's playing in any app (Music, Spotify, browsers…), via mediaremote-adapter (BSD-3, bundled).
/// Apple locked MediaRemote to system apps; the adapter runs it through /usr/bin/perl, which is allowed.
@MainActor
final class NowPlaying: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String?
        var album: String?
        var playing: Bool
        var duration: Double?
        var elapsed: Double?
        var at: Date               // when `elapsed` was measured
        var bundleID: String?
        var artwork: NSImage?

        var id: String { "\(title)|\(artist ?? "")" }
        var progress: Double? {
            guard let duration, duration > 0, let elapsed else { return nil }
            let now = elapsed + (playing ? Date().timeIntervalSince(at) : 0)
            return min(1, max(0, now / duration))
        }
        var app: InstalledApp? {
            guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return InstalledApp(name: url.deletingPathExtension().lastPathComponent, url: url)
        }
        static func == (a: Track, b: Track) -> Bool {
            a.id == b.id && a.playing == b.playing && a.elapsed == b.elapsed && (a.artwork == nil) == (b.artwork == nil)
        }
    }

    static let shared = NowPlaying()
    @Published private(set) var track: Track?
    /// New song started, or play/pause flipped.
    var onChange: ((_ old: Track?, _ new: Track?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private static var cleaned = false

    private static var adapter: (script: String, framework: String)? {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/MediaRemoteAdapter").standardized]
        for d in dirs.compactMap({ $0 }) {
            let s = d.appendingPathComponent("mediaremote-adapter.pl").path
            let f = d.appendingPathComponent("MediaRemoteAdapter.framework").path
            if FileManager.default.fileExists(atPath: s), FileManager.default.fileExists(atPath: f) { return (s, f) }
        }
        return nil
    }

    func start() {
        guard process == nil, let a = Self.adapter else { return }
        if !Self.cleaned {
            // A crashed/killed Butterfly leaves its helper behind: clear those once.
            Self.cleaned = true
            let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", "mediaremote-adapter.pl"]
            try? k.run(); k.waitUntilExit()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.process?.terminationHandler = nil; self?.process?.terminate() }
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [a.script, a.framework, "stream", "--no-diff", "--debounce=150"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.process = nil; self?.start()
            }
        }
        try? p.run()
        process = p
    }

    /// One-shot read (CLI tests, or before the stream has reported).
    static func fetch() -> Track? {
        guard let a = adapter else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [a.script, a.framework, "get"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(parse)
    }

    /// MRCommand ids: play 0, pause 1, toggle 2, next 4, previous 5. Works for whatever app is playing.
    static func send(_ command: Int) {
        guard let a = adapter else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [a.script, a.framework, "send", String(command)]
        try? p.run()
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            var new = Self.parse(payload)
            let old = track
            // Updates without artwork (progress ticks) keep the cover; Apple Music: ask it directly as a fallback.
            if new != nil, new?.artwork == nil {
                if old?.id == new?.id, let art = old?.artwork { new?.artwork = art }
                else if new?.bundleID == "com.apple.Music" { new?.artwork = Self.musicArtwork() }
            }
            track = new
            if old?.id != new?.id || old?.playing != new?.playing { onChange?(old, new) }
        }
    }

    private static func musicArtwork() -> NSImage? {
        var error: NSDictionary?
        let d = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?.executeAndReturnError(&error)
        return error == nil ? d.flatMap { NSImage(data: $0.data) } : nil
    }

    private static func parse(_ p: [String: Any]) -> Track? {
        guard let title = p["title"] as? String, !title.isEmpty else { return nil }
        let art = (p["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
        let stamp = (p["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return Track(title: title, artist: p["artist"] as? String, album: p["album"] as? String,
                     playing: p["playing"] as? Bool ?? false, duration: p["duration"] as? Double,
                     elapsed: p["elapsedTime"] as? Double, at: stamp,
                     bundleID: (p["parentApplicationBundleIdentifier"] as? String) ?? (p["bundleIdentifier"] as? String),
                     artwork: art)
    }
}
