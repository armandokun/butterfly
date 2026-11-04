import Darwin
import Foundation

/// Crash reports in ~/Library/Logs/Butterfly/crashes, so "it crashed" always leaves a trail:
/// - fatal signals (Swift traps, segfaults, aborts) and uncaught exceptions → `crash-<launch>.log` with a backtrace
/// - SIGTERM → noted as "terminated"
/// - no clean exit and no crash (SIGKILL, Force Quit, out of memory, power loss) → found next launch via the `running` marker
/// Also, when not started from a terminal, stdout/stderr go to ~/Library/Logs/Butterfly/butterfly.log (previous run: butterfly.prev.log).
enum CrashReporter {
    static let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Butterfly/crashes")
    private static let logs = dir.deletingLastPathComponent()
    private static var marker: URL { dir.appendingPathComponent("running") }

    /// Call first thing at launch. Returns a one-line summary if the previous run didn't end cleanly.
    @discardableResult
    static func install() -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = checkPrevious()
        redirectOutput()

        let stamp = Self.stamp(Date())
        crashPath = strdup(dir.appendingPathComponent("crash-\(stamp).log").path)
        header = strdup("Butterfly \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · pid \(getpid()) · launched \(stamp)\n")
        try? "pid \(getpid())\nlaunched \(stamp)\n".write(to: marker, atomically: true, encoding: .utf8)
        markerPath = strdup(marker.path)
        atexit { if let m = CrashReporter.markerPath { unlink(m) } }

        NSSetUncaughtExceptionHandler { e in
            let text = "Uncaught exception: \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))\n\n"
            CrashReporter.write(text)
        }
        for s in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS, SIGTERM] { signal(s, onSignal) }
        return previous
    }

    // Set at launch, read from the signal handler (which may only use async-signal-safe calls).
    nonisolated(unsafe) private static var crashPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var markerPath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var header: UnsafeMutablePointer<CChar>?

    private static let onSignal: @convention(c) (Int32) -> Void = { sig in
        signal(sig, SIG_DFL)   // a second fault while reporting just ends the process
        let fd = CrashReporter.openReport()
        if fd >= 0 {
            // No allocation here: the heap may be what broke.
            if sig == SIGTERM { CrashReporter.put(fd, "Terminated (SIGTERM) by another process\n") }
            else {
                CrashReporter.put(fd, "Fatal signal ")
                var digits: (CChar, CChar, CChar) = (CChar(48 + sig / 10), CChar(48 + sig % 10), 10)
                withUnsafeBytes(of: &digits) { _ = Darwin.write(fd, $0.baseAddress, 3) }
                CrashReporter.put(fd, "(5 SIGTRAP = Swift runtime error/force unwrap, 6 SIGABRT, 10 SIGBUS, 11 SIGSEGV)\n")
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                let n = backtrace(&frames, 128)
                backtrace_symbols_fd(&frames, n, fd)
            }
            close(fd)
        }
        // The `running` marker stays: next launch sees it next to this report.
        raise(sig)   // default action: macOS still writes its own .ips report too
    }

    private static func openReport() -> Int32 {
        guard let p = crashPath else { return -1 }
        let fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0, let h = header { Darwin.write(fd, h, strlen(h)) }
        return fd
    }
    private static func put(_ fd: Int32, _ s: String) { s.withCString { _ = Darwin.write(fd, $0, strlen($0)) } }
    private static func write(_ s: String) {
        let fd = openReport(); guard fd >= 0 else { return }
        put(fd, s); close(fd)
    }

    /// A leftover marker means the last run was killed without a chance to report.
    private static func checkPrevious() -> String? {
        guard let info = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: marker)
        let launched = info.split(separator: "\n").first { $0.hasPrefix("launched ") }.map { String($0.dropFirst(9)) } ?? "?"
        let report = dir.appendingPathComponent("crash-\(launched).log")
        if let text = try? String(contentsOf: report, encoding: .utf8) {
            return text.contains("SIGTERM") ? "Butterfly was terminated last time: \(report.path)" : "Butterfly crashed last time: \(report.path)"
        }
        let ended = (try? FileManager.default.attributesOfItem(atPath: logs.appendingPathComponent("butterfly.log").path)[.modificationDate] as? Date).map(stamp) ?? "?"
        let note = """
        Butterfly launched \(launched) ended without a clean exit or a crash signal (last output \(ended)).
        Likely: killed (SIGKILL / Force Quit / `kill -9`), out of memory, a hang that was force-quit, or the Mac lost power.
        Its output: \(logs.appendingPathComponent("butterfly.prev.log").path)

        """
        try? note.write(to: report, atomically: true, encoding: .utf8)
        return "Butterfly was killed last time: \(report.path)"
    }

    private static func redirectOutput() {
        guard isatty(STDERR_FILENO) == 0 else { return }   // from a terminal: keep printing there
        let log = logs.appendingPathComponent("butterfly.log"), prev = logs.appendingPathComponent("butterfly.prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: log, to: prev)
        freopen(log.path, "a", stdout); freopen(log.path, "a", stderr)
        setlinebuf(stdout); setlinebuf(stderr)
        print("— Butterfly launched \(Date()) · pid \(getpid())")
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: d)
    }
}
