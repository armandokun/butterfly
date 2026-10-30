import AppKit

/// Records how each voice command was decided: what was heard, the context, every model answer,
/// the rules that kicked in, the outcome and what the notch showed. Shown as a tree in Settings → Debug.
@MainActor
final class DecisionTrace: ObservableObject {
    static let shared = DecisionTrace()

    enum Kind: String { case heard, context, model, rule, outcome, result, error }

    struct Node: Identifiable {
        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String? = nil
        var ms: Int? = nil
        var p: Double? = nil            // probability / confidence, drawn as a bar
        var children: [Node] = []
    }

    struct Run: Identifiable {
        let id = UUID()
        let at = Date()
        let said: String
        var nodes: [Node] = []
        var ms: Int = 0
        var failed = false
        var outcome: String { nodes.last { $0.kind == .outcome }?.title ?? (failed ? "error" : "—") }
    }

    @Published private(set) var runs: [Run] = []
    private var current: Run?
    private var started = Date()

    /// The run being recorded; async work (click checks) captures it so late nodes land on the right run.
    var currentID: UUID? { current?.id }

    func begin(_ said: String) {
        current = Run(said: said)
        started = Date()
        DebugRecorder.shared.begin(current!.id, said: said)
    }

    func add(_ node: Node, run id: UUID? = nil) {
        guard let id = id ?? currentID else { return }
        if current?.id == id { current?.nodes.append(node) }
        else if let i = runs.firstIndex(where: { $0.id == id }) { runs[i].nodes.append(node) }
        DebugRecorder.shared.node(node, run: id)
    }

    func add(_ kind: Kind, _ title: String, _ detail: String? = nil, ms: Int? = nil, run id: UUID? = nil) {
        add(Node(kind: kind, title: title, detail: detail, ms: ms), run: id)
    }

    func end() {
        guard var r = current else { return }
        r.ms = Int(Date().timeIntervalSince(started) * 1000)
        r.failed = r.nodes.contains { $0.kind == .error }
        DebugRecorder.shared.finish(r)
        runs.insert(r, at: 0)
        if ProcessInfo.processInfo.environment["CTRL_TIMING"] == "1" { print(Self.text(r)); fflush(stdout) }
        if runs.count > 50 { runs.removeLast(runs.count - 50) }
        current = nil
    }

    func clear() { runs = [] }

    /// Plain-text tree, for pasting into a chat or bug report.
    static func text(_ r: Run) -> String {
        var out = "“\(r.said)” · \(r.ms) ms · \(r.at.formatted(date: .omitted, time: .standard))\n"
        func walk(_ n: Node, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            var line = "\(pad)\(depth == 0 ? "■" : "└") [\(n.kind.rawValue)] \(n.title)"
            if let p = n.p { line += String(format: " (%.2f)", p) }
            if let d = n.detail { line += " — \(d)" }
            if let ms = n.ms { line += " · \(ms) ms" }
            out += line + "\n"
            n.children.forEach { walk($0, depth + 1) }
        }
        r.nodes.forEach { walk($0, 0) }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
