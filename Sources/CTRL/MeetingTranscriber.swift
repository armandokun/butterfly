import Foundation

/// Meeting audio → transcript with Gemini. Benchmarked on Lithuanian (FLEURS + a Lithuanian IT podcast):
/// gemini-3.8-flash had the fewest errors (7.5% WER) and keeps English tech terms (OpenAI, deploy'inti).
enum MeetingTranscriber {
    static let model = "gemini-3.8-flash"
    private static let base = "https://generativelanguage.googleapis.com"

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func transcribe(_ audio: URL, title: String?, attendees: [String], key: String) async throws -> String {
        let file = try await upload(audio, key: key)
        defer { Task { _ = try? await request("DELETE", "/v1beta/\(file.name)", key: key) } }
        let who = attendees.isEmpty ? "" : "\nParticipants (from the calendar): \(attendees.joined(separator: ", "))."
        let prompt = """
        This is a recording of a work meeting\(title.map { " titled “\($0)”" } ?? "").\(who)
        People speak mostly Lithuanian, often corporate/tech Lithuanian with English terms mixed in. Keep English terms \
        in their English spelling (OpenAI, Anthropic'as, deploy'inti, sprint'as). If someone speaks English, keep it English. Never translate.

        Transcribe the whole recording verbatim. Start a new line at every change of speaker:
        [mm:ss] Name: what they said
        Use a name only when the conversation makes it clear who is speaking (they're addressed or introduce themselves); \
        otherwise Speaker 1, Speaker 2… consistently. Output only the transcript. If nobody speaks at all, output exactly: \(noSpeech)
        """
        let body: [String: Any] = [
            "contents": [["parts": [["file_data": ["mime_type": "audio/mp4", "file_uri": file.uri]], ["text": prompt]]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 65536],
        ]
        // Empty answers happen (finishReason RECITATION/OTHER, thoughts-only…): retry, then try the fallback model.
        var reasons: [String] = []
        for m in [model, model, fallbackModel] {
            do {
                let d = try await request("POST", "/v1beta/models/\(m):generateContent", key: key, json: body, timeout: 1800)
                if ProcessInfo.processInfo.environment["BUTTERFLY_GEMINI_DEBUG"] != nil,
                   let raw = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted) {
                    FileHandle.standardError.write(raw + Data("\n".utf8))
                }
                let (text, why) = extract(d)
                if let text { return text }
                reasons.append("\(m): \(why)")
            } catch {
                reasons.append("\(m): \(error.localizedDescription)")
            }
        }
        throw Failure(message: "Gemini returned no transcript (\(reasons.joined(separator: "; ")))")
    }

    static let fallbackModel = "gemini-3.1-pro-preview"
    static let noSpeech = "(no speech in this recording)"

    /// The transcript text, or why there is none (finishReason, block reason…).
    private static func extract(_ d: [String: Any]) -> (String?, String) {
        let cand = (d["candidates"] as? [[String: Any]])?.first
        let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return (text, "") }
        if let block = (d["promptFeedback"] as? [String: Any])?["blockReason"] as? String { return (nil, "blocked: \(block)") }
        guard let cand else { return (nil, "no candidates") }
        let finish = cand["finishReason"] as? String ?? "no finishReason"
        let thoughts = parts.contains { $0["thought"] as? Bool == true }
        return (nil, finish + (parts.isEmpty ? ", no parts" : thoughts ? ", thoughts only" : ""))
    }

    /// Files API (resumable upload): meetings are far over the 20 MB inline limit.
    private static func upload(_ audio: URL, key: String) async throws -> (name: String, uri: String) {
        let data = try Data(contentsOf: audio)
        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files")!)
        start.httpMethod = "POST"
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/mp4", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": audio.deletingLastPathComponent().lastPathComponent]])
        let (_, r) = try await URLSession.shared.data(for: start)
        guard let http = r as? HTTPURLResponse, let up = http.value(forHTTPHeaderField: "X-Goog-Upload-URL").flatMap(URL.init) else {
            throw Failure(message: "Gemini upload refused (\((r as? HTTPURLResponse)?.statusCode ?? 0)). Check the API key.")
        }
        var put = URLRequest(url: up, timeoutInterval: 900)
        put.httpMethod = "POST"
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        let (body, _) = try await URLSession.shared.upload(for: put, from: data)
        guard let f = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["file"] as? [String: Any],
              let name = f["name"] as? String, let uri = f["uri"] as? String else { throw Failure(message: "Gemini upload failed") }
        // Audio is processed before it can be used.
        var state = f["state"] as? String
        for _ in 0..<120 where state == "PROCESSING" {
            try await Task.sleep(for: .seconds(2))
            state = try await request("GET", "/v1beta/\(name)", key: key)["state"] as? String
        }
        guard state == nil || state == "ACTIVE" else { throw Failure(message: "Gemini couldn't read the audio (\(state ?? "?"))") }
        return (name, uri)
    }

    @discardableResult
    private static func request(_ method: String, _ path: String, key: String, json: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let json { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            throw Failure(message: "Gemini: \(msg)")
        }
        return obj
    }
}
