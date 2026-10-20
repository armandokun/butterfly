import AppKit

/// Short-term memory: what happened in the last couple of minutes.
/// Jev reads it (so "close it", "move it back", "the other one" make sense),
/// and clicks check the screen you were just working on first.
@MainActor
enum Memory {
    struct Entry {
        let at: Date
        let said: String
        let did: String
        let app: String?
        let display: CGDirectDisplayID?
    }

    static let window: TimeInterval = 120
    private static var entries: [Entry] = []

    static var recent: [Entry] {
        entries.removeAll { Date().timeIntervalSince($0.at) > window }
        return entries
    }

    static func record(said: String, did: String, app: String? = nil, display: CGDirectDisplayID? = nil) {
        entries.append(Entry(at: Date(), said: said, did: did, app: app, display: display ?? displayUnderMouse))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
    }

    /// For Jev's state: newest last, e.g. "12s ago: said “close this tab” → Dia: File → Close Tab".
    static var summary: String? {
        let list = recent
        guard !list.isEmpty else { return nil }
        return list.map { e in
            let ago = Int(Date().timeIntervalSince(e.at))
            return "\(ago)s ago: said “\(e.said)” → \(e.did)" + (e.app.map { " (in \($0))" } ?? "")
        }.joined(separator: "\n")
    }

    /// The display of your most recent action, if it was recent.
    static var lastDisplay: CGDirectDisplayID? { recent.last?.display }

    static var displayUnderMouse: CGDirectDisplayID? {
        let p = CGEvent(source: nil)?.location ?? .zero
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0 ? id : nil
    }

    static func display(at p: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0 ? id : nil
    }
}
