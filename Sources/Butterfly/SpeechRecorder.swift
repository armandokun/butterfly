@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// Push-to-talk recorder: on-device SpeechAnalyzer + live audio level.
@MainActor
final class SpeechRecorder {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Locked mode: each finalized phrase and where it ends in the recording (seconds), and the in-progress text.
    var onSegment: ((String, Double) -> Void)?
    var onVolatile: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private var engineDevice: AudioObjectID?
    private var retired: [AVAudioEngine] = []
    /// Name of the mic used for the current/last recording (shown if nothing was heard).
    private(set) var micName: String?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<String, Error>?
    // Touched from the audio thread; set before the tap starts, cleared after it stops.
    nonisolated(unsafe) private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    private var preparedLocale: Locale?
    /// Buffers received this recording (audio thread). 0 after a while = the engine is on a dead device.
    nonisolated(unsafe) private var buffers = 0
    /// This recording's audio (analyzer format), kept until the next one starts: Gemini transcribes it (Lithuanian).
    nonisolated private let clipLock = NSLock()
    nonisolated(unsafe) private var clip: [AVAudioPCMBuffer] = []
    /// Live dictation: gets this recording's audio as 16 kHz 16-bit PCM, from the start of the clip on.
    nonisolated(unsafe) private var pcmSink: ((Data) -> Void)?
    nonisolated(unsafe) private var pcmConverter: AVAudioConverter?
    /// Bumps when the mic setup changes, so a prepare that started before is thrown away.
    private var generation = 0
    private var listening = false

