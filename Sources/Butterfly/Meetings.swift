import AppKit
import CoreAudio
import EventKit
import Network

/// Recall-style meeting notes without a bot: when a call app uses the mic, Butterfly records the call
/// (what you hear + your mic), then Gemini writes the transcript. Saved in ~/Documents/Butterfly Meetings.
@MainActor
final class Meetings {
    static let shared = Meetings()

    enum Event { case ask(app: String), unasked, askStop(app: String), unaskStop, started(app: String), stopped(app: String), discarded(app: String), saved(title: String, folder: URL), failed(String) }
    var onEvent: ((Event) -> Void)?
    private func emit(_ e: Event) { Self.log("\(e)"); onEvent?(e) }

    static var auto: Bool { UserDefaults.standard.object(forKey: "recordMeetings") as? Bool ?? true }
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Butterfly Meetings", isDirectory: true)

    private struct Session {
        let recorder: MeetingRecorder
        let app: String
        let browser: Bool
        let started: Date
        let event: EKEvent?
        let manual: Bool
    }
    private var session: Session?
    private var ticker: Timer?
    private var quietSince: Date?
    private var browserSince: Date?
    private var dismissed: String?   // stopped by hand or "Not now": don't ask again for the same call
    /// A call was detected and the notch is asking "Record this meeting?".
    private var pending: (app: String, browser: Bool)?
    private var askedStop = false   // "Call ended?" is showing
    private var keep = false        // you said Keep recording: don't ask again until the mic comes back and goes

    /// Your answer to "Call ended?".
    func answerStop(_ stopNow: Bool) {
        guard session != nil else { return }
        askedStop = false
        Self.log("stop prompt: \(stopNow ? "Stop" : "Keep")")
        if stopNow { stop() } else { keep = true }
    }

    var isRecording: Bool { session != nil }
    var level: Float { session?.recorder.level ?? 0 }
    var recordingApp: String? { session?.app }

