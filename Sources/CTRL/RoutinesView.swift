import AppKit
import SwiftUI

struct RoutineEditor: View {
    @Binding var routine: Routine
    var run: (Routine) -> Void
    @FocusState private var focusedStep: Routine.Step.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(routine.name.isEmpty ? "Untitled" : routine.name)
                        .font(Pond.display(28))
                        .foregroundStyle(Pond.ink)
                        .padding(.horizontal, 8)
                        .background(Pond.lavender)
                    Spacer()
                    Button("▶ Run now") { run(routine) }
                        .buttonStyle(.pond(Pond.peach))
                        .disabled(!routine.isRunnable)
                        .help(routine.isRunnable ? "Run this routine" : "Add a name and at least one step")
                }

                PondSection(title: "Trigger", tint: Pond.lime, footer: "Phrases you'd say to start it, separated by commas.") {
                    PondRow(title: "Name") { PondField(prompt: "Work mode", text: $routine.name).frame(width: 220) }
                    PondRow(title: "Say it like", last: true) {
                        PondField(prompt: "work mode, let's get to work", text: $routine.phrases).frame(width: 220)
                    }
                }

                PondSection(title: "Steps", tint: Pond.teal,
                            footer: "Each step is anything you'd say to CTRL: “open slack”, “play some music”, “switch to dark mode”.") {
                    ForEach(Array(routine.steps.enumerated()), id: \.element.id) { i, step in
                        let binding = Binding(get: { routine.steps.first { $0.id == step.id }?.text ?? "" },
                                              set: { t in if let j = routine.steps.firstIndex(where: { $0.id == step.id }) { routine.steps[j].text = t } })
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(Pond.label).foregroundStyle(Pond.ink)
                                    .frame(width: 20, height: 20).background(Pond.lime)
                                TextField("", text: binding, prompt: Text("open cursor and slack side by side"))
                                    .textFieldStyle(.plain).font(Pond.body).foregroundStyle(Pond.ink)
                                    .focused($focusedStep, equals: step.id)
                                    .onSubmit { addStep(after: step.id) }
                                Button("−") { routine.steps.removeAll { $0.id == step.id } }
                                    .buttonStyle(.pond(Pond.rose))
                                    .disabled(routine.steps.count == 1)
                                    .help("Remove step")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            Rectangle().fill(Pond.ink.opacity(0.08)).frame(height: 1)
                        }
                    }
                    HStack {
                        Button("+ Add step") { addStep(after: routine.steps.last?.id) }.buttonStyle(.pond(Pond.teal))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
    }

    private func addStep(after id: Routine.Step.ID?) {
        let new = Routine.Step("")
        let i = routine.steps.firstIndex { $0.id == id }.map { $0 + 1 } ?? routine.steps.count
        routine.steps.insert(new, at: i)
        focusedStep = new.id
    }
}
