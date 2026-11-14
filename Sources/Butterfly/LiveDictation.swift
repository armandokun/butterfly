import Foundation

/// Right-⌥ dictation streamed to Gemini while you talk (gemini-3.5-transcribe-live over the Live API WebSocket),
/// so the text is ready ~0.4 s after you let go. Lithuanian and English, mixed is fine.
/// Push-to-talk (`manual`): the press is one turn, ended on release. Locked mode: Gemini splits at pauses and each
/// finished utterance comes back as a final, typed one by one.
final class LiveDictation: @unchecked Sendable {
    static let model = "gemini-3.5-transcribe-live"

    /// The current guess for the words being spoken (main thread).
    var onInterim: (@MainActor (String) -> Void)?
    /// A finished utterance (main thread). Locked mode types each one.
    var onFinal: (@MainActor (String) -> Void)?

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var ended = false        // finish() called
    private var turnDone = false
    private var failed = false
    private let manual: Bool
    private var endedAt: Date?
    private var finalAfterEnd = false
    private var lastMsg = Date.distantPast   // last transcription message from the server
    private var interimOpen = false          // words heard that have no final text yet
    private var pending: [Data] = [] // audio from before setupComplete
    private var chunk = Data()       // audio collected into ~100 ms messages
    private var finals: [String] = []
    private let opened = Date()

    var hasFailed: Bool { lock.withLock { failed } }

    init(key: String, vocabulary: [String], manual: Bool) {
        self.manual = manual
        var c = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        c.queryItems = [.init(name: "key", value: key)]
        let t = URLSession.shared.webSocketTask(with: c.url!)
        t.maximumMessageSize = 16 << 20
        task = t
        t.resume()
        var transcription: [String: Any] = ["languageCodes": ["lt-LT", "en-US"]]
        let vocab = vocabulary.filter { !$0.isEmpty }.prefix(100)
        if !vocab.isEmpty { transcription["customVocabulary"] = Array(vocab) }
        var setup: [String: Any] = [
            "model": "models/\(Self.model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
        ]
        if manual { setup["realtimeInputConfig"] = ["automaticActivityDetection": ["disabled": true]] }
        send(["setup": setup])
        receive()
    }

    /// 16 kHz mono 16-bit PCM from the mic (audio thread).
    func feed(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, !failed else { return }
        chunk.append(pcm)
        guard chunk.count >= 3200 else { return }   // 100 ms
        let out = chunk
        chunk = Data()
        if ready { sendAudio(out) } else { pending.append(out) }   // sent in order: under the lock
    }

    /// Ends the turn and waits for the last words. nil = it failed (caller falls back).
    func finish(timeout: Double = 3) async -> String? {
        let (isReady, rest) = lock.withLock { () -> (Bool, Data) in
            ended = true
            endedAt = Date()
            let r = chunk
            chunk = Data()
            return (ready, r)
        }
        lock.withLock {
            if ready { if !rest.isEmpty { sendAudio(rest) }; sendEnd() }
            else if !rest.isEmpty { pending.append(rest) }   // sent once setup completes, then the end
        }
        let deadline = Date().addingTimeInterval(timeout + (isReady ? 0 : 2))
        // Auto (locked) mode never sends a turn end: done once every utterance heard has its final text.
        while Date() < deadline, !lock.withLock({ turnDone || failed || (!manual && ready && !interimOpen && Date().timeIntervalSince(max(lastMsg, endedAt ?? .distantPast)) > 0.4) }) {
            try? await Task.sleep(for: .milliseconds(15))
        }
        let (text, done, bad) = lock.withLock { (Self.join(finals), turnDone, failed) }   // before close: closing fails the receive
        close()
        Self.log(String(format: "live: %.2fs after release, %d words%@", Date().timeIntervalSince(endedAt ?? Date()),
                        text.split(separator: " ").count, text.isEmpty && (bad || !done) ? ", no answer (falling back)" : ""))
        if text.isEmpty && (bad || !done) { return nil }   // nothing back: caller falls back
        return text
    }

    func cancel() {
        lock.withLock { ended = true; failed = true }
        close()
    }

    // MARK: WebSocket

    private func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { [weak self] error in if error != nil { self?.fail("send failed") } }
    }

    private func sendAudio(_ pcm: Data) {
        send(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    private func sendEnd() {
        send(["realtimeInput": manual ? ["activityEnd": [String: Any]()] : ["audioStreamEnd": true]])
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure: self.fail("connection closed")
            case .success(let msg):
                let data: Data? = switch msg {
                case .string(let s): Data(s.utf8)
                case .data(let d): d
                @unknown default: nil
                }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(obj) }
                self.receive()
            }
        }
    }

    private func handle(_ m: [String: Any]) {
        if m["setupComplete"] != nil {
            // Under the lock, so the mic thread can't slip new audio in before activityStart and the backlog.
            let n = lock.withLock { () -> Int in
                if manual { send(["realtimeInput": ["activityStart": [String: Any]()]]) }
                for p in pending { sendAudio(p) }
                let n = pending.count
                pending = []
                ready = true
                if ended { sendEnd() }
                return n
            }
            Self.log(String(format: "live: connected in %.2fs (%d ms of audio waiting)", Date().timeIntervalSince(opened), n * 100))
            return
        }
        if let e = m["error"] { fail("\(e)"); return }
        guard let sc = m["serverContent"] as? [String: Any] else { return }
        lock.withLock { lastMsg = Date() }
        if let t = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String, !t.isEmpty {
            lock.withLock { interimOpen = true }
            Task { @MainActor in self.onInterim?(t) }
        }
        if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String,
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lock.withLock { finals.append(t); interimOpen = false; if ended { finalAfterEnd = true } }
            Task { @MainActor in self.onFinal?(t) }
        }
        if sc["turnComplete"] as? Bool == true || sc["generationComplete"] as? Bool == true {
            // Manual: the one turn is over. Auto: an earlier utterance's turn can end after release, so wait for the
            // last one (a final after release, or a quiet moment).
            lock.withLock {
                guard ended else { return }
                if manual || finalAfterEnd || Date().timeIntervalSince(endedAt ?? .distantPast) > 0.8 { turnDone = true }
            }
        }
    }

    private func fail(_ why: String) {
        let first = lock.withLock { () -> Bool in
            defer { failed = true }
            return !failed && !ended   // after finish, closing the socket "fails" the receive: not news
        }
        if first { Self.log("live failed: \(why)") }
    }

    /// ~/Library/Logs/Butterfly/dictation.log
    private static let logLock = NSLock()
    static func log(_ s: String) {
        logLock.lock(); defer { logLock.unlock() }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly/dictation.log")
        let line = Data("\(Date().formatted(.iso8601)) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) }
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
