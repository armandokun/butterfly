import AppKit
import AVFoundation
import CoreText
import ScreenCaptureKit

/// Developer mode: one screen video per listening session — from ⌥ down (or locking) through every command, its
/// routing, actions, click checks and planner steps, until Butterfly has been idle for 5 s. Captions burned in (the
/// current utterance + the latest decision, a red dot + timer) and a ring where Butterfly clicked; then a 16-frame
/// contact sheet. ~/Library/Application Support/CTRL/debug/sessions/<date>_<id>/{video.mp4, contact-sheet.jpg, session.md}
@MainActor
final class RunVideo {
    static let shared = RunVideo()
    static let cap: TimeInterval = 600, idleAfter: TimeInterval = 5
    static var sessionsDir: URL { DebugRecorder.root.appendingPathComponent("sessions") }

    struct Run { let id: UUID; let folder: String; let said: String; let offset: Double; var outcome: String? }
    private var session: Session?
    private var folder: URL?
    private var began = Date()
    private var runs: [Run] = []
    private var open: Set<UUID> = []
    private var lastActive = Date()
    private var lastTranscript = ""
    private var ending = false
    private var watch: Task<Void, Never>?
    /// Set by the notch: is it doing something (listening while ⌥ is held, thinking, a request in flight), and what it hears.
    private var activity: () -> (busy: Bool, transcript: String) = { (false, "") }
    /// Called with the session folder once it's saved (self-test).
    var onSaved: ((URL?) -> Void)?

    /// A listening session started (⌥ down / locked). Already recording: the same session goes on.
    func start(force: Bool = false, activity: @escaping () -> (busy: Bool, transcript: String)) {
        self.activity = activity
        touch()
        guard force || DebugRecorder.enabled, session == nil, CGPreflightScreenCaptureAccess() else { return }
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName, ScreenMemory.isExcluded(app) { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = Self.sessionsDir.appendingPathComponent("\(f.string(from: Date()))_\(UUID().uuidString.prefix(8).lowercased())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let display = Memory.lastDisplay ?? Memory.displayUnderMouse ?? CGMainDisplayID()
        let s = Session(display: display, url: dir.appendingPathComponent("video.mp4"))
        session = s; folder = dir; began = Date(); runs = []; open = []; ending = false
        Task { [weak self] in
            do { try await s.start() } catch { if self?.session === s { self?.session = nil; try? FileManager.default.removeItem(at: dir) } }
        }
        // Idle watchdog: 5 s with nothing going on (or 10 min in total) ends the session.
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.session === s else { return }
                let a = self.activity()
                if a.busy || !self.open.isEmpty || a.transcript != self.lastTranscript { self.lastTranscript = a.transcript; self.touch() }
                if !a.transcript.isEmpty, a.busy { s.caption("🎙 " + a.transcript, query: true, log: false) }
                let idle = Date().timeIntervalSince(self.lastActive)
                if idle >= (self.ending ? 1 : Self.idleAfter) || Date().timeIntervalSince(self.began) >= Self.cap { return self.stop() }
            }
        }
    }

    private func touch() { lastActive = Date() }

    /// A run (one utterance) began: noted with its offset in the video.
    func attach(_ id: UUID, folder runFolder: String, said: String) {
        guard let session else { return }
        runs.append(Run(id: id, folder: runFolder, said: said, offset: max(0, Date().timeIntervalSince(session.startedAt))))
        open.insert(id); touch()
        session.caption("“\(said)”", query: true)
    }

    func caption(_ text: String) { session?.caption(text); if session != nil { touch() } }
    func ring(at p: CGPoint) { session?.ring(p); if session != nil { touch() } }

    /// The run finished its action (incl. click checks).
    func finished(_ id: UUID, outcome: String?) {
        guard session != nil, open.remove(id) != nil else { return }
        if let i = runs.firstIndex(where: { $0.id == id }) { runs[i].outcome = outcome }
        touch()
    }

    /// Cancelled / locked mode ended: stop as soon as nothing is in flight.
    func end() { if session != nil { ending = true } }

    /// A private app came forward: nothing of this session is kept.
    func discard() {
        runs = []
        stop()
    }

    /// Runs that were real commands (not asides / "not a command"): without one, the session isn't kept.
    private var commands: [Run] { runs.filter { !($0.outcome ?? "").hasPrefix("aside") && $0.outcome != "notACommand" } }