    /// macOS swaps mics on its own (AirPods, displays, Continuity): rebuild the engine on the next press.
    func watchDevices() {
        guard !listening else { return }
        listening = true
        let changed: AudioObjectPropertyListenerBlock = { _, _ in Task { @MainActor [weak self] in self?.deviceChanged() } }
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, changed)
        }
    }

    private func deviceChanged() {
        // Only when the mic we'd pick is really a different one (device lists change often, e.g. our own engines).
        guard AudioInput.chosen?.id != engineDevice else { return }
        generation += 1
        guard armed == nil, analyzer == nil else { pendingChange = true; return }   // mid-recording: after it ends
        pendingChange = false
        engineDevice = nil   // fresh engine next time
        ready = nil
        warming = nil
        prewarm()
    }

    static func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Downloads the on-device model if needed. Call once at launch so the first press is instant.
    func prepare() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        preparedLocale = locale
        prewarm()
    }

    /// A transcriber + analyzer already prepared for the current mic's format, so pressing ⌥ only has to start the mic.
    private struct Ready { let transcriber: SpeechTranscriber; let analyzer: SpeechAnalyzer; let format: AVAudioFormat; let micFormat: AVAudioFormat; let device: AudioObjectID? }
    private var ready: Ready?
    private var warming: Task<Void, Never>?

    /// Prepares the next recording's analyzer (no mic access). Called at launch, on ⌥ down, and after each recording.
    func prewarm() {
        guard ready == nil || ready?.device != AudioInput.chosen?.id, warming == nil else { return }
        let gen = generation
        warming = Task { [weak self] in
            guard let self else { return }
            let r = try? await self.makeReady()
            guard gen == self.generation else { return }   // the mic changed meanwhile
            self.ready = r
            self.warming = nil
        }
    }

    private func makeReady() async throws -> Ready {
        let locale = preparedLocale ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let device = useChosenMic()
        let input = engine.inputNode
        // The device's real format (48 kHz on Studio Display); outputFormat can be stale after a switch → no audio.
        let hw = input.inputFormat(forBus: 0)
        let micFormat = hw.sampleRate > 0 ? hw : input.outputFormat(forBus: 0)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat) ?? micFormat
        try await analyzer.prepareToAnalyze(in: format)
        let context = AnalysisContext()
        context.contextualStrings[.general] = Vocabulary.speechHints
        try? await analyzer.setContext(context)
        return Ready(transcriber: transcriber, analyzer: analyzer, format: format, micFormat: micFormat, device: device)
    }

    /// Pick the mic each time (displays/AirPods come and go). A fresh engine per device switch:
    /// AVAudioEngine caches the old device's format otherwise.
    @discardableResult
    private func useChosenMic() -> AudioObjectID? {
        let mic = AudioInput.chosen
        micName = mic?.name
        if let mic, mic.id != engineDevice {
            // Never free an engine: its audio unit keeps getting device callbacks after a switch,
            // and a freed one crashes (EXC_BAD_ACCESS in IOUnitPropertyListener). A few stay around; they're small.
            retired.append(engine)
            if retired.count > 8 { retired.removeFirst() }
            engine = AVAudioEngine()
            if let unit = engine.inputNode.audioUnit {
                var id = mic.id
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
            }
            engine.reset()   // drop the old device's cached format
            engineDevice = mic.id
        }
        return mic?.id
    }

    /// The mic started on ⌥ down (before we know it's a hold): its analyzer and the stream collecting audio.
    private var armed: Task<(Ready, AsyncStream<AnalyzerInput>), Error>?

    /// ⌥ went down: start the mic now (the hold delay runs in parallel). Audio waits in the stream.
    func arm() {
        guard armed == nil else { return }
        resetClip()
        armed = Task { [weak self] in
            guard let self else { throw CancellationError() }
            if let warming = self.warming { await warming.value }
            var r = self.ready
            self.ready = nil
            if r == nil || r?.device != AudioInput.chosen?.id { r = try await self.makeReady() }
            guard let r else { throw CancellationError() }
            self.analyzerFormat = r.format
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.inputContinuation = continuation
            // All engine work off the main thread: with Bluetooth mics (AirPods switching to mic mode) touching the
            // input node can block for seconds, which froze the ⌥ hold timer → no notch.
            try await self.startEngine(prepared: r.micFormat, target: r.format)
            return (r, stream)
        }
    }

    /// Tap + start, off the main thread (with Bluetooth mics, touching the input node can block for seconds).
    private func startEngine(prepared: AVAudioFormat, target: AVAudioFormat) async throws {
        nonisolated(unsafe) let engine = self.engine
        nonisolated(unsafe) let recorder = self
        buffers = 0
        let want = AudioInput.chosen?.id
        try await Task.detached(priority: .userInitiated) {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            // AVAudioEngine falls back to the system default mic after audio changes (AirPods connecting become
            // the default): put it back on the one we chose, or the AirPods mic turns on and music drops to call mode.
            if let want, let unit = input.audioUnit {
                var cur = AudioObjectID(0); var n = UInt32(MemoryLayout<AudioObjectID>.size)
                AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &n)
                if cur != want {
                    var id = want
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, n)
                    print("mic: engine was on device \(cur), moved to \(want)")
                }
            }
            // Read the mic's format now: AirPods change sample rate when their mic turns on, and a stale
            // format here throws (crash). The converter maps whatever it is to the analyzer's format.
            let hw = input.inputFormat(forBus: 0)
            let format = hw.sampleRate > 0 ? hw : prepared
            recorder.converter = format == target ? nil : AVAudioConverter(from: format, to: target)
            Self.installTap(on: input, format: format, recorder: recorder)
            engine.prepare()
            try engine.start()
        }.value
    }

    /// No audio 0.8 s after the mic started: the engine is stuck on a device macOS switched away from.
    /// Rebuild it on the current mic; the analyzer keeps going (same stream).
    private func watchdog(_ analyzer: SpeechAnalyzer, target: AVAudioFormat) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.analyzer === analyzer, self.buffers == 0 else { return }
            print("mic: no audio from \(self.micName ?? "?"), restarting on the current mic")
            nonisolated(unsafe) let old = self.engine
            await Task.detached { old.inputNode.removeTap(onBus: 0); old.stop() }.value
            self.engineDevice = nil
            self.useChosenMic()
            try? await self.startEngine(prepared: target, target: target)
        }
    }

    /// ⌥ was part of a shortcut (or let go too soon): stop the mic, keep the prepared analyzer for next time.
    func disarm() {
        guard let armed else { return }
        self.armed = nil
        Task {
            guard let (r, _) = try? await armed.value else { return }
            guard self.armed == nil, self.analyzer == nil else { return }   // a new press took over
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.inputContinuation?.finish()
            self.inputContinuation = nil
            if self.ready == nil { self.ready = r }
        }
    }

    /// Mic first (levels move right away), then the analyzer; audio captured meanwhile waits in the stream.
    /// `onAudio` runs once the mic is live (the caller's slower work goes there, not before it).
    func start(onAudio: (() -> Void)? = nil) async throws {
        arm()
        guard let task = armed else { return }
        let (r, stream) = try await task.value
        armed = nil
        transcriber = r.transcriber
        analyzer = r.analyzer
        watchdog(r.analyzer, target: r.format)
        onAudio?()

        try await r.analyzer.start(inputSequence: stream)
        let transcriber = r.transcriber
        resultsTask = Task { [weak self] in
            var finalText = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalText += text
                    volatile = ""
                    let end = CMTimeGetSeconds(result.range.end)
                    await MainActor.run { self?.onSegment?(text, end.isFinite ? end : .infinity) }
                } else {
                    volatile = text
                }
                let combined = finalText + volatile
                let v = volatile
                await MainActor.run { self?.onPartial?(combined); self?.onVolatile?(v) }
            }
            return finalText + volatile
        }
    }

    /// Stops recording and returns the full transcript.
    func stop() async -> String {
        nonisolated(unsafe) let engine = self.engine
        await Task.detached { engine.inputNode.removeTap(onBus: 0); engine.stop() }.value
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = (try? await resultsTask?.value) ?? ""
        analyzer = nil
        transcriber = nil
        resultsTask = nil
        afterRecording()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        nonisolated(unsafe) let engine = self.engine
        await Task.detached { engine.inputNode.removeTap(onBus: 0); engine.stop() }.value
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        resultsTask = nil
        afterRecording()
    }

    /// The mic changed while recording: rebuild now; else just prepare the next one.
    private var pendingChange = false
    private func afterRecording() {
        if pendingChange { deviceChanged() } else { prewarm() }
    }

    // Audio thread. Built in a nonisolated context so the closure isn't main-actor bound.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, recorder: SpeechRecorder) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak recorder] buffer, _ in
            recorder?.handle(buffer)
        }
    }

    nonisolated private func handle(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        let level = Self.rms(buffer)
        if let out = convert(buffer) {
            inputContinuation?.yield(AnalyzerInput(buffer: out))
            clipLock.withLock {
                clip.append(out)
                if let pcmSink, let d = pcm16(out) { pcmSink(d) }
            }
        }
        Task { @MainActor [weak self] in self?.onLevel?(level) }
    }

    nonisolated private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format = analyzerFormat else { return Self.copy(buffer) }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(s.mDataByteSize)) }
        }
        return out
    }

    // MARK: Audio for Gemini

    var isArmed: Bool { armed != nil }
    /// A new recording starts: drop the last one's audio.
    func resetClip() { clipLock.withLock { clip = [] } }

    /// Sends this recording's audio so far, then every new buffer, to `sink` (nil stops). Same lock as the tap: nothing's lost or reordered.
    nonisolated func streamPCM(to sink: ((Data) -> Void)?, includeSoFar: Bool = true) {
        clipLock.withLock {
            pcmSink = sink
            guard let sink, includeSoFar else { return }
            for b in clip { if let d = pcm16(b) { sink(d) } }
        }
    }

    /// Analyzer-format buffer → 16 kHz mono Int16 bytes (converter kept across buffers, so resampling is seamless).
    nonisolated private func pcm16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else { return nil }
        if pcmConverter?.inputFormat != buffer.format { pcmConverter = AVAudioConverter(from: buffer.format, to: target) }
        guard let conv = pcmConverter,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64)
        else { return nil }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: p, count: Int(out.frameLength) * 2)
    }

    /// The recording (or the part between two times, in seconds) as 16 kHz mono 16-bit WAV.
    func wav(from start: Double = 0, to end: Double = .infinity) -> Data? {
        let bufs = clipLock.withLock { clip }
        guard let f = bufs.first?.format, f.sampleRate > 0 else { return nil }
        let a = AVAudioFramePosition(max(0, start) * f.sampleRate)
        let b = end.isFinite ? AVAudioFramePosition(end * f.sampleRate) : .max
        guard let joined = Self.join(bufs, from: a, to: b), joined.frameLength > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: f, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(joined.frameLength) * 16000 / f.sampleRate) + 1024)
        else { return nil }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return joined
        }
        guard error == nil, let samples = out.int16ChannelData?[0], out.frameLength > 0 else { return nil }
        let pcm = Data(bytes: samples, count: Int(out.frameLength) * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Frames [a, b) of consecutive buffers, as one buffer.
    nonisolated private static func join(_ bufs: [AVAudioPCMBuffer], from a: AVAudioFramePosition, to b: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard let f = bufs.first?.format else { return nil }
        let bpf = Int(f.streamDescription.pointee.mBytesPerFrame)
        let total = bufs.reduce(AVAudioFramePosition(0)) { $0 + AVAudioFramePosition($1.frameLength) }
        let cap = min(b, total) - a
        guard cap > 0, let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(cap)) else { return nil }
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        var pos: AVAudioFramePosition = 0
        var written = 0
        for buf in bufs {
            let n = AVAudioFramePosition(buf.frameLength)
            let s = max(a, pos), e = min(b, pos + n)
            if e > s {
                let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buf.audioBufferList))
                for (sb, db) in zip(src, dst) {
                    guard let sp = sb.mData, let dp = db.mData else { continue }
                    memcpy(dp + written * bpf, sp + Int(s - pos) * bpf, Int(e - s) * bpf)
                }
                written += Int(e - s)
            }
            pos += n
            if pos >= b { break }
        }
        out.frameLength = AVAudioFrameCount(written)
        for i in dst.indices { dst[i].mDataByteSize = UInt32(written * bpf) }
        return out
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        return min(1, rms * 12)   // scale speech to ~0...1
    }
}
