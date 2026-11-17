import AVFoundation

/// Headless check that a meeting recording survives macOS ending the capture mid-call (the 17 Nov 2026 bug:
/// 85 min recorded as 1 min). `BUTTERFLY_CAPTURE_TEST=1 Butterfly.app/Contents/MacOS/Butterfly` → exit 0 = pass.
/// Play sound during the run (CI: a looped tone) so there's something to capture.
@MainActor
enum CaptureTest {
    static func run() {
        setlinebuf(stdout)
        Meetings.testMode = true
        Meetings.shared.start()   // the 1.5 s tick that runs the stall watchdog
        Task {
            let failures = await scenario()
            print(failures.isEmpty ? "CAPTURE TEST: PASS" : "CAPTURE TEST: FAIL\n- " + failures.joined(separator: "\n- "))
            exit(failures.isEmpty ? 0 : 1)
        }
        RunLoop.main.run()
    }

    private static func say(_ s: String) { print("[\(Date().formatted(.iso8601))] \(s)"); Meetings.log("capture test: \(s)") }
    private static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    private static func scenario() async -> [String] {
        let m = Meetings.shared
        var fails: [String] = []
        m.toggle()
        await wait(3)
        guard let rec = m.debugRecorder, rec.secondsSinceAudio < 3 else {
            return ["capture never started (permission? no audio device?) lastError: \(String(describing: m.debugRecorder?.lastError))"]
        }
        let began = Date()
        func expectRestarts(_ n: Int, within: Double, _ what: String) async {
            let deadline = Date().addingTimeInterval(within)
            while m.restarts < n, Date() < deadline { await wait(0.5) }
            if m.restarts < n { fails.append("\(what): no restart within \(Int(within)) s (restarts \(m.restarts)/\(n))") }
            else { say("\(what): restarted (\(m.restarts))") }
        }

        await wait(10)
        say("1. silent kill (what macOS did on 17 Nov)")
        await rec.debugKill(notify: false)
        await expectRestarts(1, within: 25, "silent kill")

        await wait(8)
        say("2. kill with didStopWithError")
        await rec.debugKill(notify: true)
        await expectRestarts(2, within: 5, "error kill")

        await wait(8)
        say("3. five kills in a row, 0.3 s apart")
        for _ in 0..<5 { await rec.debugKill(notify: true); await wait(0.3) }
        // A kill can land while a restart is in flight; the stall watchdog (15 s) has to catch that one.
        let deadline = Date().addingTimeInterval(25)
        await wait(3)
        while rec.secondsSinceAudio > 2, Date() < deadline { await wait(0.5) }
        if rec.secondsSinceAudio > 2 { fails.append("burst: capture not back after 25 s (restarts \(m.restarts))") }
        else { say("burst: capture back (restarts \(m.restarts))") }

        await wait(10)
        let wall = Date().timeIntervalSince(began) + 3
        say("4. stop")
        let mixed: URL
        do { mixed = try await m.stopForTest() } catch { return fails + ["stop failed: \(error)"] }

        // The file must cover the whole call (gaps become silence), and the audio after the last restart must be real.
        let folder = mixed.deletingLastPathComponent()
        for name in ["meeting.m4a", "them.m4a", "me.m4a"] {
            let url = folder.appendingPathComponent(name)
            guard let f = try? AVAudioFile(forReading: url) else { say("\(name): missing"); continue }
            let secs = Double(f.length) / f.processingFormat.sampleRate
            let p = peaks(f, window: 5)
            say("\(name): \(String(format: "%.1f", secs)) s of \(String(format: "%.1f", wall)) s, peak per 5 s: \(p.map { String(format: "%.2f", $0) }.joined(separator: " "))")
            if name == "meeting.m4a" {
                if secs < wall - 5 { fails.append("meeting.m4a is \(Int(secs)) s, call was \(Int(wall)) s: audio lost") }
                if (p.suffix(2).max() ?? 0) < 0.005 { fails.append("meeting.m4a is silent at the end: capture didn't really come back") }
            }
        }
        if FileManager.default.fileExists(atPath: folder.path) == false { fails.append("folder missing") }
        return fails
    }

    private static func peaks(_ f: AVAudioFile, window: Double) -> [Float] {
        let fmt = f.processingFormat
        let n = AVAudioFrameCount(window * fmt.sampleRate)
        var out: [Float] = []
        while f.framePosition < f.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n), (try? f.read(into: b, frameCount: n)) != nil,
                  b.frameLength > 0, let d = b.floatChannelData?[0] else { break }
            var p: Float = 0
            for i in 0..<Int(b.frameLength) { p = max(p, abs(d[i])) }
            out.append(p)
        }
        return out
    }
}
