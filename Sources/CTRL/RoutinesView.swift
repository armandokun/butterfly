import AppKit
import SwiftUI

/// Menu bar → Routines…: create and edit routines.
struct RoutinesView: View {
    @ObservedObject var store: RoutineStore
    var run: (Routine) -> Void
    @State private var selection: Routine.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.routines) { r in
                    Text(r.name.isEmpty ? "Untitled" : r.name)
                        .foregroundStyle(r.name.isEmpty ? .secondary : .primary)
                        .tag(r.id)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                        .help("New routine")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                        .disabled(selection == nil)
                        .help("Delete routine")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if let i = store.routines.firstIndex(where: { $0.id == selection }) {
                RoutineEditor(routine: $store.routines[i], run: run)
                    .id(store.routines[i].id)
            } else {
                ContentUnavailableView {
                    Label(store.routines.isEmpty ? "No Routines" : "No Selection", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("A routine runs several commands from one phrase, like “work mode”.")
                } actions: {
                    Button("New Routine") { add() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear { if selection == nil { selection = store.routines.first?.id } }
    }

    private func add() {
        let r = Routine()
        store.routines.append(r)
        selection = r.id
    }

    private func remove() {
        guard let i = store.routines.firstIndex(where: { $0.id == selection }) else { return }
        store.routines.remove(at: i)
        selection = store.routines.indices.contains(i) ? store.routines[i].id : store.routines.last?.id
    }
}

private struct RoutineEditor: View {
    @Binding var routine: Routine
    var run: (Routine) -> Void
    @FocusState private var focusedStep: Routine.Step.ID?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $routine.name, prompt: Text("Work mode"))
                TextField("Say it like", text: $routine.phrases, prompt: Text("work mode, let's get to work"), axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                Text("Phrases you'd say to start it, separated by commas.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($routine.steps) { $step in
                    HStack {
                        Text("\((routine.steps.firstIndex(of: step) ?? 0) + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        TextField("Step", text: $step.text, prompt: Text("open cursor and slack side by side"))
                            .labelsHidden()
                            .focused($focusedStep, equals: step.id)
                            .onSubmit { addStep(after: step.id) }
                        Button {
                            routine.steps.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(routine.steps.count == 1)
                        .help("Remove step")
                    }
                }
                .onMove { routine.steps.move(fromOffsets: $0, toOffset: $1) }

                Button("Add Step", systemImage: "plus") { addStep(after: routine.steps.last?.id) }
                    .buttonStyle(.borderless)
            } header: {
                Text("Steps")
            } footer: {
                Text("Each step is anything you'd say to CTRL: “open slack”, “play some music”, “switch to dark mode”.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button("Run Now", systemImage: "play.fill") { run(routine) }
                .disabled(!routine.isRunnable)
                .help(routine.isRunnable ? "Run this routine" : "Add a name and at least one step")
        }
    }

    private func addStep(after id: Routine.Step.ID?) {
        let new = Routine.Step("")
        let i = routine.steps.firstIndex { $0.id == id }.map { $0 + 1 } ?? routine.steps.count
        routine.steps.insert(new, at: i)
        focusedStep = new.id
    }
}

@MainActor
final class RoutinesWindow {
    private var window: NSWindow?

    func show(run: @escaping (Routine) -> Void) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: RoutinesView(store: .shared, run: run)))
            w.title = "Routines"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.setContentSize(.init(width: 680, height: 440))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
