import AppKit

/// Routines: one phrase → several normal CTRL commands, run in order.
/// File: ~/Library/Application Support/CTRL/routines.json
///
/// Each step is just a sentence CTRL already understands, so routines reuse every skill
/// (apps, sites, layout, music, settings, menus) with no extra code per step.
@MainActor
enum Routines {
    struct Routine: Codable {
        let name: String
        let description: String   // what Jev reads to match your phrase
        let steps: [String]
    }

    static let fileURL: URL = Vocabulary.fileURL.deletingLastPathComponent().appendingPathComponent("routines.json")

    private static let starter: [Routine] = [
        Routine(name: "Work mode", description: "start working, work mode, focus on work, let's get to work",
                steps: ["open cursor and slack side by side", "play some music"]),
        Routine(name: "Email time", description: "check email, inbox time, email mode",
                steps: ["open openmail dot sh and console dot openmail dot sh side by side"]),
        Routine(name: "Wind down", description: "done for the day, wind down, end of day, stop working",
                steps: ["pause the music", "switch to dark mode"]),
    ]

    static var all: [Routine] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? enc.encode(starter).write(to: fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Routine].self, from: data) else { return [] }
        return list
    }

    static func routine(named name: String) -> Routine? { all.first { $0.name == name } }

    static var question: TypeSafeClient.Question? {
        let list = all
        guard !list.isEmpty else { return nil }
        var opts = ["none": "not one of the user's routines"]
        for r in list { opts[r.name] = "the routine called \"\(r.name)\": \(r.description)" }
        return .choice("Is the user asking to run one of their saved routines? Which one?", options: opts)
    }

    static func open() {
        _ = all
        NSWorkspace.shared.open(fileURL)
    }
}
