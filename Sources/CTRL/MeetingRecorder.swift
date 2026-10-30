import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records a call: everything the Mac plays (the other people) and your mic, as two files,
/// then mixes them into one `meeting.m4a`. ScreenCaptureKit gives both streams on one clock.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay, permission
        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display to capture from"
            case .permission: "Butterfly needs Screen & System Audio Recording permission"
            }
        }
    }

    let folder: URL
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "butterfly.meeting.audio", qos: .userInitiated)
    private var tracks: [Track] = []
    private(set) var lastError: Error?

    /// One stream (call audio or mic) → one AAC file, gaps filled with silence so both stay in sync.
    private final class Track {
        let url: URL
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var source: AVAudioFormat?
        var start: CMTime?
        var written: AVAudioFramePosition = 0
        var peak: Float = 0
        var recent: Float = 0   // loudness right now (decays), for the notch bars
        static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        init(_ url: URL) { self.url = url }

        func append(_ sb: CMSampleBuffer) {
            guard sb.isValid, sb.numSamples > 0, let desc = sb.formatDescription,
                  var asbd = desc.audioStreamBasicDescription, let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
            let frames = AVAudioFrameCount(sb.numSamples)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
            let mono = convert(pcm)
            guard let mono, mono.frameLength > 0 else { return }
            if file == nil {
                file = try? AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                start = sb.presentationTimeStamp
            }
            guard let file, let start else { return }
            // Where this buffer belongs on the timeline; pad silence if the stream paused (nothing playing).
            let at = AVAudioFramePosition((sb.presentationTimeStamp - start).seconds * 48000)
            if at - written > 2400 { writeSilence(AVAudioFrameCount(at - written)) }
            if let d = mono.floatChannelData?[0] {
                var p: Float = 0
                for i in 0..<Int(mono.frameLength) { p = max(p, abs(d[i])) }
                peak = max(peak, p)
                recent = max(p, recent * 0.85)
            }
            try? file.write(from: mono)
            written += AVAudioFramePosition(mono.frameLength)
        }

        private func writeSilence(_ n: AVAudioFrameCount) {
            var left = n
            while left > 0 {
                let c = min(left, 48000)
                guard let b = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: c) else { return }
                b.frameLength = c   // zero-filled
                try? file?.write(from: b)
                written += AVAudioFramePosition(c)
                left -= c
            }
        }

        private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if pcm.format == Self.format { return pcm }
            if source != pcm.format { source = pcm.format; converter = AVAudioConverter(from: pcm.format, to: Self.format); converter?.downmix = true }
            guard let converter else { return nil }
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * 48000 / pcm.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            return err == nil ? out : nil
        }

        func close() { file = nil }
    }

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    var them: URL { folder.appendingPathComponent("them.m4a") }
    var me: URL { folder.appendingPathComponent("me.m4a") }
    var mixed: URL { folder.appendingPathComponent("meeting.m4a") }

    /// - Parameter micUID: the mic to record (nil = the system's input).
    func start(micUID: String?) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw Failure.permission }
        guard let display = content.displays.first else { throw Failure.noDisplay }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.captureMicrophone = true
        if let micUID { c.microphoneCaptureDeviceID = micUID }
        c.sampleRate = 48000
        c.channelCount = 1
        // Audio only: the smallest, slowest video ScreenCaptureKit allows.
        c.width = 2; c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.showsCursor = false
        tracks = [Track(them), Track(me)]
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: tracks.first?.append(sb)
        case .microphone: tracks.last?.append(sb)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { lastError = error }

    /// Seconds recorded, and how loud each side got (0 = silent).
    /// How loud the call is right now (either side), 0…1. Read from the UI, a slightly stale value is fine.
    var level: Float {
        let v = tracks.map(\.recent).max() ?? 0
        tracks.forEach { $0.recent *= 0.8 }   // falls back to quiet if buffers stop coming
        return min(1, sqrt(v))
    }

    /// Seconds recorded, and how loud each side got (0 = silent).
    var stats: (seconds: Double, themPeak: Float, mePeak: Float) {
        queue.sync { (Double(tracks.map(\.written).max() ?? 0) / 48000, tracks.first?.peak ?? 0, tracks.last?.peak ?? 0) }
    }

    /// Both sides as separate files on the same timeline (set by `stop()`): the user's mic and everyone else.
    /// nil when one side never produced audio or the two started more than a quarter second apart.
    private(set) var sides: (me: URL, them: URL)?

    /// Stops and mixes. Returns the mixed file (or the one side that has audio).
    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        stream = nil
        let starts: [CMTime?] = queue.sync { tracks.forEach { $0.close() }; return tracks.map(\.start) }
        let files = zip([them, me], starts).compactMap { url, start in start.map { (url, $0) } }
        guard let first = files.map(\.1).min() else { throw Failure.noDisplay }
        if files.count == 1 { try? FileManager.default.copyItem(at: files[0].0, to: mixed); return mixed }
        if let a = starts[0], let b = starts[1], abs((a - b).seconds) < 0.25 { sides = (me, them) }

        let comp = AVMutableComposition()
        for (url, start) in files {
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first,
                  let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = try await src.load(.timeRange)
            try dst.insertTimeRange(range, of: src, at: start - first)
        }
        try? FileManager.default.removeItem(at: mixed)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return them }
        try await export.export(to: mixed, as: .m4a)
        return mixed
    }
}
