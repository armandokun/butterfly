import AppKit
import SwiftUI

struct RoutineEditor: View {
    @Binding var routine: Routine
    var run: (Routine) -> Void
    @FocusState private var focusedStep: Routine.Step.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
                HStack(alignment: .firstTextBaseline) {
                    Text(routine.name.isEmpty ? "Untitled" : routine.name).displayText(30).lineLimit(1)
                    Spacer()
                    Button { run(routine) } label: { Label("Run now", systemImage: "play.fill") }
                        .buttonStyle(.puffyInk)
                        .disabled(!routine.isRunnable)
                        .help(routine.isRunnable ? "Run this routine" : "Add a name and at least one step")
                }

                CardSection(title: "Trigger", footer: "Phrases you'd say to start it, separated by commas.") {
                    CardRow(title: "Name") { SoftField(prompt: "Work mode", text: $routine.name).frame(maxWidth: 260) }
                    CardRow(title: "Say it like", last: true) {
                        SoftField(prompt: "work mode, let's get to work", text: $routine.phrases).frame(maxWidth: 260)
                    }
                }

                CardSection(title: "Steps",
                            footer: "Each step is anything you'd say to Butterfly: “open slack”, “play some music”, “switch to dark mode”.") {
                    ForEach(Array(routine.steps.enumerated()), id: \.element.id) { i, step in
                        let binding = Binding(get: { routine.steps.first { $0.id == step.id }?.text ?? "" },
                                              set: { t in if let j = routine.steps.firstIndex(where: { $0.id == step.id }) { routine.steps[j].text = t } })
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(Design.label).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(Design.sky, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                TextField("", text: binding, prompt: Text("open cursor and slack side by side"))
                                    .textFieldStyle(.plain).font(Design.body).foregroundStyle(Design.ink)
                                    .focused($focusedStep, equals: step.id)
                                    .onSubmit { addStep(after: step.id) }
                                Button(role: .destructive) { routine.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus") }
                                    .buttonStyle(.puffy)
                                    .disabled(routine.steps.count == 1)
                                    .help("Remove step")
                            }
                            .padding(.horizontal, Design.pad).padding(.vertical, 9)
                            Rectangle().fill(Design.hairline).frame(height: 1)
                        }
                    }
                    HStack {
                        Button { addStep(after: routine.steps.last?.id) } label: { Label("Add step", systemImage: "plus") }.buttonStyle(.puffy)
                        Spacer()
                    }
                    .padding(.horizontal, Design.pad).padding(.vertical, 12)
                }
            }
            .padding(Design.margin)
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
