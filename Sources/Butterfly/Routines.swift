import AppKit

/// Routines: one phrase → several normal Butterfly commands, run in order.
/// Created in the app (menu bar → Routines…). Saved to ~/Library/Application Support/Butterfly/routines.json.
///
/// Each step is a sentence Butterfly already understands, so routines reuse every skill
/// (apps, sites, layout, music, settings, menus) with no extra code per step.
struct Routine: Codable, Identifiable, Equatable {
    struct Step: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        init(_ text: String) { self.text = text }
        init(from decoder: Decoder) throws { text = try decoder.singleValueContainer().decode(String.self) }
        func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
    }

    var id = UUID()
    var name: String
    var phrases: String          // how you'd say it, e.g. "work mode, let's get to work"
    var steps: [Step]

    enum CodingKeys: String, CodingKey { case name, phrases, steps }
    init(name: String = "", phrases: String = "", steps: [Step] = [Step("")]) {
        self.name = name; self.phrases = phrases; self.steps = steps
    }

    var runnableSteps: [String] {
        steps.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var isRunnable: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !runnableSteps.isEmpty }
}

@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    static let fileURL = Vocabulary.fileURL.deletingLastPathComponent().appendingPathComponent("routines.json")

    @Published var routines: [Routine] = [] {
        didSet { if routines != oldValue { save() } }
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = list
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(routines).write(to: Self.fileURL, options: .atomic)
    }

    func routine(named name: String) -> Routine? { routines.first { $0.isRunnable && $0.name == name } }

    /// Jev question listing your routines; nil when you have none.
    var question: TypeSafeClient.Question? {
        let list = routines.filter(\.isRunnable)
        guard !list.isEmpty else { return nil }
        var opts = ["none": "not one of the user's routines"]
        for r in list {
            let said = r.phrases.trimmingCharacters(in: .whitespaces)
            opts[r.name] = "the routine called \"\(r.name)\"" + (said.isEmpty ? "" : ", triggered by phrases like: \(said)")
        }
        return .choice("Is the user asking to run one of their saved routines? Which one?", options: opts)
    }
}
