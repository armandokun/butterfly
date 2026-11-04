import Foundation

/// Meeting audio → transcript with Gemini. Benchmarked on Lithuanian (FLEURS + a Lithuanian IT podcast):
/// gemini-3.8-flash had the fewest errors (7.5% WER) and keeps English tech terms (OpenAI, deploy'inti).
enum MeetingTranscriber {
    static let model = "gemini-3.8-flash"
    private static let base = "https://generativelanguage.googleapis.com"

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Audio sent to Gemini: the mix, or (better) the user's mic and everyone else as two files on one timeline.
    struct Audio {
        var mixed: URL
        var sides: (me: URL, them: URL)? = nil
    }

    /// Pass 1: audio → verbatim transcript. Pass 2: transcript → summary and decisions. Returns Markdown with
    /// "## Summary", "## Decisions & next steps" and "## Transcript" (or just the transcript if the notes fail).
    static func transcribe(_ audio: Audio, title: String?, attendees: [String], me: String, key: String) async throws -> String {
        let transcript = try await transcript(audio, title: title, attendees: attendees, me: me, key: key)
        guard transcript != noSpeech, transcript.count > 600 else { return transcript }
        let notes = (try? await notes(for: transcript, key: key)).map { $0 + "\n\n" } ?? ""
        return notes + "## Transcript\n\n" + transcript
    }

    private static func transcript(_ audio: Audio, title: String?, attendees: [String], me: String, key: String) async throws -> String {
        var files: [(name: String, uri: String)] = []
        defer { for f in files { Task { _ = try? await request("DELETE", "/v1beta/\(f.name)", key: key) } } }
        let twoTracks = audio.sides != nil
        if let s = audio.sides {
            files.append(try await upload(s.me, key: key))
            files.append(try await upload(s.them, key: key))
        } else {
            files.append(try await upload(audio.mixed, key: key))
        }
        let who = attendees.isEmpty ? "" : "\nParticipants (from the calendar): \(attendees.joined(separator: ", ")). Use these exact spellings."
        let intro = twoTracks
            ? "Two synchronized audio tracks of one work meeting\(title.map { " titled “\($0)”" } ?? ""), same timeline. Track 1 is \(me) alone (their microphone). Track 2 is everyone else."
            : "This is a recording of a work meeting\(title.map { " titled “\($0)”" } ?? "")."
        let prompt = """
        \(intro)\(who)
        People speak mostly Lithuanian, often corporate/tech Lithuanian with English terms mixed in. Keep English terms \
        in their English spelling (OpenAI, Anthropic'as, deploy'inti, sprint'as). If someone speaks English, keep it English. Never translate, never summarize.

        Transcribe everything word for word (minus fillers, see below), in time order, one line per turn:
        [mm:ss] Name: what they said

        Rules:
        - \(twoTracks ? "Everything on track 1 is \(me). Name the others" : "Use a name only") when the conversation makes it clear who is speaking \
        (they're addressed or introduce themselves); otherwise Speaker 1, Speaker 2… kept consistent.
        - A line never covers more than about 20 seconds of speech. When one person keeps talking, start a new [mm:ss] line \
        every 2–3 sentences. A 36-minute meeting has roughly 250–350 lines, not 100.
        - The listener's reactions ("Mhm", "Yeah", "Aha", "Aišku", "Okay") are turns: each gets its own [mm:ss] line at the moment it \
        happened, between the speaker's lines — never dropped, never gathered after the block.
        - When people talk over each other, write both lines, ordered by when each started.
        - Keep asides and false starts ("I'll pause my video for a second").
        - Drop only fillers and stutters inside a sentence: "uh", "um", "uhm", "like" as a filler, "you know", "nu", "ee", \
        doubled words ("I'm I'm" → "I'm"). Everything else stays word for word.
        - Unclear word → [?]. Never guess a word that would change the meaning.
        This is a transcript, not meeting notes: no headings, no bullet points, no summary — every line starts with [mm:ss]. \
        Output only the transcript. If nobody speaks at all, output exactly: \(noSpeech)
        """
        var parts: [[String: Any]] = files.map { ["file_data": ["mime_type": "audio/mp4", "file_uri": $0.uri]] }
        parts.append(["text": prompt])
        let body: [String: Any] = [
            "contents": [["parts": parts]],
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
                if let text, isTranscript(text) { return text }
                reasons.append("\(m): \(text == nil ? why : "wrote notes instead of a transcript")")
            } catch {
                reasons.append("\(m): \(error.localizedDescription)")
            }
        }
        throw Failure(message: "Gemini returned no transcript (\(reasons.joined(separator: "; ")))")
    }

    /// Mostly "[mm:ss] Name: …" lines (the model sometimes drifts into writing notes).
    private static func isTranscript(_ t: String) -> Bool {
        if t == noSpeech { return true }
        let lines = t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return false }
        let stamped = lines.filter { $0.firstMatch(of: #/^\[\d{1,2}:\d\d(:\d\d)?\]/#) != nil }.count
        return Double(stamped) / Double(lines.count) >= 0.6
    }

    static let fallbackModel = "gemini-3.1-pro-preview"
    static let noSpeech = "(no speech in this recording)"

    /// Pass 2: summary and explicit decisions, from the transcript text only (nothing inferred).
    private static func notes(for transcript: String, key: String) async throws -> String {
        let prompt = """
        Below is a verbatim transcript of a work meeting. Write, in the language the participants mostly used:

        ## Summary
        4–6 sentences: what was discussed and where it landed. Only what was actually said.

        ## Decisions & next steps
        - [mm:ss] what — who
        Only explicit agreements or commitments someone made. Someone describing how their company does things is not a \
        decision. If none were made, write: None stated.

        Attribute each point to the person who said it. Do not infer locations, roles or facts that are not in the transcript. \
        Use the transcript's timestamps. Output only these two sections.

        \(transcript)
        """
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.1, "maxOutputTokens": 8192],
        ]
        let d = try await request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 300)
        guard let t = extract(d).0, t.contains("## Summary") else { throw Failure(message: "no notes") }
        return t
    }

    /// A short calendar-style title for a transcript ("Admin dashboard data model", "Sprint'o planavimas"), in the meeting's language.
    static func title(for transcript: String, key: String) async throws -> String {
        let prompt = """
        Below is a transcript of a work meeting. Give it a short title (2–6 words) like a calendar event name: the main topic \
        or decision, in the language the participants mostly speak (keep product/tech names as they are). No quotes, no date, \
        no words like "meeting"/"susitikimas"/"call". Output only the title.

        \(transcript.prefix(14000))
        """
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 1024, "thinkingConfig": ["thinkingBudget": 0]],   // thoughts would eat a small budget
        ]
        let d = try await request("POST", "/v1beta/models/\(model):generateContent", key: key, json: body, timeout: 60)
        guard let t = extract(d).0?.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'.#*-")), !t.isEmpty else { throw Failure(message: "no title") }
        return String(t.prefix(60))
    }

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
    static func request(_ method: String, _ path: String, key: String, json: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> [String: Any] {
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
