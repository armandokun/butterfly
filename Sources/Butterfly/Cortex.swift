import AppKit
import Foundation

/// Sends meeting transcripts to Cortex (Armandas's shared company memory), which pulls out facts and connections.
/// Connected from Cortex → Connectors → Butterfly, which opens `butterfly://cortex?url=…&key=…`.
@MainActor
enum Cortex {
    static var endpoint: URL? { Keychain.cortexURL.flatMap(URL.init(string:)) }
    static var connected: Bool { endpoint != nil && Keychain.cortexKey != nil }

    /// Meetings already sent, by their timestamp ("2026-10-29 13.00"), which survives folder renames.
    private static let sentKey = "cortexSent"
    private static var sent: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: sentKey) }
    }

    /// `butterfly://cortex?url=…&key=…`: save the connection, then send every past meeting.
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "butterfly", url.host == "cortex",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let endpoint = items.first(where: { $0.name == "url" })?.value, endpoint.hasPrefix("https://") || endpoint.hasPrefix("http://localhost"),
              let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty else { return false }
        Keychain.saveCortex(url: endpoint, key: key)
        sent = []   // a new key may be a new workspace: send everything again (Cortex skips what it already has)
        sendAll()
        return true
    }

    /// Sends every finished transcript not sent yet, oldest first. Safe to call often.
    static func sendAll(again: Bool = false) {
        if again { sent = [] }
        guard connected, let dirs = try? FileManager.default.contentsOfDirectory(at: Meetings.root, includingPropertiesForKeys: nil) else { return }
        Task {
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { await send(d) }
        }
    }

    /// Sends one meeting folder's transcript. Skips placeholders (no key, failed) and silence.
    @discardableResult
    static func send(_ folder: URL) async -> Bool {
        guard let endpoint, let key = Keychain.cortexKey else { return false }
        let id = String(folder.lastPathComponent.prefix(16))
        guard !sent.contains(id),
              let md = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8),
              !md.contains("_Transcription failed"), !md.contains("_No Gemini API key"), !md.contains(MeetingTranscriber.noSpeech),
              md.count > 300 else { return false }
        let title = String(folder.lastPathComponent.dropFirst(17))
        var r = URLRequest(url: endpoint, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "title": title, "text": md])
        guard let (_, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode, code < 300 else { return false }
        sent.insert(id)
        return true
    }
}
