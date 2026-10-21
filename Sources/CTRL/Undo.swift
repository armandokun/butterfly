import Foundation

/// "Undo that": reverses CTRL's own last action (volume, window move, Focus, timer…) when it can.
/// Anything CTRL can't reverse itself falls back to ⌘Z in the app in front.
@MainActor
enum Undo {
    struct Step { let at: Date; let what: String; let run: () async -> Void }

    private static var last: Step?

    static func register(_ what: String, _ run: @escaping () async -> Void) {
        last = Step(at: Date(), what: what, run: run)
    }

    /// Something CTRL did that isn't reversible: "undo" means the app's own undo now.
    static func clear() { last = nil }

    /// The step, if it's recent (2 minutes), removed so a second "undo" doesn't redo it.
    static func pop() -> Step? {
        defer { last = nil }
        guard let s = last, Date().timeIntervalSince(s.at) < 120 else { return nil }
        return s
    }
}
