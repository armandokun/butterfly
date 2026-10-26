import AppKit
import SwiftUI

/// Decision Tree window: the last voice commands as decision trees (newest first).
/// Heard → context → model answers (with probabilities) → rules → outcome → what the notch showed.
struct DebugPane: View {
    @ObservedObject var trace = DecisionTrace.shared
    /// Jump to each new command as it lands (picking an older one sticks until the next command).
    var follow = true
    @State private var selected: UUID?

    private var run: DecisionTrace.Run? { trace.runs.first { $0.id == selected } ?? trace.runs.first }

    var body: some View {
        HStack(spacing: 0) {
            // Runs
            VStack(spacing: 0) {
                HStack {
                    Text("LAST COMMANDS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(Pond.ink.opacity(0.6))
                    Spacer()
                    if !trace.runs.isEmpty {
                        Button("Clear") { trace.clear(); selected = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pond.ink.opacity(0.6))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(trace.runs) { r in
                            let on = r.id == run?.id
                            Button { selected = r.id } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.said).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Circle().fill(r.failed ? Pond.peach : Pond.lime).frame(width: 6, height: 6)
                                        Text("\(r.ms) ms · \(r.at.formatted(date: .omitted, time: .shortened))")
                                    }
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pond.ink.opacity(0.55))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(on ? Pond.lime.opacity(0.7) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                if trace.runs.isEmpty {
                    Text("Hold ⌥ and say something.\nEach command shows up here.")
                        .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(Pond.ink.opacity(0.5))
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 20)
                }
            }
            .frame(width: 190)
            Rectangle().fill(Pond.ink.opacity(0.12)).frame(width: 1)

            // Tree
            if let run {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(run.said)”").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text("\(run.ms) ms total · \(run.at.formatted(date: .abbreviated, time: .standard))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pond.ink.opacity(0.55))
                        }
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DecisionTrace.text(run), forType: .string)
                        }
                        .buttonStyle(.pond(Pond.lavender))
                    }
                    .padding(14)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(run.nodes.enumerated()), id: \.element.id) { i, n in
                                TraceNode(node: n, depth: 0, last: i == run.nodes.count - 1)
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
                .id(run.id)
            } else {
                Spacer()
            }
        }
        .foregroundStyle(Pond.ink)
        .onChange(of: trace.runs.first?.id) { if follow { selected = nil } }
    }
}

private struct TraceNode: View {
    let node: DecisionTrace.Node
    let depth: Int
    let last: Bool
    @State private var open: Bool

    init(node: DecisionTrace.Node, depth: Int, last: Bool) {
        self.node = node; self.depth = depth; self.last = last
        // Top-level steps open; the model's per-answer runners-up start folded.
        _open = State(initialValue: depth == 0)
    }

    private var tint: Color {
        switch node.kind {
        case .heard: Pond.lime
        case .context: Pond.ink.opacity(0.15)
        case .model: Pond.lavender
        case .rule: Color(red: 1, green: 0.85, blue: 0.4)
        case .outcome: Pond.lime
        case .result: Color(red: 0.6, green: 0.85, blue: 1)
        case .error: Pond.peach
        }
    }
    private var label: String {
        switch node.kind {
        case .heard: "HEARD"
        case .context: "CONTEXT"
        case .model: depth == 0 ? "MODEL" : "ANSWER"
        case .rule: "RULE"
        case .outcome: "DECIDED"
        case .result: "SHOWED"
        case .error: "ERROR"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Connector: a vertical spine linking steps, so it reads as a path.
                if depth == 0 {
                    VStack(spacing: 0) {
                        Circle().fill(tint).overlay(Circle().stroke(Pond.ink.opacity(0.4), lineWidth: 1)).frame(width: 10, height: 10).padding(.top, 5)
                        if !last { Rectangle().fill(Pond.ink.opacity(0.2)).frame(width: 1).frame(maxHeight: .infinity) }
                    }
                    .frame(width: 10)
                } else {
                    Rectangle().fill(Pond.ink.opacity(0.15)).frame(width: 1).padding(.leading, CGFloat(depth - 1) * 14 + 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !node.children.isEmpty {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Pond.ink.opacity(0.5))
                        }
                        if depth == 0 || node.kind != .model {
                            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.5)
                                .padding(.horizontal, 5).padding(.vertical, 2).background(tint)
                        }
                        Text(node.title).font(.system(size: depth == 0 ? 12.5 : 11.5, weight: depth == 0 ? .semibold : .regular, design: depth == 0 ? .default : .monospaced))
                            .textSelection(.enabled).lineLimit(3)
                        Spacer(minLength: 4)
                        if let p = node.p { Confidence(p: p) }
                        if let ms = node.ms { Text("\(ms) ms").font(.system(size: 10, design: .monospaced)).foregroundStyle(Pond.ink.opacity(0.5)) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if !node.children.isEmpty { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } }
                    if let d = node.detail {
                        Text(d).font(.system(size: 11)).foregroundStyle(Pond.ink.opacity(0.6)).textSelection(.enabled)
                    }
                    if open {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(node.children.enumerated()), id: \.element.id) { i, c in
                                TraceNode(node: c, depth: depth + 1, last: i == node.children.count - 1)
                            }
                        }
                    }
                }
                .padding(.bottom, depth == 0 ? 12 : 3)
            }
        }
    }
}

/// Probability bar: green when sure, yellow in between, peach when the model is guessing.
private struct Confidence: View {
    let p: Double
    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Pond.ink.opacity(0.1))
                Rectangle().fill(p >= 0.75 ? Pond.lime : p >= 0.5 ? Color(red: 1, green: 0.85, blue: 0.4) : Pond.peach).frame(width: 46 * max(0.02, min(1, p)))
            }
            .frame(width: 46, height: 6)
            Text(String(format: "%.2f", p)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pond.ink.opacity(0.6))
        }
    }
}
