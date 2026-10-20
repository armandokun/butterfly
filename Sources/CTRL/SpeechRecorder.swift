@preconcurrency import AVFoundation
import Speech

/// Push-to-talk recorder: on-device SpeechAnalyzer + live audio level.
@MainActor
final class SpeechRecorder {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<String, Error>?
    // Touched from the audio thread; set before the tap starts, cleared after it stops.
    nonisolated(unsafe) private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    private var preparedLocale: Locale?

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
    }

    func start() async throws {
        let locale = preparedLocale ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat) ?? micFormat
        analyzerFormat = format
        converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            var finalText = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalText += text
                    volatile = ""
                } else {
                    volatile = text
                }
                let combined = finalText + volatile
                await MainActor.run { self?.onPartial?(combined) }
            }
            return finalText + volatile
        }

        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: micFormat, recorder: self)
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns the full transcript.
    func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = (try? await resultsTask?.value) ?? ""
        analyzer = nil
        transcriber = nil
        resultsTask = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        resultsTask = nil
    }

    // Audio thread. Built in a nonisolated context so the closure isn't main-actor bound.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, recorder: SpeechRecorder) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak recorder] buffer, _ in
            recorder?.handle(buffer)
        }
    }

    nonisolated private func handle(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        if let out = convert(buffer) {
            inputContinuation?.yield(AnalyzerInput(buffer: out))
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
