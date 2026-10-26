import AppKit
import ServiceManagement
import SwiftUI

/// CTRL → Settings… (⌘,). One fixed-size window with a flat Pond tab strip (General · Vocabulary · Routines);
/// the title follows the pane and the last pane is restored.
struct SettingsView: View {
    var run: (Routine) -> Void
    @AppStorage("settingsPane") private var pane = "general"

    private static let panes: [(id: String, title: String, icon: String, tint: Color)] = [
        ("general", "General", "gearshape", Pond.lime),
        ("vocabulary", "Vocabulary", "character.book.closed", Pond.lavender),
        ("routines", "Routines", "bolt", Pond.peach),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Self.panes, id: \.id) { p in PondTab(title: p.title, icon: p.icon, tint: p.tint, selected: pane == p.id) { pane = p.id } }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            Rectangle().fill(Pond.ink.opacity(0.12)).frame(height: 1)
            Group {
                switch pane {
                case "vocabulary": VocabularyPane()
                case "routines": RoutinesPane(store: .shared, run: run)
                default: ScrollView { GeneralPane() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 620, height: 600)
        .background(Pond.paper)
        .navigationTitle(Self.panes.first { $0.id == pane }?.title ?? "Settings")
        .toolbarBackground(Pond.paper, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .tint(Pond.ink)
        .accentColor(Pond.ink)
        .preferredColorScheme(.light)
    }
}

/// Settings pane switcher: flat square block, ink glyph over a mono label; the selected pane is filled with its color.
private struct PondTab: View {
    let title: String, icon: String, tint: Color, selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .regular)).symbolRenderingMode(.monochrome)
                    .frame(height: 20)
                Text(title.uppercased()).font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.6)
            }
            .foregroundStyle(Pond.ink.opacity(selected ? 1 : 0.62))
            .frame(width: 92, height: 50)
            .background(selected ? tint : (hover ? Pond.ink.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct GeneralPane: View {
    @State private var key = ""
    @State private var hasKey = Keychain.apiKey != nil
    @State private var trusted = HotkeyMonitor.hasAccessibility
    @State private var appCount = AppCatalog.shared.apps.count
    @State private var login = LoginItem.enabled
    @AppStorage("developerMode") private var developer = false
    @AppStorage("listeningSounds") private var sounds = true
    @AppStorage("duckMusic") private var duck = true
    @State private var mic = AudioInput.preferredUID
    @State private var mics = AudioInput.devices

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                if let art = Bundle.main.image(forResource: "mark") {
                    Image(nsImage: art).resizable().scaledToFit().frame(width: 88, height: 88)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("A faithful computer").font(Pond.display(26)).foregroundStyle(Pond.ink)
                    HStack(spacing: 0) {
                        PondChip(text: "Hold ⌥", fill: Pond.lavender)
                        PondChip(text: "and speak", fill: Pond.lime)
                    }
                }
            }

            PondSection(title: "TypeSafe", tint: Pond.lavender, footer: "Stored in your Keychain. Get one at typesafe.ai.") {
                PondRow(title: "API key", last: true) {
                    HStack(spacing: 6) {
                        PondField(prompt: hasKey ? "Saved in Keychain" : "apikey_…", text: $key, secure: true).frame(width: 200)
                        Button("Save") {
                            Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""; hasKey = true
                        }
                        .buttonStyle(.pond(Pond.lime))
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            PondSection(title: "Microphone", tint: Pond.peach,
                        footer: "Automatic uses your Mac's input, and an external mic (like a Studio Display) when the lid is closed.") {
                PondRow(title: "Listen with", last: true) {
                    Picker("", selection: $mic) {
                        Text("Automatic · \(AudioInput.chosen.map(\.name) ?? "none")").tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().frame(width: 260)
                    .onChange(of: mic) { AudioInput.preferredUID = mic }
                }
            }

            PondSection(title: "System", tint: Pond.teal) {
                PondRow(title: "Sounds when listening starts and stops") {
                    Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch).tint(Pond.moss)
                        .onChange(of: sounds) { if sounds { Cues.listening() } }
                }
                PondRow(title: "Lower music while listening") {
                    Toggle("", isOn: $duck).labelsHidden().toggleStyle(.switch).tint(Pond.moss)
                }
                PondRow(title: "Open at login") {
                    Toggle("", isOn: $login).labelsHidden().toggleStyle(.switch).tint(Pond.moss)
                        .onChange(of: login) { LoginItem.set(login); login = LoginItem.enabled }
                }
                PondRow(title: "Accessibility") {
                    if trusted { PondChip(text: "● Allowed", fill: Pond.lime) }
                    else {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.pond(Pond.peach))
                    }
                }
                PondRow(title: "\(appCount) apps found") {
                    Button("Rescan") { AppCatalog.shared.reload(); appCount = AppCatalog.shared.apps.count }
                        .buttonStyle(.pond(Pond.teal))
                }
                PondRow(title: "Developer mode", last: true) {
                    Toggle("", isOn: $developer).labelsHidden().toggleStyle(.switch).tint(Pond.moss)
                }
            }
            if LoginItem.needsApproval {
                Button("Allow Butterfly in Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pond(Pond.peach))
            }
        }
        .padding(20)
        .onAppear { trusted = HotkeyMonitor.hasAccessibility; appCount = AppCatalog.shared.apps.count; login = LoginItem.enabled; mics = AudioInput.devices }
    }
}

private struct VocabularyPane: View {
    struct Word: Identifiable, Equatable { var id = UUID(); var text: String }
    @State private var words: [Word] = Vocabulary.words.map { Word(text: $0) }
    @FocusState private var focused: Word.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Words Butterfly should hear right")
                    .font(Pond.display(26)).foregroundStyle(Pond.ink)
                    .padding(.horizontal, 8).background(Pond.lime)
                PondSection(title: "Vocabulary", tint: Pond.peach,
                            footer: "Names and web addresses, like “openmail.sh” or a colleague's name.") {
                    ForEach($words) { $w in
                        VStack(spacing: 0) {
                            HStack {
                                TextField("", text: $w.text, prompt: Text("openmail.sh"))
                                    .textFieldStyle(.plain).font(Pond.body).foregroundStyle(Pond.ink)
                                    .focused($focused, equals: w.id)
                                    .onSubmit { add(after: w.id) }
                                Button("−") { words.removeAll { $0.id == w.id } }.buttonStyle(.pond(Pond.rose)).help("Remove")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            Rectangle().fill(Pond.ink.opacity(0.08)).frame(height: 1)
                        }
                    }
                    HStack {
                        Button("+ Add word") { add(after: words.last?.id) }.buttonStyle(.pond(Pond.peach))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .padding(20)
        }
        .frame(height: 380)
        .onChange(of: words) { Vocabulary.save(words.map(\.text)) }
    }

    private func add(after id: Word.ID?) {
        let w = Word(text: "")
        let i = words.firstIndex { $0.id == id }.map { $0 + 1 } ?? words.count
        words.insert(w, at: i)
        focused = w.id
    }
}

/// Routine list on the left (numbered, Pond chips), editor on the right.
private struct RoutinesPane: View {
    @ObservedObject var store: RoutineStore
    var run: (Routine) -> Void
    @State private var selection: Routine.ID?
    private let tints = [Pond.lavender, Pond.lime, Pond.peach, Pond.teal, Pond.rose]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                PondChip(text: "Routines", fill: Pond.ink, ink: Pond.lime)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(store.routines.enumerated()), id: \.element.id) { i, r in
                            Button { selection = r.id } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(Pond.label).frame(width: 18, height: 18).background(tints[i % tints.count])
                                    Text(r.name.isEmpty ? "Untitled" : r.name).font(Pond.body)
                                    Spacer()
                                }
                                .foregroundStyle(Pond.ink)
                                .padding(4)
                                .background(selection == r.id ? Pond.lime.opacity(0.6) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Button("+") { add() }.buttonStyle(.pond(Pond.teal)).help("New routine")
                    Button("−") { remove() }.buttonStyle(.pond(Pond.rose)).disabled(selection == nil).help("Delete routine")
                }
            }
            .frame(width: 160)
            .padding([.leading, .vertical], 20)

            Rectangle().fill(Pond.ink.opacity(0.1)).frame(width: 1).padding(.vertical, 20).padding(.leading, 16)

            if let i = store.routines.firstIndex(where: { $0.id == selection }) {
                RoutineEditor(routine: $store.routines[i], run: run).id(store.routines[i].id)
            } else {
                VStack(spacing: 10) {
                    Text("No routine yet").font(Pond.display(24)).foregroundStyle(Pond.ink)
                    Text("One phrase runs several commands, like “work mode”.").font(Pond.body).foregroundStyle(Pond.ink.opacity(0.6))
                    Button("+ New routine") { add() }.buttonStyle(.pond(Pond.lime))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 420)
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

/// Open at login (SMAppService). On by default the first time CTRL runs from /Applications.
@MainActor
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "openAtLogin")
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { print("login item:", error) }
    }

    /// Called at launch: registers once unless you turned it off. Only for the installed copy, not dev builds.
    static func applyDefault() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let wanted = UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true
        if wanted != enabled { set(wanted) }
    }
}