    /// ~/Library/Logs/Butterfly/meetings.log: what detection saw and did (for "why didn't it record?").
    static func log(_ s: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meetings.log")
        let line = Data("\(Date().formatted(.iso8601)) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    func start() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { Meetings.shared.tick() }
        }
        // Self-recovery: transcripts that failed (lid closed, Wi-Fi dropped, app quit mid-way) are retried on their own.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Meetings.shared.retryFailed() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // Give Wi-Fi a moment to come back, then retry right away (skip the backoff wait).
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                MainActor.assumeIsolated { Meetings.shared.retryFailed(now: true) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated { Meetings.shared.retryFailed() }
        }
        // Back online: retry now instead of waiting for the next scheduled try.
        net.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = Meetings.shared
                    let cameBack = up && !m.online
                    m.online = up
                    if cameBack { Self.log("network back"); m.retryFailed(now: true) }
                }
            }
        }
        net.start(queue: .global(qos: .utility))
    }

    private let net = NWPathMonitor()
    private var online = true

    // MARK: self-recovery

    private var retryTimer: Timer?
    /// Recordings being transcribed right now (their transcript.md is missing until it's done).
    private var inFlight: Set<String> = []
    /// Auto-retries per recording: how many so far and when the next one is due.
    private var retries: [String: (count: Int, next: Date)] = [:]
    /// Wait before each retry: 1, 5, 15, 30 min, 1 h, 3 h. Then it stays failed (Settings › Transcribe still works).
    static let retryDelays: [TimeInterval] = [60, 300, 900, 1800, 3600, 3 * 3600]

    /// Re-transcribes recordings from the last 3 days whose transcript failed or never got written.
    func retryFailed(now force: Bool = false) {
        guard Keychain.geminiKey != nil, online else { return }   // offline: don't burn attempts, the path monitor calls back
        let now = Date()
        for r in Self.recordings().prefix(30) where r.status != .done {
            let id = r.folder.path
            guard let d = r.date, now.timeIntervalSince(d) < 3 * 86400,
                  !inFlight.contains(id), session?.recorder.folder.path != id else { continue }
            let st = retries[id] ?? (0, .distantPast)
            guard st.count < Self.retryDelays.count, force || now >= st.next else { continue }
            retries[id] = (st.count + 1, now.addingTimeInterval(Self.retryDelays[st.count]))
            Self.log("auto-retry \(st.count + 1)/\(Self.retryDelays.count): \(r.name)")
            retranscribeLast(folder: r.folder, quiet: true)
        }
    }

    // MARK: detection

    /// Apps whose mic use means "in a call".
    nonisolated private static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"), ("com.hnc.Discord", "Discord"), ("com.cisco.webex", "Webex"),
        ("com.webex", "Webex"), ("net.whatsapp", "WhatsApp"), ("com.whatsapp", "WhatsApp"), ("ru.keepcoder.Telegram", "Telegram"),
        ("com.skype", "Skype"), ("com.around", "Around"), ("so.tuple", "Tuple"), ("org.whispersystems.signal", "Signal"),
    ]
    /// Browsers (Meet, Teams web, Whereby…): their mic use counts at once during a calendar meeting, else after 15 s
    /// (a voice note or push-to-talk on a website is shorter). The name comes from the app bundle the helper lives in:
    /// Dia and Arc share `company.thebrowser.browser.helper`.
    nonisolated private static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"), ("company.thebrowser.dia", "Dia"), ("company.thebrowser", "Arc"),
        ("com.apple.WebKit", "Safari"), ("com.apple.Safari", "Safari"), ("org.mozilla", "Firefox"),
        ("com.brave", "Brave"), ("com.microsoft.edgemac", "Edge"), ("com.operasoftware", "Opera"), ("com.vivaldi", "Vivaldi"),
    ]
    static let browserDelay: TimeInterval = 15

    /// A browser window whose title is a meeting site ("Meet – abc-defg-hij") → "Google Meet". Needs Screen Recording, which recording already has.
    nonisolated private static func meetingWindow(_ browser: String) -> String? {
        let sites = [("Meet", "Google Meet"), ("Zoom", "Zoom"), ("Microsoft Teams", "Teams"), ("Teams", "Teams"),
                     ("Whereby", "Whereby"), ("Jitsi", "Jitsi"), ("Webex", "Webex"), ("Huddle", "Slack huddle"), ("Discord", "Discord")]
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == browser {
            guard let title = w[kCGWindowName as String] as? String else { continue }
            if let s = sites.first(where: { s in [" - ", " – ", " | "].contains { title.hasPrefix(s.0 + $0) || title.hasSuffix($0.trimmingCharacters(in: .whitespaces) + " " + s.0) } }) { return s.1 }
        }
        return nil
    }
    /// System speech services (Siri, "Hey Siri", dictation) hold the mic without being a call.
    nonisolated private static let ignored = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.SpeechRecognitionCore", "com.apple.assistantd", "com.apple.siri"]

    struct MicUser: CustomStringConvertible {
        let bundle: String
        let pid: pid_t
        /// The app whose bundle contains the process (a browser helper → "Dia").
        var appName: String? { Meetings.appName(pid: pid) }
        var description: String { "\(bundle) pid \(pid)\(appName.map { " (\($0))" } ?? "")" }
    }

    /// Every process using a microphone right now, not counting Butterfly or system speech.
    nonisolated static func micUsers() -> [MicUser] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id -> MicUser? in
            var r = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var on: UInt32 = 0; var n = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &r, 0, nil, &n, &on) == noErr, on != 0 else { return nil }
            var p = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0; var pn = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &p, 0, nil, &pn, &pid)
            if pid == me { return nil }
            var b = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?; var bn = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundle = ""
            if AudioObjectGetPropertyData(id, &b, 0, nil, &bn, &cf) == noErr, let s = cf?.takeRetainedValue() as String? { bundle = s }
            if bundle.isEmpty { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            guard !bundle.isEmpty, !ignored.contains(where: { bundle.hasPrefix($0) }) else { return nil }
            return MicUser(bundle: bundle, pid: pid)
        }
    }

    /// Name of the outermost .app containing the process: ".../Dia.app/.../Browser Helper.app/..." → "Dia".
    nonisolated static func appName(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/") else { return nil }
        let app = String(path[..<r.lowerBound]) + ".app"
        let info = Bundle(path: app)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
    }

    /// The call app in use, if any: (name, isBrowser).
    nonisolated(unsafe) private static var lastSeen = ""
    private static func callInProgress() -> (String, Bool)? {
        let users = micUsers()
        let seen = users.map(\.bundle).sorted().joined(separator: ", ")
        if seen != lastSeen { lastSeen = seen; log("mic users: [\(seen)]") }
        for app in callApps { if users.contains(where: { $0.bundle.hasPrefix(app.prefix) }) { return (app.name, false) } }
        for app in browsers {
            if let u = users.first(where: { $0.bundle.hasPrefix(app.prefix) }) { return (u.appName ?? app.name, true) }
        }
        return nil
    }

    /// The calendar event happening now (started up to 10 min early).
    private static var currentEvent: EKEvent? {
        let now = Date()
        return Agenda.shared.events(from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(10 * 60))
            .filter { $0.startDate <= now.addingTimeInterval(10 * 60) && $0.endDate > now }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    private func tick() {
        let call = Self.callInProgress()
        if let s = session {
            if call != nil {
                if quietSince != nil { Self.log("mic back: \(s.app)"); if askedStop { emit(.unaskStop) } }
                quietSince = nil; askedStop = false; keep = false
                return
            }
            if s.manual || keep { return }
            // Mic released: probably the call ended. Ask instead of guessing; no answer in 2 min = stop.
            if quietSince == nil { quietSince = Date(); Self.log("mic released: \(s.app)") }
            if !askedStop, Date().timeIntervalSince(quietSince!) > 2 { askedStop = true; emit(.askStop(app: s.app)) }
            if Date().timeIntervalSince(quietSince!) > 120 { emit(.unaskStop); stop() }
            return
        }
        guard let (app, browser) = call else {
            browserSince = nil; dismissed = nil
            if pending != nil, !simulated { pending = nil; emit(.unasked) }   // call ended before you answered
            return
        }
        guard Self.auto, dismissed != app, pending == nil else { return }
        if browser {
            if browserSince == nil { browserSince = Date(); Self.log("browser mic: \(app) \(Self.micUsers())") }
            let inMeeting = Self.currentEvent.map { Agenda.meetingURL($0) != nil } ?? false
            let service = Self.meetingWindow(app)
            guard inMeeting || service != nil || Date().timeIntervalSince(browserSince!) >= Self.browserDelay else { return }
        }
        let name = browser ? "\(app) call" : app
        pending = (name, browser)
        emit(.ask(app: name))
    }

    /// Debug (BUTTERFLY_MEETING_PROMPT=Dia): show the prompt as if a call started.
    func simulateAsk(_ app: String) { simulated = true; pending = ("\(app) call", true); emit(.ask(app: "\(app) call")) }
    private var simulated = false

    /// Your answer to the notch prompt.
    func answer(record: Bool) {
        guard let p = pending else { return }
        pending = nil; simulated = false
        if record { begin(app: p.app, browser: p.browser, manual: false) }
        else { dismissed = p.app.replacingOccurrences(of: " call", with: ""); Self.log("declined: \(p.app)") }
    }

    // MARK: recording

    func toggle() {
        guard session == nil else { stop(byHand: true); return }
        pending = nil
        let call = Self.callInProgress()
        begin(app: call.map { $0.1 ? "\($0.0) call" : $0.0 } ?? "Meeting", browser: call?.1 ?? false, manual: true)
    }

    private func begin(app: String, browser: Bool, manual: Bool) {
        let event = Self.currentEvent
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        let name = (event?.title ?? app).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = Self.root.appendingPathComponent("\(stamp) \(name)", isDirectory: true)
        let recorder = MeetingRecorder(folder: folder)
        session = Session(recorder: recorder, app: app, browser: browser, started: Date(), event: event, manual: manual)
        quietSince = nil
        Task {
            do {
                try await recorder.start(micUID: AudioInput.chosen?.uid)
                emit(.started(app: app))
            } catch {
                session = nil
                dismissed = app
                emit(.failed(error.localizedDescription))
                if case MeetingRecorder.Failure.permission = error {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    func stop(byHand: Bool = false) {
        guard let s = session else { return }
        session = nil
        askedStop = false; keep = false
        if byHand { dismissed = s.app.replacingOccurrences(of: " call", with: "") }
        Task { await finish(s) }
    }

    private func finish(_ s: Session) async {
        let stats = s.recorder.stats
        let folder = s.recorder.folder
        guard stats.seconds >= 30, max(stats.themPeak, stats.mePeak) > 0.01 else {
            _ = try? await s.recorder.stop()   // release ScreenCaptureKit
            try? FileManager.default.removeItem(at: folder)   // too short or silent: not a meeting
            emit(.discarded(app: s.app))
            return
        }
        emit(.stopped(app: s.app))
        let title = s.event?.title ?? s.app
        let attendees = (s.event?.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        let header = """
        # \(title)
        \(s.started.formatted(date: .complete, time: .shortened)) · \(Int(stats.seconds / 60)) min · \(s.app)\(attendees.isEmpty ? "" : "\nAttendees: " + attendees.joined(separator: ", "))


        """
        let transcript = folder.appendingPathComponent("transcript.md")
        inFlight.insert(folder.path)
        defer { inFlight.remove(folder.path) }
        do {
            let audio = try await s.recorder.stop()
            guard let key = Keychain.geminiKey else {
                try (header + "_No Gemini API key: add one in Butterfly Settings, then choose Transcribe Last Meeting._\n").write(to: transcript, atomically: true, encoding: .utf8)
                emit(.failed("Recorded, but no Gemini key to transcribe")); return
            }
            let text = try await MeetingTranscriber.transcribe(.init(mixed: audio, sides: s.recorder.sides), title: s.event?.title, attendees: attendees, me: Self.myName, key: key)
            try (header + text + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            // No calendar event: the folder is named after the app ("Slack"). Name it after what was actually discussed.
            let (named, finalTitle) = s.event == nil ? await Self.titleFromTranscript(folder, text: text, key: key) : (folder, title)
            emit(.saved(title: finalTitle, folder: named))
        } catch {
            try? (header + "_Transcription failed: \(error.localizedDescription)_\n\n_Butterfly retries on its own (next try in 1 min)._\n").write(to: transcript, atomically: true, encoding: .utf8)
            retries[folder.path] = (0, Date().addingTimeInterval(Self.retryDelays[0]))
            emit(.failed("Transcript failed, retrying in 1 min"))
        }
    }

    /// Re-run Gemini on the newest recording (after adding a key, or if it failed).
    /// `done` gets the folder after any rename (nil on failure). `quiet`: an auto-retry, no notch alert if it fails again.
    func retranscribeLast(folder: URL? = nil, quiet: Bool = false, done: ((URL?) -> Void)? = nil) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.creationDateKey]),
              let last = folder ?? dirs.filter({ fm.fileExists(atPath: $0.appendingPathComponent("meeting.m4a").path) })
                  .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let key = Keychain.geminiKey else { emit(.failed("No recording or no Gemini key")); done?(nil); return }
        let transcript = last.appendingPathComponent("transcript.md")
        let id = last.path
        guard !inFlight.contains(id) else { done?(nil); return }   // already being transcribed
        let old = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        let header = Self.split(old).header
        let title = String(last.lastPathComponent.dropFirst(17))
        inFlight.insert(id)
        Task {
            defer { inFlight.remove(id) }
            do {
                let me = last.appendingPathComponent("me.m4a"), them = last.appendingPathComponent("them.m4a")
                let both = fm.fileExists(atPath: me.path) && fm.fileExists(atPath: them.path)
                let text = try await MeetingTranscriber.transcribe(.init(mixed: last.appendingPathComponent("meeting.m4a"), sides: both ? (me, them) : nil),
                                                                   title: title, attendees: [], me: Self.myName, key: key)
                try (header + text + "\n").write(to: transcript, atomically: true, encoding: .utf8)
                retries[id] = nil
                let (named, finalTitle) = Self.appNames.contains(title) ? await Self.titleFromTranscript(last, text: text, key: key) : (last, title)
                emit(.saved(title: finalTitle, folder: named))
                done?(named)
            } catch {
                // Network dropped mid-try: that attempt doesn't count.
                let msg = error.localizedDescription
                if !online || error is URLError || ["network connection", "offline", "timed out", "Internet connection"].contains(where: msg.contains),
                   let r = retries[id], r.count > 0 { retries[id] = (r.count - 1, r.next) }
                let left = retries[id].map { $0.count < Self.retryDelays.count } ?? false
                let next = !online ? "\n\n_Butterfly retries on its own when you're back online._"
                    : left ? "\n\n_Butterfly retries on its own (next try \(retries[id]!.next.formatted(date: .omitted, time: .shortened)))._" : ""
                try? (header + "_Transcription failed: \(error.localizedDescription)_\(next)\n").write(to: transcript, atomically: true, encoding: .utf8)
                Self.log("transcribe failed: \(last.lastPathComponent): \(error.localizedDescription)")
                if !quiet { emit(.failed(error.localizedDescription)) }
                done?(nil)
            }
        }
    }

    /// A saved recording, for the Settings list.
    struct Recording: Identifiable {
        let folder: URL
        var id: String { folder.path }
        var name: String { folder.lastPathComponent }
        var title: String { name.count > 17 ? String(name.dropFirst(17)) : name }
        /// "2026-10-29 13.00" → date.
        var date: Date? { try? Date(String(name.prefix(16)), strategy: Date.ParseStrategy(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)", timeZone: .current)) }
        enum Status { case done, failed, missing }
        let status: Status
        init(folder: URL) {
            self.folder = folder
            let md = (try? FileHandle(forReadingFrom: folder.appendingPathComponent("transcript.md")))
                .flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 4096) }   // the failure note sits right under the header
                .map { String(decoding: $0, as: UTF8.self) }
            // Only the note right under the header counts: a transcript that merely mentions "failed" is fine.
            let body = md.map { Meetings.split($0).body.trimmingCharacters(in: .whitespacesAndNewlines) }
            let empty = body?.isEmpty ?? false   // header only (cut off mid-write)
            let noKey = body?.hasPrefix("_No Gemini API key") ?? false
            status = body == nil ? .missing : empty || noKey || body!.hasPrefix("_Transcription failed") ? .failed : .done
            reason = status != .failed ? nil
                : noKey ? "No Gemini API key. Add one under API Keys."
                : empty ? "The transcript is empty: it was cut off before Gemini finished."
                : body!.components(separatedBy: "\n").filter { $0.hasPrefix("_Transcription failed") || $0.hasPrefix("_Butterfly retries") }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_")) }.joined(separator: "\n\n")
        }
        /// Why it failed (and when the next auto-retry is), from the note in transcript.md.
        let reason: String?
    }

    /// transcript.md → the "# title / date / attendees" block (with its blank line) and everything under it.
    nonisolated static func split(_ md: String) -> (header: String, body: String) {
        guard md.hasPrefix("# "), let r = md.range(of: "\n\n") else { return ("", md) }
        return (String(md[..<r.upperBound]), String(md[r.upperBound...]))
    }

    /// Every recording with audio, newest first.
    static func recordings() -> [Recording] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("meeting.m4a").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(Recording.init)
    }

    /// Who's on the mic track: the Mac's account name.
    static var myName: String { NSFullUserName().isEmpty ? "Me" : NSFullUserName() }

    /// Folder names that are just the call app, not a meeting title.
    nonisolated static let appNames: Set<String> = {
        var n = Set(callApps.map(\.name)).union(["Google Meet", "Whereby", "Jitsi", "Slack huddle", "Microsoft Teams"])
        for b in browsers.map(\.name) { n.insert(b); n.insert(b + " call") }
        return n
    }()

    /// Asks Gemini for a title from the transcript, renames the folder "2026-10-29 13.00 Slack" → "2026-10-29 13.00 <title>"
    /// and fixes the "# title" line. Returns (folder, title); unchanged if anything fails.
    static func titleFromTranscript(_ folder: URL, text: String, key: String) async -> (URL, String) {
        let stamp = String(folder.lastPathComponent.prefix(16))
        let old = String(folder.lastPathComponent.dropFirst(17))
        guard text != MeetingTranscriber.noSpeech, text.count > 600,   // a minute of chatter has no topic to name
              let raw = try? await MeetingTranscriber.title(for: text, key: key) else { return (folder, old) }
        let title = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard title != old else { return (folder, old) }
        var dest = root.appendingPathComponent("\(stamp) \(title)", isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) { dest = root.appendingPathComponent("\(stamp) \(title) (\(stamp.suffix(5)))", isDirectory: true) }
        let transcript = folder.appendingPathComponent("transcript.md")
        if let md = try? String(contentsOf: transcript, encoding: .utf8), md.hasPrefix("# \(old)\n") {
            try? ("# \(title)\n" + md.dropFirst("# \(old)\n".count)).write(to: transcript, atomically: true, encoding: .utf8)
        }
        do { try FileManager.default.moveItem(at: folder, to: dest) } catch { return (folder, title) }
        return (dest, title)
    }

    /// Older recordings still named after the app: give them titles too (runs once at launch, in the background).
    static func nameUntitledFolders() {
        guard let key = Keychain.geminiKey, let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        Task.detached(priority: .background) {
            for d in dirs where appNames.contains(String(d.lastPathComponent.dropFirst(17))) {
                let md = d.appendingPathComponent("transcript.md")
                guard let text = try? String(contentsOf: md, encoding: .utf8), Recording(folder: d).status == .done else { continue }
                let body = split(text).body
                _ = await titleFromTranscript(d, text: body, key: key)
            }
        }
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Butterfly is rarely the active app here (menu bar): ask Finder to come forward, or the window opens behind.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.open([root], withApplicationAt: finder, configuration: config)
    }
}