    private func stop() {
        watch?.cancel(); watch = nil
        guard let s = session, let dir = folder else { return }
        session = nil; folder = nil
        let keep = commands.isEmpty ? [] : runs
        runs = []; open = []
        Task {
            let url = await s.finish()
            guard url != nil, !keep.isEmpty else { try? FileManager.default.removeItem(at: dir); onSaved?(nil); return }
            let ok = await Self.contactSheet(dir.appendingPathComponent("video.mp4"), captions: s.timeline, to: dir.appendingPathComponent("contact-sheet.jpg"), count: 16)
            let duration = (try? await AVURLAsset(url: dir.appendingPathComponent("video.mp4")).load(.duration).seconds) ?? 0
            var md = "# Session \(dir.lastPathComponent)\n\nOne screen video of a whole listening session (\(Session.clock(duration)), \(keep.count) utterances), for an AI coding agent fixing Butterfly. "
            md += "Captions burned in: the utterance and the latest decision; yellow rings mark clicks.\n\n- Video: [video.mp4](video.mp4)\n"
            if ok { md += "- Contact sheet: [contact-sheet.jpg](contact-sheet.jpg)\n\n![contact sheet](contact-sheet.jpg)\n" }
            md += "\n## Runs (offset in the video)\n\n| At | Said | Outcome | Run |\n|---|---|---|---|\n"
            for r in keep {
                md += "| \(Session.clock(r.offset)) | \(r.said.replacingOccurrences(of: "|", with: "/")) | \((r.outcome ?? "—").replacingOccurrences(of: "|", with: "/").prefix(80)) | [run.md](../../runs/\(r.folder)/run.md) |\n"
                DebugRecorder.shared.attachSession(r.id, session: dir.lastPathComponent, offset: r.offset)
            }
            try? md.write(to: dir.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
            onSaved?(dir)
        }
    }

    // MARK: Contact sheet

    /// Evenly spaced frames in a 4-wide grid, each labeled with its time and the caption showing then.
    static func contactSheet(_ video: URL, captions: [(t: Double, text: String)], to out: URL, count: Int = 12) async -> Bool {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return false }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .init(value: 1, timescale: 10); gen.requestedTimeToleranceAfter = .init(value: 1, timescale: 10)
        gen.maximumSize = CGSize(width: 480, height: 480)
        var tiles: [(CGImage, Double)] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { tiles.append((img, t)) }
        }
        guard let first = tiles.first?.0 else { return false }
        let cols = 4, rows = (tiles.count + cols - 1) / cols
        let tw = CGFloat(first.width), th = CGFloat(first.height), label: CGFloat = 34, gap: CGFloat = 6
        let W = Int(CGFloat(cols) * (tw + gap) + gap), H = Int(CGFloat(rows) * (th + label + gap) + gap)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, (img, t)) in tiles.enumerated() {
            let x = gap + CGFloat(i % cols) * (tw + gap)
            let y = CGFloat(H) - gap - CGFloat(i / cols + 1) * (th + label + gap) + gap   // top row first
            ctx.draw(img, in: CGRect(x: x, y: y + label, width: tw, height: th))
            let caption = captions.last { $0.t <= t }?.text ?? "listening…"
            Text.draw("\(Session.clock(t))  \(caption)", in: ctx, at: CGPoint(x: x + 4, y: y + 11), width: tw - 8, size: 13, color: .white)
        }
        guard let image = ctx.makeImage(), let jpg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return false }
        return (try? jpg.write(to: out)) != nil
    }

    enum Text {
        static func draw(_ s: String, in ctx: CGContext, at p: CGPoint, width: CGFloat, size: CGFloat, color: NSColor, bold: Bool = false) {
            let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: color]))
            let fitted = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
            ctx.textPosition = p
            CTLineDraw(fitted, ctx)
        }
    }

    // MARK: Capture + encode

    /// One recording. The stream keeps the newest screen frame; a 10 fps timer composes it with the captions and
    /// encodes it, so the timer and captions advance even while the screen is still. All state lives on `queue`.
    final class Session: NSObject, SCStreamOutput, @unchecked Sendable {
        let display: CGDirectDisplayID, url: URL
        private let queue = DispatchQueue(label: "butterfly.runvideo")
        private var stream: SCStream?
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var latest: CVPixelBuffer?
        private var timer: DispatchSourceTimer?
        private var started = Date()
        private var frames = 0
        private var lastPTS = CMTime.negativeInfinity
        private var closed = false   // finish() came before start() got going
        private var query = ""
        private var current = ""
        private var rings: [(p: CGPoint, at: Date)] = []
        private var _timeline: [(t: Double, text: String)] = []
        private let bounds: CGRect
        let width: Int, height: Int

        init(display: CGDirectDisplayID, url: URL) {
            self.display = display; self.url = url
            bounds = CGDisplayBounds(display)
            width = 1280
            height = Int((1280 * bounds.height / max(bounds.width, 1)).rounded(.down)) & ~1
        }

        var timeline: [(t: Double, text: String)] { queue.sync { _timeline } }
        var startedAt: Date { queue.sync { started } }   // video time zero
        static func clock(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

        func caption(_ text: String, query isQuery: Bool = false, log: Bool = true) {
            let t = Date()
            queue.async { [self] in
                if isQuery { if query != text, log { current = "" }; query = text } else { current = text }
                if log { _timeline.append((t.timeIntervalSince(started), text)) }
            }
        }
        func ring(_ p: CGPoint) { let t = Date(); queue.async { [self] in rings.append((p, t)) } }

        func start() async throws {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == display }) ?? content.displays.first else { throw CocoaError(.featureUnsupported) }
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let c = SCStreamConfiguration()
            c.width = width; c.height = height
            c.pixelFormat = kCVPixelFormatType_32BGRA
            c.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            c.queueDepth = 5
            c.showsCursor = true
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoMaxKeyFrameIntervalKey: 20]])
            i.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            w.add(i)
            guard w.startWriting() else { throw w.error ?? CocoaError(.fileWriteUnknown) }
            w.startSession(atSourceTime: .zero)
            let s = SCStream(filter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), configuration: c, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            queue.sync { writer = w; input = i; adaptor = a; started = Date() }
            try await s.startCapture()
            if queue.sync(execute: { closed }) { try? await s.stopCapture(); w.cancelWriting(); try? FileManager.default.removeItem(at: url); return }
            queue.sync {
                stream = s
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(100))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                timer = t
            }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let pb = sb.imageBuffer,
                  let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  (info[.status] as? Int).flatMap(SCFrameStatus.init) == .complete else { return }
            latest = pb
        }

        /// Copies the newest frame into a fresh buffer and draws the overlay on it.
        private func tick() {
            guard let latest, let adaptor, let input, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return }
            CVPixelBufferLockBaseAddress(latest, .readOnly); CVPixelBufferLockBaseAddress(out, [])
            defer { CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(latest, .readOnly) }
            guard let src = CVPixelBufferGetBaseAddress(latest), let dst = CVPixelBufferGetBaseAddress(out) else { return }
            let (sr, dr) = (CVPixelBufferGetBytesPerRow(latest), CVPixelBufferGetBytesPerRow(out))
            let rows = min(CVPixelBufferGetHeight(latest), height), rowBytes = min(sr, dr, width * 4)
            for y in 0..<rows { memcpy(dst + y * dr, src + y * sr, rowBytes) }
            if let ctx = CGContext(data: dst, width: width, height: height, bitsPerComponent: 8, bytesPerRow: dr, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                overlay(ctx)
            }
            // Wall-clock time: offsets in session.md / captions line up with the video even when frames were skipped.
            let pts = CMTime(seconds: Date().timeIntervalSince(started), preferredTimescale: 600)
            guard pts > lastPTS else { return }
            if adaptor.append(out, withPresentationTime: pts) { frames += 1; lastPTS = pts }
        }

        private func overlay(_ ctx: CGContext) {
            let W = CGFloat(width), H = CGFloat(height), t = Date().timeIntervalSince(started)
            let scale = W / bounds.width
            // Click rings: grow and fade over 1.2 s.
            rings.removeAll { Date().timeIntervalSince($0.at) > 1.2 }
            for r in rings {
                let age = CGFloat(Date().timeIntervalSince(r.at)) / 1.2
                let c = CGPoint(x: (r.p.x - bounds.minX) * scale, y: H - (r.p.y - bounds.minY) * scale)
                let radius = 14 + 26 * age
                ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1 - age * 0.7)); ctx.setLineWidth(4)
                ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            }
            // Bottom caption bar: what was said, then the latest decision.
            let bar: CGFloat = 64
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.72)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: bar))
            Text.draw(query.isEmpty ? "Listening…" : query, in: ctx, at: CGPoint(x: 16, y: 36), width: W - 32, size: 19, color: .white, bold: true)
            if !current.isEmpty { Text.draw(current, in: ctx, at: CGPoint(x: 16, y: 12), width: W - 32, size: 16, color: NSColor(white: 0.85, alpha: 1)) }
            // Red dot + mm:ss, top-left.
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6)); ctx.fill(CGRect(x: 10, y: H - 40, width: 92, height: 30))
            ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: Int(t * 2) % 2 == 0 ? 1 : 0.45))
            ctx.fillEllipse(in: CGRect(x: 20, y: H - 31, width: 12, height: 12))
            Text.draw(Self.clock(t), in: ctx, at: CGPoint(x: 40, y: H - 31), width: 60, size: 15, color: .white, bold: true)
        }

        /// Stops and closes the file. Nil when nothing was written.
        func finish() async -> URL? {
            let s: SCStream? = queue.sync { closed = true; timer?.cancel(); timer = nil; let s = stream; stream = nil; return s }
            try? await s?.stopCapture()
            let (w, i, n): (AVAssetWriter?, AVAssetWriterInput?, Int) = queue.sync { (writer, input, frames) }
            guard let w, let i, w.status == .writing else { try? FileManager.default.removeItem(at: url); return nil }
            i.markAsFinished()
            await w.finishWriting()
            guard n > 0, w.status == .completed else { try? FileManager.default.removeItem(at: url); return nil }
            return url
        }
    }
}
