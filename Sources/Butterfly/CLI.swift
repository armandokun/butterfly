import AppKit
import AVFoundation
import EventKit
import SwiftUI

/// Debug flags for the Butterfly binary (`build/Butterfly.app/Contents/MacOS/Butterfly --plan "…"`), kept out of the app's
/// own startup. `run` returns true when a flag was handled: the caller keeps the run loop alive and the flag exits the process.
enum CLI {
    @MainActor static func run(_ args: [String]) -> Bool {
        // `open Butterfly.app --args --add-event "title" "yyyy-MM-dd HH:mm" minutes "location" "notes" ["calendar"]` (runs with Butterfly's Calendar access)
        if let i = args.firstIndex(of: "--add-event"), args.count >= i + 6 {
            let a = Array(args[(i + 1)...])
            Task {
                var out = "failed"
                do {
                    let c = try await CalendarWriter.createEvent(title: a[0], start: a[1], durationMinutes: Int(a[2]), location: a[3], notes: a[4], calendar: a.count > 5 ? a[5] : nil, allDay: false, source: "", request: "")
                    out = "added \(c.text)"
                } catch { out = "error \(error.localizedDescription)" }
                try? out.write(toFile: "/tmp/butterfly-add-event.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--date"), i + 1 < args.count {
            for t in args[(i + 1)...] { print(t, "→", CalendarWriter.date(t).map { $0.formatted() } ?? "nil", "time:", CalendarWriter.hasTime(t)) }
            exit(0)
        }
        // `Butterfly --mictest`: records 3 s with the same recorder the notch uses, prints mic, level and transcript.
        if args.contains("--mictest") {
            Task { @MainActor in
                let r = SpeechRecorder()
                var peak: Float = 0
                r.onLevel = { peak = max(peak, $0) }
                try? await r.prepare()
                do { try await r.start() } catch { print("start failed:", error); exit(1) }
                print("listening with:", r.micName ?? "?")
                try? await Task.sleep(for: .seconds(3))
                let text = await r.stop()
                print("peak level:", peak, "· heard:", text.isEmpty ? "(nothing)" : text)
                exit(0)
            }
            return true
        }
        if args.contains("--playlist-art") {
            let names = MediaController.ownPlaylists().prefix(4)
            print("playlists:", Array(names))
            for (n, img) in MediaController.artwork(for: Array(names)) { print(n, "→", img.map { "\($0.size)" } ?? "none") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--route"), i + 1 < args.count {
            routeFromCLI(args[(i + 1)...].joined(separator: " ")); return true
        }
        if let i = args.firstIndex(of: "--set-gemini-key"), i + 1 < args.count { Keychain.saveGemini(args[i + 1]); print("saved"); exit(0) }
        // `--export-debug`: zips the developer-mode debug logs (runs + lessons + INDEX.md) to the Desktop.
        if args.contains("--export-debug") { print(DebugRecorder.export().map { "exported \($0.path)" } ?? "export failed"); exit(0) }
        // `--debug-runs`: the last 10 recorded commands, said → outcome → verdict.
        if args.contains("--debug-runs") {
            for r in DebugRecorder.allRuns().suffix(10).reversed() { print("“\(r.said)” → \(r.outcome ?? "—") → \(r.verdict)\(r.correction.map { " (“\($0)”)" } ?? "")") }
            exit(0)
        }
        // `--session-selftest`: a listening session with 2 fake runs 3 s apart, then idle → auto-stop after 5 s (temp debug dir).
        if args.contains("--session-selftest") {
            if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG_DIR"] == nil { setenv("BUTTERFLY_DEBUG_DIR", NSTemporaryDirectory() + "butterfly-session-selftest", 1) }
            try? FileManager.default.removeItem(at: DebugRecorder.root)
            Task { @MainActor in
                guard DebugRecorder.enabled else { print("turn developer mode on first"); exit(1) }
                let t0 = Date(), video = RunVideo.shared, trace = DecisionTrace.shared
                var busy = true
                video.onSaved = { dir in
                    guard let dir else { print("FAIL session discarded"); exit(1) }
                    Task { @MainActor in
                        let dur = (try? await AVURLAsset(url: dir.appendingPathComponent("video.mp4")).load(.duration).seconds) ?? 0
                        let md = (try? String(contentsOf: dir.appendingPathComponent("session.md"), encoding: .utf8)) ?? ""
                        let runs = DebugRecorder.allRuns()
                        print(String(format: "stopped %.1f s after start · video %.1f s", Date().timeIntervalSince(t0), dur))
                        for r in runs { print("run “\(r.said)” @", RunVideo.Session.clock(r.videoOffset ?? -1), "in", r.session ?? "nil") }
                        let one = Set(runs.compactMap(\.session)).count == 1 && runs.count == 2 && runs.allSatisfy { $0.session != nil }
                        print(one && md.contains("run.md") ? "ok   one video spans both runs" : "FAIL"); print("dir:", dir.path)
                        exit(one ? 0 : 1)
                    }
                }
                video.start { (busy, "") }                                   // ⌥ down: listening
                try? await Task.sleep(for: .seconds(1)); busy = false
                for (i, said) in ["open notes", "click the weather widget"].enumerated() {
                    if i > 0 { try? await Task.sleep(for: .seconds(3)) }
                    trace.begin(said)
                    trace.add(.outcome, i == 0 ? "open(Notes)" : "click(Weather)", nil, ms: 300)
                    if i == 1 { video.ring(at: CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)) }   // ring only, no real click
                    trace.add(.rule, "click check", i == 1 ? "done 0.90" : nil)
                    trace.end()
                }
                print("runs done at", String(format: "%.1f s", Date().timeIntervalSince(t0)), "· waiting for 5 s idle…")
            }
            return true
        }
        if args.contains("--debug-selftest") { debugSelftest(); return true }
        // `--video-selftest`: 4 s of the main display with fake captions + a click ring → mp4 + contact sheet in a temp dir.
        if args.contains("--video-selftest") {
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("butterfly-video-selftest")
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let s = RunVideo.Session(display: CGMainDisplayID(), url: dir.appendingPathComponent("video.mp4"))
                do { try await s.start() } catch { print("start failed:", error); exit(1) }
                let b = CGDisplayBounds(CGMainDisplayID())
                s.caption("“click the weather widget”", query: true)
                for (i, c) in ["Model answered 24 questions", "click(Weather)", "click check — done 0.20", "click check (retry) — done 0.90"].enumerated() {
                    try? await Task.sleep(for: .seconds(1))
                    s.caption(c)
                    if i == 1 { s.ring(CGPoint(x: b.midX, y: b.midY)) }
                }
                guard let url = await s.finish() else { print("no video written"); exit(1) }
                let sheet = dir.appendingPathComponent("contact-sheet.jpg")
                let ok = await RunVideo.contactSheet(url, captions: s.timeline, to: sheet)
                let size = { (u: URL) in ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0), countStyle: .file) }
                let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                print("video:", url.path, size(url), String(format: "%.1f s", dur), "\(s.width)×\(s.height)")
                print("sheet:", ok ? "\(sheet.path) \(size(sheet))" : "failed")
                exit(ok ? 0 : 1)
            }
            return true
        }
        // `--meeting-apps`: which processes use a mic right now (meeting detection).
        if args.contains("--meeting-apps") { print(Meetings.micUsers()); exit(0) }
        // `--memory-test 15`: runs screen memory for N seconds and prints what it captured (debugging).
        if let i = args.firstIndex(of: "--memory-test") {
            _ = NSApplication.shared
            let secs = args.count > i + 1 ? Double(args[i + 1]) ?? 15 : 15
            ScreenMemory.shared.debug = true
            ScreenMemory.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { print(ScreenMemory.shared.count, "screens"); exit(0) }
            return true
        }
        // `--frame-check`: decrypts the newest remembered frame and prints its size (encryption round-trip).
        if args.contains("--frame-check") {
            ScreenMemory.shared.start(); ScreenMemory.shared.stop()
            print(ScreenMemory.shared.count, "screens ·", ByteCountFormatter.string(fromByteCount: ScreenMemory.diskUsage, countStyle: .file), "· excluded:", ScreenMemory.excludedApps.joined(separator: ", "))
            print("excluded? Messages:", ScreenMemory.isExcluded("Messages"), "Safari:", ScreenMemory.isExcluded("Safari"), "Swedbank Lietuva:", ScreenMemory.isExcluded("Swedbank Lietuva"))
            for e in ScreenMemory.shared.newest(3) { print("•", e.image ?? "no image", "→", ScreenMemory.frame(e).map { "\($0.count) bytes decoded" } ?? "no frame") }
            exit(0)
        }
        // `--recall "what was the camera price on stride"`: what screen memory would hand the planner.
        if let i = args.firstIndex(of: "--recall"), i + 1 < args.count {
            ScreenMemory.shared.start(); ScreenMemory.shared.stop()
            print(ScreenMemory.shared.count, "screens remembered")
            for h in ScreenMemory.shared.search(args[i + 1]) { print("• [\(ScreenMemory.when(h.entry.t)) · \(h.entry.app) · \(h.entry.title.prefix(40))] score \(h.score)\n   \(h.snippet.prefix(300))") }
            exit(0)
        }
        // `--click-dry Calendar "click on October 27th"`: top-ranked AX click options in that app; clicks nothing.
        if let i = args.firstIndex(of: "--click-dry"), i + 2 < args.count {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[i + 1] }) else { print("not running"); exit(1) }
            let els = Clicker.elements(of: app)
            let opts = Clicker.options(els, for: args[(i + 2)...].joined(separator: " "), limit: 5)
            print(els.count, "elements,", els.filter { $0.role == "AXList" }.count, "lists")
            for (k, (d, e)) in opts.sorted(by: { $0.value.1.label.count < $1.value.1.label.count }) { print(k, d.prefix(80).replacingOccurrences(of: "\n", with: " "), e.frame) }
            exit(0)
        }
        // `--verify-dry "click on October 27th"`: before/after check with no click in between (expect done ≈ 0).
        if let i = args.firstIndex(of: "--verify-dry"), i + 1 < args.count, let key = Keychain.apiKey {
            Task { @MainActor in
                let d = CGMainDisplayID()
                guard let a = try? await Clicker.screenshot(region: CGDisplayBounds(d), display: d),
                      let b = try? await Clicker.screenshot(region: CGDisplayBounds(d), display: d) else { print("no screenshot"); exit(1) }
                let c = try? await CommandRouter(client: TypeSafeClient(apiKey: key)).verifyClick(args[i + 1], clicked: args[i + 1], before: a, after: b)
                print("done:", c.map { String(format: "%.2f", $0.done) } ?? "error")
                exit(0)
            }
            return true
        }
        // `--widgets`: desktop widgets (Notification Centre AX) with frames and items.
        if args.contains("--widgets") {
            for w in Clicker.widgets() {
                let f = w.group.frame
                print("• \(w.app) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] window “\(w.title.prefix(50))”")
                for e in w.items { print("    \(e.role) “\(e.label.prefix(60))” [\(Int(e.frame.minX)),\(Int(e.frame.minY)) \(Int(e.frame.width))x\(Int(e.frame.height))]") }
            }
            exit(0)
        }
        // `--widget-click-dry "open the weather widget"`: what a widget click would hit; clicks nothing.
        if let i = args.firstIndex(of: "--widget-click-dry"), i + 1 < args.count {
            guard let e = Clicker.widgetTarget(for: args[i + 1]) else { print("no widget matches"); exit(1) }
            let f = e.frame
            print("\(e.role) “\(e.label.prefix(60))” [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] → click \(Int(f.midX)),\(Int(f.midY))")
            exit(0)
        }
        // `--actionable Calendar "Today"` (or `--actionable widget "weather"`): resolves the element and runs the click gate; clicks nothing.
        if let i = args.firstIndex(of: "--actionable"), i + 2 < args.count {
            let label = args[(i + 2)...].joined(separator: " ")
            var e: Clicker.Element?
            if args[i + 1].lowercased() == "widget" { e = Clicker.widgetTarget(for: label) } else {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[i + 1] }) else { print("not running"); exit(1) }
                let els = Clicker.elements(of: app)
                e = els.first { $0.label == label } ?? els.first { $0.label.localizedCaseInsensitiveContains(label) }
            }
            guard let e else { print("no element “\(label)”"); exit(1) }
            let f = e.frame
            print("\(e.role) “\(e.label.prefix(60))” [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] via \(Clicker.usesPress(e) ? "AXPress" : "mouse click")")
            Task { @MainActor in
                let t0 = Date()
                let g = await Clicker.actionable(e)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let p: CGPoint = if case .ok(let p, _) = g { p } else { CGPoint(x: f.midX, y: f.midY) }
                print("\(g.message) → point \(Int(p.x)),\(Int(p.y)) · hit \(Clicker.hitOwner(at: p)) · \(ms) ms")
                exit(0)
            }
            return true
        }
        // `--fingerprint Calendar`: the cheap AX state a click check compares before/after.
        if let i = args.firstIndex(of: "--fingerprint"), i + 1 < args.count {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[i + 1] }) else { print("not running"); exit(1) }
            print(Clicker.fingerprint(nil, app: app).summary)
            exit(0)
        }
        // `--ax-dump Slack [depth]`: prints the focused window's accessibility tree (debugging the settings crawl).
        if let i = args.firstIndex(of: "--ax-dump"), i + 1 < args.count {
            _ = NSApplication.shared
            let want = args[i + 1].lowercased()
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == want }) else { print("not running"); exit(1) }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.6)   // Electron builds its tree after being asked
            print("pid", app.processIdentifier, "hidden", app.isHidden, "bundle", app.bundleIdentifier ?? "-")
            let maxDepth = args.count > i + 2 ? Int(args[i + 2]) ?? 8 : 8
            var n = 0
            func dump(_ el: AXUIElement, _ d: Int) {
                guard d <= maxDepth, n < 1500 else { return }
                n += 1
                let role: String = Clicker.attr(el, kAXRoleAttribute) ?? "?"
                let sub: String = Clicker.attr(el, kAXSubroleAttribute) ?? ""
                let label = Clicker.label(of: el, role: role)
                let f = Clicker.frame(of: el).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
                let v: Any? = Clicker.attr(el, kAXValueAttribute) as Any?
                print(String(repeating: "  ", count: d) + role + (sub.isEmpty ? "" : "/\(sub)") + (label.isEmpty ? "" : " “\(label.prefix(50))”") + (v.map { " =\("\($0)".prefix(30))" } ?? "") + "  [\(f)]")
                let kids: [AXUIElement] = Clicker.attr(el, kAXChildrenAttribute) ?? []
                for k in kids { dump(k, d + 1) }
            }
            let wins: [AXUIElement] = Clicker.attr(ax, kAXWindowsAttribute) ?? []
            let focused: AXUIElement? = Clicker.attr(ax, kAXFocusedWindowAttribute)
            print("\(wins.count) windows, focused: \(focused != nil)")
            for w in wins { dump(w, 0) }
            if wins.isEmpty, let focused { dump(focused, 0) }
            exit(0)
        }
        // `--app-map Slack [--no-crawl]`: learns the running app (menus, settings panes, scripting) and prints what it found.
        if let i = args.firstIndex(of: "--app-map"), i + 1 < args.count {
            _ = NSApplication.shared
            Task {
                let want = args[i + 1].lowercased()
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == want || $0.bundleIdentifier?.lowercased() == want }) else { print("not running:", want); exit(1) }
                let t = Date()
                let m = await AppMap.shared.build(for: app, crawlSettings: !args.contains("--no-crawl")) { print("…", $0) }
                print("\(m?.entries.count ?? 0) entries in \(Int(Date().timeIntervalSince(t) * 1000)) ms · settings crawled: \(m?.settingsCrawled ?? false)")
                for e in m?.entries ?? [] where e.kind != "menu" { print("  ", e.line) }
                if let q = args.firstIndex(of: "--ask"), q + 1 < args.count { print("relevant to “\(args[q + 1])”:"); for l in AppMap.shared.relevant(args[q + 1], in: app) { print("   ", l) } }
                exit(0)
            }
            return true
        }
        // `--plan "search chaseit on linkedin"`: prints the planner's steps and the skill it would learn; `--exec` runs them.
        // `--skills`: lists learned skills; `--skill-match "…"`: which learned skill fires, no model.
        if args.contains("--skills") {
            for s in SkillStore.shared.skills { print("•", s.name, "—", s.pattern, "·", s.uses, "uses\n   ", s.steps.map(Planner.describe).joined(separator: " → ")) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--skill-match"), i + 1 < args.count {
            if let (s, v) = SkillStore.shared.match(args[i + 1]) { print("skill:", s.name, v); print(SkillStore.fill(s.steps, with: v).map(Planner.describe).joined(separator: " → ")) }
            else { print("no match") }
            exit(0)
        }
        // `--skill-semantic "look up tesla on linkedin"`: the classifier picks a learned skill by meaning, Gemini fills its slots.
        if let i = args.firstIndex(of: "--skill-semantic"), i + 1 < args.count {
            Task {
                guard let key = Keychain.apiKey else { print("no API key"); exit(1) }
                let t = Date()
                do {
                    guard let (s, c) = try await SkillStore.shared.semanticMatch(args[i + 1], client: TypeSafeClient(apiKey: key)) else { print("none (\(Int(Date().timeIntervalSince(t) * 1000)) ms)"); exit(0) }
                    print("skill:", s.name, "—", s.pattern, String(format: "(%.2f, %d ms)", c, Int(Date().timeIntervalSince(t) * 1000)))
                    let slots = SkillStore.slots(in: s.pattern)
                    if !slots.isEmpty, let g = Keychain.geminiKey {
                        let t2 = Date()
                        let v = try await Planner.fillSlots(slots, pattern: s.pattern, request: args[i + 1], key: g)
                        print("slots:", v, "(\(Int(Date().timeIntervalSince(t2) * 1000)) ms)")
                        print(SkillStore.fill(s.steps, with: v).map(Planner.describe).joined(separator: " → "))
                    }
                } catch { print("error:", error.localizedDescription) }
                exit(0)
            }
            return true
        }
        // `--split "open notes and then write hello|open slack and safari"`: conjunction gate + how each sentence splits.
        if let i = args.firstIndex(of: "--split"), i + 1 < args.count {
            Task { for l in args[i + 1].components(separatedBy: "|") { print("“\(l)” conj=\(StepSplitter.hasConjunction(l)) →", await StepSplitter.split(l)) }; exit(0) }
            return true
        }
        // `--toggle "click Dark Mode" [App]`: what a click step means and the control's state in that app (defaults to the front app).
        if let i = args.firstIndex(of: "--toggle"), i + 1 < args.count {
            _ = NSApplication.shared
            let app = args.count > i + 2 ? NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased() == args[i + 2].lowercased() } : NSWorkspace.shared.frontmostApplication
            let label = Planner.clickLabel(args[i + 1])
            print("label:", label ?? "nil (not a click)")
            if let label { let s = Clicker.toggleState(label: label, in: app); print("found:", s.found, "value:", s.value.map(String.init) ?? "nil", "in", app?.localizedName ?? "-") }
            exit(0)
        }
        // `--plan-check '[{"do":"applescript","source":"do shell script \"rm -rf ~\""}]' ["request"]`: the safety pass on raw steps.
        if let i = args.firstIndex(of: "--plan-check"), i + 1 < args.count {
            let steps = Planner.steps(json: args[i + 1])
            let request = args.count > i + 2 && !args[i + 2].hasPrefix("--") ? args[i + 2] : ""
            let p = Planner.harden(Planner.Plan(steps: steps, summary: "check"), request: request)
            print("in:", steps.count, "steps · out:", p.steps.count, "steps · summary:", p.summary)
            for s in steps { print("  ", Planner.describe(s), "→", Planner.danger(of: s) ?? "ok") }
            print("confirm:", p.confirm ?? "nil"); print("clarify:", p.clarify ?? "nil")
            exit(0)
        }
        if let i = args.firstIndex(of: "--plan"), i + 1 < args.count {
            _ = NSApplication.shared   // screen capture needs a connection to the window server
            ScreenMemory.shared.start(); ScreenMemory.shared.stop()   // load what's remembered, don't capture
            Task {
                guard let key = Keychain.geminiKey else { print("no Gemini key"); exit(1) }
                AppCatalog.shared.reload()
                let front = NSWorkspace.shared.frontmostApplication
                let t = Date()
                do {
                    let p = try await Planner.plan(args[i + 1], app: front, menu: front.flatMap { MenuReader.snapshot(of: $0) }, elements: front.map { Clicker.elements(of: $0) } ?? [], key: key)
                    print("summary:", p.summary, "(\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                    for s in p.steps { print("  ", s.do, Planner.detail(s)) }
                    if let c = p.confirm { print("confirm:", c) }
                    if let c = p.clarify { print("clarify:", c) }
                    if let r = p.recap { print("recap:", r.title, r.range); for i in r.items { print("   ", i.time, i.app, "—", i.text) } }
                    if let sk = p.skill { print("skill:", sk.name, "—", sk.pattern); for s in sk.steps { print("     ", s.do, Planner.detail(s)) }
                        if args.contains("--learn") { SkillStore.shared.learn(name: sk.name, pattern: sk.pattern, steps: sk.steps, example: args[i + 1]); print("learned") } }
                    if args.contains("--exec") {
                        Planner.openURL = { NSWorkspace.shared.open($0) }
                        Planner.runCommand = { c in print("   [command]", c); return "ok" }
                        let r = await Planner.run(p.steps, app: front)
                        print("run:", r.ok ? "ok" : r.failed ?? "?", r.said)
                    }
                } catch { print("error:", error.localizedDescription) }
                exit(0)
            }
            return true
        }
        // `--transcribe file.m4a|meeting-folder [title]`: Gemini meeting transcript to stdout (a folder uses me.m4a + them.m4a).
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            Task {
                do {
                    guard let key = Keychain.geminiKey else { print("no Gemini key"); exit(1) }
                    let t = Date()
                    let u = URL(fileURLWithPath: args[i + 1])
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let audio = isDir ? MeetingTranscriber.Audio(mixed: u.appendingPathComponent("meeting.m4a"), sides: (u.appendingPathComponent("me.m4a"), u.appendingPathComponent("them.m4a")))
                                      : MeetingTranscriber.Audio(mixed: u)
                    print(try await MeetingTranscriber.transcribe(audio, title: args.count > i + 2 ? args[i + 2] : nil, attendees: [], me: Meetings.myName, key: key))
                    print("(\(Int(Date().timeIntervalSince(t))) s)")
                } catch { print("error:", error.localizedDescription) }
                exit(0)
            }
            return true
        }
        // `open Butterfly.app --args --record-test 20`: records 20 s of call audio + mic, writes /tmp/butterfly-record-test.txt.
        if let i = args.firstIndex(of: "--record-test"), i + 1 < args.count {
            Task {
                let r = MeetingRecorder(folder: URL(fileURLWithPath: "/tmp/butterfly-record-test"))
                var out = ""
                do {
                    try await r.start(micUID: AudioInput.chosen?.uid)
                    try await Task.sleep(for: .seconds(Double(args[i + 1]) ?? 10))
                    let s = r.stats
                    let url = try await r.stop()
                    out = "ok \(url.path) seconds=\(s.seconds) themPeak=\(s.themPeak) mePeak=\(s.mePeak) err=\(r.lastError.map { "\($0)" } ?? "-")"
                } catch { out = "error \(error)" }
                try? out.write(toFile: "/tmp/butterfly-record-test.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        return false
    }

    /// Debug: `Butterfly --route "open facebook dot com"` prints what would happen, opens nothing.
    /// Add `--exec` to actually run it. Starts the work; the caller keeps the run loop alive.
    /// `--debug-selftest` (developer mode, ideally with BUTTERFLY_DEBUG_DIR=/tmp/…): a fake run with a late click check,
    /// a voice correction → declined, then checks run.md, lessons.jsonl, past_mistakes, the skill drop and the export.
    @MainActor private static func debugSelftest() {
        Task { @MainActor in
            func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { exit(1) } }
            check(DebugRecorder.enabled, "developer mode on")
            let trace = DecisionTrace.shared, dbg = DebugRecorder.shared
            let pattern = "selftest open {thing} widget"
            SkillStore.shared.learn(name: "Selftest", pattern: pattern, steps: [], example: "selftest open weather widget")
            trace.begin("click the weather widget")
            let id = trace.currentID!
            dbg.context(NSRunningApplication.current, summary: "0 menu items · 3 clickable elements")
            dbg.options(click: ["the button labeled “Weather”", "the button labeled “Stocks”"], menu: [])
            dbg.skill(pattern)
            trace.add(.outcome, "click(Weather)", nil, ms: 120)
            dbg.hold(id)                                   // a click check still running…
            dbg.action("performed click(Weather)")
            trace.end()                                    // …route finished first
            trace.add(.rule, "click check", "done 0.20", run: id)   // late event lands on the same run
            let ci = dbg.click("Weather", at: CGPoint(x: 100, y: 200), run: id)
            dbg.clickUpdate(ci, run: id) { $0.done = 0.2 }
            dbg.release(id)                                // finalizes now
            trace.begin("no, the weather widget on the desktop")
            trace.add(.outcome, "correction", nil); dbg.followUp("no, the weather widget on the desktop", force: true); trace.end()
            let run = DebugRecorder.allRuns().first { $0.id == id.uuidString }
            check(run?.verdict == "declined", "verdict declined (\(run?.verdict ?? "nil"))")
            check(run?.nodes.contains { $0.title == "click check" } == true, "late click-check node on the right run")
            let md = (try? String(contentsOf: DebugRecorder.runsDir.appendingPathComponent(run?.folder ?? "").appendingPathComponent("run.md"), encoding: .utf8)) ?? ""
            check(md.contains("Verdict: declined") && md.contains("no, the weather widget"), "run.md has verdict + correction")
            let lessons = (try? String(contentsOf: DebugRecorder.lessonsURL, encoding: .utf8)) ?? ""
            check(lessons.contains("click the weather widget"), "lessons.jsonl has the mistake")
            check(dbg.pastMistakes("click weather", app: nil)?.contains("WRONG") == true, "past_mistakes fed for a similar request")
            check(!SkillStore.shared.skills.contains { $0.pattern == pattern }, "declined skill dropped")
            let zip = DebugRecorder.export(to: URL(fileURLWithPath: NSTemporaryDirectory()))
            check(zip != nil, "export → \(zip?.path ?? "nil")")
            let index = (try? String(contentsOf: DebugRecorder.root.appendingPathComponent("INDEX.md"), encoding: .utf8)) ?? ""
            check(index.contains("**declined**") && index.contains("run.md"), "INDEX.md lists the run")
            exit(0)
        }
    }

    @MainActor private static func routeFromCLI(_ text: String) {
        let exec = CommandLine.arguments.contains("--exec")
        let text = text.replacingOccurrences(of: "--exec", with: "").trimmingCharacters(in: .whitespaces)
        AudioOutput.warm()
        AppCatalog.shared.reload()
        print("sites:", URLExtractor.candidates(in: text))
        guard let key = Keychain.apiKey else { print("no API key"); exit(1) }
        Bluetooth.shared.refreshNow()
        // BUTTERFLY_CLIPS="newest|older|oldest" pretends these were copied.
        if let c = ProcessInfo.processInfo.environment["BUTTERFLY_CLIPS"] { Clipboard.shared.seed(c.components(separatedBy: "|")) }
        // BUTTERFLY_MEMORY="said|did|app;said|did|app" pretends these happened just now.
        if let mem = ProcessInfo.processInfo.environment["BUTTERFLY_MEMORY"] {
            for e in mem.split(separator: ";") {
                let f = e.split(separator: "|").map(String.init)
                if f.count >= 2 { Memory.record(said: f[0], did: f[1], app: f.count > 2 ? f[2] : nil) }
            }
        }
        // BUTTERFLY_APP=Dia pretends that app is in front (for menu commands).
        var menu: MenuReader.Snapshot?
        var front: NSRunningApplication?
        var elements: [Clicker.Element] = []
        if let name = ProcessInfo.processInfo.environment["BUTTERFLY_APP"],
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            front = app
            app.activate(); usleep(400_000)   // like real use: the app is in front
            let t0 = Date()
            menu = MenuReader.snapshot(of: app)
            print("menu: \(menu?.items.count ?? 0) items read in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            let t1 = Date()
            elements = ProcessInfo.processInfo.environment["BUTTERFLY_VISUAL"] == "1" ? [] : Clicker.elements(of: app)
            print("clickables: \(elements.count) read in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            if ProcessInfo.processInfo.environment["BUTTERFLY_DUMP"] == "2" { elements.forEach { print("   ", $0.role, $0.label) } }
            if ProcessInfo.processInfo.environment["BUTTERFLY_DUMP"] == "1" { menu?.items.forEach { print("   ", $0.key, $0.shortcut ?? "") } }
        }
        Task {
            let start = Date()
            do {
                let router = CommandRouter(client: TypeSafeClient(apiKey: key))
                let env = ProcessInfo.processInfo.environment
                let cursorSnap = front.flatMap(CursorControl.snapshot)
                if let cursorSnap { print("cursor: \(cursorSnap.chats.count) chats, project \(cursorSnap.currentProject ?? "-"), open: \(cursorSnap.chats.first { $0.current }?.title ?? "-")") }
                let outcome = try await router.route(text, menu: menu, front: front, elements: elements,
                                                     previous: env["BUTTERFLY_PREV"], dictating: env["BUTTERFLY_DICTATING"] == "1", cursor: cursorSnap,
                                                     recentPlan: env["BUTTERFLY_PREVIOUS"]?.components(separatedBy: "|").first)   // BUTTERFLY_PREVIOUS="request|steps": a plan just ran
                let ms = String(format: "(%.0f ms)", Date().timeIntervalSince(start) * 1000)
                if case .cursor(let action, let chat, let project, let message) = outcome {
                    print("outcome: cursor \(action.rawValue) chat=\(chat?.title ?? "-") project=\(project ?? "-") message=“\(message)” \(ms)")
                    if exec, let cursorSnap {
                        let r = await CursorControl.perform(action, chat: chat, project: project, message: message, snapshot: cursorSnap, menu: menu)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1))
                    }
                } else if case .askBrowser(let q) = outcome {
                    print("outcome: askBrowser “\(q)” \(ms)")
                    if exec { let b = await BrowserTab.ask(q); print("executed in \(b?.name ?? "-")"); try? await Task.sleep(for: .seconds(1)) }
                } else if case .type(let text, let ret) = outcome {
                    print("outcome: type “\(text)” return=\(ret) \(ms)")
                    if exec { front?.activate(); try? await Task.sleep(for: .milliseconds(300)); await Typer.type(text, pressReturn: ret); print("executed") }
                } else if case .file(let url, let reveal) = outcome {
                    print("outcome: file \(url.path) reveal=\(reveal) \(ms)")
                    if exec { Files.open(url, reveal: reveal) }
                } else if case .click(let el) = outcome {
                    print("outcome: click \(el.role) “\(el.label)” at \(el.frame) \(ms)")
                    if exec { front?.activate(); Clicker.press(el); try? await Task.sleep(for: .seconds(0.8)); print("executed") }
                } else if case .clickVisual(let app, let what) = outcome {
                    print("outcome: clickVisual “\(what)” \(ms)")
                    let t = Date()
                    let p = try await router.locate(what, in: app)
                    print("   located: \(p.map { "\($0)" } ?? "not visible") (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                    if exec, let p { app.activate(); try? await Task.sleep(for: .seconds(0.3)); Clicker.click(at: p); print("executed") }
                } else if case .routine(let r) = outcome {
                    print("outcome: routine \(r.name) \(ms)")
                    for step in r.runnableSteps {
                        let o = try await CommandRouter(client: TypeSafeClient(apiKey: key)).route(step)
                        print("   step “\(step)” →", o)
                    }
                } else if case .window(let action, let app) = outcome {
                    print("outcome: window \(action.rawValue) app=\(app.localizedName ?? "?") \(ms)")
                    if exec {
                        let r = await WindowCommands.perform(action, app: app)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                } else if case .system(let action, let level) = outcome {
                    print("outcome: system \(action.rawValue) level=\(level.map(String.init) ?? "-") \(ms)")
                    if exec, ![.lock, .sleep, .displayOff].contains(action) {
                        let r = await SystemController.perform(action, level: level)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1.2))
                    }
                } else if case .menu(let item, let app) = outcome {
                    print("outcome: menu \(item.key) \(item.shortcut ?? "") \(ms)")
                    if exec { let ok = await MenuReader.press(item, in: app); try? await Task.sleep(for: .seconds(1)); print("executed", ok) }
                } else if case .open(let p) = outcome {
                    let names = p.targets.map { t -> String in
                        switch t { case .app(let a): a.name; case .site(let u): u.absoluteString }
                    }
                    print("outcome: open \(names) windows=\(p.windowsEach) layout=\(p.layout.rawValue) \(ms)")
                    if exec { await WindowManager.run(p); print("executed, AX trusted:", HotkeyMonitor.hasAccessibility) }
                } else if case .settings(let page, let action) = outcome {
                    print("outcome: settings \(page.key) \(action.rawValue) \(ms)")
                    if exec {
                        let r = SettingsController.perform(page, action: action)
                        print("executed: \(r.title) \(r.detail ?? "")")
                        try? await Task.sleep(for: .seconds(1))   // let deferred activation run
                    }
                } else if case .media(let action, let preferred, let query) = outcome {
                    print("outcome: media \(action.rawValue) preferred=\(preferred ?? "-") query=\(query ?? "-") \(ms)")
                    if exec {
                        let r = await MediaController.perform(action, preferred: preferred, query: query)
                        print("executed: \(r.player?.name ?? "media key") — \(r.title) \(r.detail ?? "")")
                    }
                } else if case .agent(let request) = outcome {
                    print("outcome: agent → planner \(ms)")
                    if exec, let g = Keychain.geminiKey {
                        let t = Date()
                        let p = try await Planner.plan(request, app: front, menu: menu, elements: elements, key: g)
                        print("   plan (\(Int(Date().timeIntervalSince(t) * 1000)) ms): \(p.summary)")
                        for s in p.steps { print("   ", Planner.describe(s)) }
                    }
                } else if case .navigate(let a) = outcome {
                    print("outcome: navigate \(a.rawValue) \(ms)")
                    if exec { let r = await KeyCommands.perform(a, in: front); print("executed: \(r.title)"); try? await Task.sleep(for: .seconds(0.5)) }
                } else if case .screen(let a, let request) = outcome {
                    print("outcome: screen \(a.rawValue) \(ms)")
                    if exec {
                        let t = Date()
                        guard let (text, selected) = await ScreenReader.text(of: front) else { print("no text (screen recording?)"); exit(0) }
                        print("   read \(text.count) chars, selected=\(selected) (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
                        let t2 = Date()
                        let answer = try await ScreenReader.answer(a, request: request, text: text, app: front?.localizedName)
                        print("   answer (\(Int(Date().timeIntervalSince(t2) * 1000)) ms): \(answer)")
                    }
                } else {
                    print("outcome:", outcome, ms)
                }
            } catch { print("error:", error.localizedDescription) }
            exit(0)
        }
    }
}
