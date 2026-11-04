import AppKit
import ServiceManagement
import SwiftUI

/// Butterfly → Settings… (⌘,). One fixed-size window with a pill tab strip (General · Vocabulary · Routines · Skills · Screen · Developer);
/// the title follows the pane and the last pane is restored.
struct SettingsView: View {
    var run: (Routine) -> Void
    @AppStorage("settingsPane") private var pane = "general"

    private static let panes: [(id: String, title: String, icon: String)] = [
        ("general", "General", "gearshape"),
        ("vocabulary", "Vocabulary", "character.book.closed"),
        ("routines", "Routines", "bolt"),
        ("skills", "Skills", "brain"),
        ("screen", "Screen", "eye"),
        ("developer", "Developer", "hammer"),
    ]

    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(Self.panes, id: \.id) { p in
                        PaneTab(title: p.title, icon: p.icon, selected: pane == p.id, ns: tabs) {
                            withAnimation(.bouncy(duration: 0.35)) { pane = p.id }
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            Group {
                switch pane {
                case "vocabulary": VocabularyPane()
                case "routines": RoutinesPane(store: .shared, run: run)
                case "skills": SkillsPane(store: .shared)
                case "screen": ScreenMemoryPane()
                case "developer": ScrollView { DeveloperPane() }
                default: ScrollView { GeneralPane() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 640, height: 660)
        .background(Backdrop())
        .containerBackground(.clear, for: .window)
        .navigationTitle(Self.panes.first { $0.id == pane }?.title ?? "Settings")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(Design.ink)
        .accentColor(Design.ink)
        .preferredColorScheme(.light)
    }
}

/// Settings pane switcher: glass capsule segments; the selected one is ink-tinted glass that morphs between tabs.
private struct PaneTab: View {
    let title: String, icon: String, selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .medium)).tracking(-0.1)
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? .white : Design.ink.opacity(hover ? 1 : 0.8))
                .padding(.horizontal, 11).frame(height: 32)
                .contentShape(Capsule())
                .glassEffect(selected ? .regular.tint(Design.ink).interactive() : .regular.interactive(), in: .capsule)
                .glassEffectID(selected ? "selected" : title, in: ns)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Page header: editorial serif title and a gray line under it, centered.
private struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 6) {
            Text(title).displayText(32)
            if let subtitle { Text(subtitle).secondaryText(.system(size: 14)).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6).padding(.bottom, 4)
    }
}

private struct GeneralPane: View {
    @State private var key = ""
    @State private var hasKey = Keychain.apiKey != nil
    @State private var trusted = HotkeyMonitor.hasAccessibility
    @State private var appCount = AppCatalog.shared.apps.count
    @State private var login = LoginItem.enabled
    @State private var recording: String?
    @AppStorage("listeningSounds") private var sounds = true
    @AppStorage("duckMusic") private var duck = true
    @AppStorage("recordMeetings") private var recordMeetings = true
    @State private var gemini = ""
    @State private var hasGemini = Keychain.geminiKey != nil
    @State private var mic = AudioInput.preferredUID
    @State private var mics = AudioInput.devices

    var body: some View {
        VStack(alignment: .leading, spacing: Design.section) {
            VStack(spacing: 18) {
                if let art = Bundle.main.image(forResource: "mark") {
                    Image(nsImage: art).resizable().scaledToFit().frame(width: 64, height: 64)
                }
                PageTitle(title: "A faithful computer", subtitle: "Hold ⌥ and speak. Butterfly does the rest.")
                GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    WidgetTile(title: "Speak", symbol: "waveform", caption: "Hold ⌥", tint: Design.pink)
                    WidgetTile(title: "Meetings", symbol: "video.fill", caption: recordMeetings ? "Asks to record" : "Off", tint: Design.sky)
                    WidgetTile(title: "Routines", symbol: "bolt.fill", caption: "One phrase", tint: Design.orange)
                    WidgetTile(title: "Memory", symbol: "eye.fill", caption: ScreenMemory.shared.enabled ? "On" : "Off", tint: Design.slate)
                    WidgetTile(title: "Keys", symbol: hasKey ? "checkmark.seal.fill" : "key.fill", caption: hasKey ? "Saved" : "Add a key", tint: Design.green, filled: false)
                }
                }
            }
            .frame(maxWidth: .infinity)

            CardSection(title: "TypeSafe", footer: "Stored in your Keychain. Get one at typesafe.ai.") {
                CardRow(title: "API key", last: true) {
                    HStack(spacing: 6) {
                        SoftField(prompt: hasKey ? "Saved in Keychain" : "apikey_…", text: $key, secure: true).frame(width: 200)
                        Button("Save") {
                            Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""; hasKey = true
                        }
                        .buttonStyle(.puffyInk)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            CardSection(title: "Microphone",
                        footer: "Automatic uses your Mac's input, and an external mic (like a Studio Display) when the lid is closed.") {
                CardRow(title: "Listen with", last: true) {
                    Picker("", selection: $mic) {
                        Text("Automatic · \(AudioInput.chosen.map(\.name) ?? "none")").tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().glassPicker().frame(width: 260)
                    .onChange(of: mic) { AudioInput.preferredUID = mic }
                }
            }

            CardSection(title: "Meetings",
                        footer: "When Zoom, Teams, Meet, Slack or FaceTime start a call, the notch asks to record it (the call and your mic). Gemini writes the transcript (Lithuanian and English). Saved in Documents › Butterfly Meetings.") {
                CardRow(title: "Ask to record when a call starts") {
                    InkToggle(isOn: $recordMeetings)
                }
                CardRow(title: "Gemini API key") {
                    HStack(spacing: 6) {
                        SoftField(prompt: hasGemini ? "Saved in Keychain" : "AIza…", text: $gemini, secure: true).frame(width: 200)
                        Button("Save") {
                            Keychain.saveGemini(gemini.trimmingCharacters(in: .whitespacesAndNewlines))
                            gemini = ""; hasGemini = true
                        }
                        .buttonStyle(.puffyInk)
                        .disabled(gemini.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                CardRow(title: recording.map { "Recording · \($0)" } ?? "Record a meeting now") {
                    Button(recording == nil ? "Record" : "Stop") {
                        Meetings.shared.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { recording = Meetings.shared.recordingApp }
                    }
                    .buttonStyle(.puffy)
                    .onAppear { recording = Meetings.shared.recordingApp }
                }
                CardRow(title: "Meeting notes", last: true) {
                    HStack(spacing: 6) {
                        Button("Transcribe last") { Meetings.shared.retranscribeLast() }.buttonStyle(.puffy)
                        Button("Open folder") { Meetings.openFolder() }.buttonStyle(.puffy)
                    }
                }
            }

            CardSection(title: "System") {
                CardRow(title: "Sounds when listening starts and stops") {
                    InkToggle(isOn: $sounds)
                        .onChange(of: sounds) { if sounds { Cues.listening() } }
                }
                CardRow(title: "Lower music while listening") {
                    InkToggle(isOn: $duck)
                }
                CardRow(title: "Open at login") {
                    InkToggle(isOn: $login)
                        .onChange(of: login) { LoginItem.set(login); login = LoginItem.enabled }
                }
                CardRow(title: "Accessibility") {
                    if trusted { Tag(text: "Allowed", tint: Design.green) }
                    else {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.puffy)
                    }
                }
                CardRow(title: "\(appCount) apps found", last: true) {
                    Button("Rescan") { AppCatalog.shared.reload(); appCount = AppCatalog.shared.apps.count }
                        .buttonStyle(.puffy)
                }
            }
            if LoginItem.needsApproval {
                Button("Allow Butterfly in Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.puffy)
            }
        }
        .padding(Design.margin)
        .onAppear { trusted = HotkeyMonitor.hasAccessibility; appCount = AppCatalog.shared.apps.count; login = LoginItem.enabled; mics = AudioInput.devices }
    }
}

private struct DeveloperPane: View {
    @AppStorage("developerMode") private var developer = false
    @State private var exported: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.section) {
            PageTitle(title: "Developer", subtitle: "Record every command to see what Butterfly heard, decided and clicked.")
            CardSection(title: "Developer mode", footer: "Saves a trace, screenshots and a video of each command in Application Support › Butterfly › debug.") {
                CardRow(title: "Record every command", last: !developer) {
                    InkToggle(isOn: $developer)
                }
                if developer {
                    CardRow(title: "Decision tree") {
                        Button("Show") { DecisionTreeWindow.shared.toggle() }.buttonStyle(.puffy)
                    }
                    CardRow(title: exported.map { "Debug logs · \($0)" } ?? "Debug logs", last: true) {
                        HStack(spacing: 6) {
                            Button("Reveal") { DebugRecorder.reveal() }.buttonStyle(.puffy)
                            Button("Export") {
                                if let zip = DebugRecorder.export() { exported = "saved to Desktop"; NSWorkspace.shared.activateFileViewerSelecting([zip]) } else { exported = "export failed" }
                            }
                            .buttonStyle(.puffy)
                        }
                    }
                }
            }
            CardSection(title: "Crash reports", footer: "Written when Butterfly crashes or is killed. Attach them to bug reports.") {
                CardRow(title: "~/Library/Logs/Butterfly", last: true) {
                    Button("Reveal") { NSWorkspace.shared.open(CrashReporter.dir.deletingLastPathComponent()) }.buttonStyle(.puffy)
                }
            }
        }
        .padding(Design.margin)
    }
}

private struct VocabularyPane: View {
    struct Word: Identifiable, Equatable { var id = UUID(); var text: String }
    @State private var words: [Word] = Vocabulary.words.map { Word(text: $0) }
    @FocusState private var focused: Word.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
                PageTitle(title: "Words Butterfly should hear right")
                CardSection(title: "Vocabulary",
                            footer: "Names and web addresses, like “openmail.sh” or a colleague's name.") {
                    ForEach($words) { $w in
                        VStack(spacing: 0) {
                            HStack {
                                TextField("", text: $w.text, prompt: Text("openmail.sh"))
                                    .textFieldStyle(.plain).font(Design.body).foregroundStyle(Design.ink)
                                    .focused($focused, equals: w.id)
                                    .onSubmit { add(after: w.id) }
                                Button(role: .destructive) { words.removeAll { $0.id == w.id } } label: { Image(systemName: "minus") }.buttonStyle(.puffy).help("Remove")
                            }
                            .padding(.horizontal, Design.pad).padding(.vertical, 9)
                            Rectangle().fill(Design.hairline).frame(height: 1)
                        }
                    }
                    HStack {
                        Button { add(after: words.last?.id) } label: { Label("Add word", systemImage: "plus") }.buttonStyle(.puffy)
                        Spacer()
                    }
                    .padding(.horizontal, Design.pad).padding(.vertical, 12)
                }
            }
            .padding(Design.margin)
        }
                .onChange(of: words) { Vocabulary.save(words.map(\.text)) }
    }

    private func add(after id: Word.ID?) {
        let w = Word(text: "")
        let i = words.firstIndex { $0.id == id }.map { $0 + 1 } ?? words.count
        words.insert(w, at: i)
        focused = w.id
    }
}

/// Routine list on the left (numbered tiles) in a light gray frame, editor on the right.
private struct RoutinesPane: View {
    @ObservedObject var store: RoutineStore
    var run: (Routine) -> Void
    @State private var selection: Routine.ID?
    private let tints = [Design.violet, Design.green, Design.orange, Design.sky, Design.pink]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Routines").titleText(22).padding(.leading, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(store.routines.enumerated()), id: \.element.id) { i, r in
                            Button { selection = r.id } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(Design.label).foregroundStyle(.white).frame(width: 22, height: 22)
                                        .background(tints[i % tints.count], in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    Text(r.name.isEmpty ? "Untitled" : r.name).font(Design.body)
                                    Spacer()
                                }
                                .foregroundStyle(Design.ink)
                                .padding(6)
                                .contentShape(.rect(cornerRadius: 12))
                                .glassEffect(selection == r.id ? .regular.tint(.white.opacity(0.6)).interactive() : .identity, in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.puffy).help("New routine")
                    Button(role: .destructive) { remove() } label: { Image(systemName: "minus") }.buttonStyle(.puffy).disabled(selection == nil).help("Delete routine")
                }
                }
            }
            .padding(12)
            .frame(width: 180)
            .softCard(radius: Design.radius)
            .padding([.leading, .vertical], 20)

            if let i = store.routines.firstIndex(where: { $0.id == selection }) {
                RoutineEditor(routine: $store.routines[i], run: run).id(store.routines[i].id)
            } else {
                VStack(spacing: 10) {
                    Text("No routine yet").displayText(24)
                    Text("One phrase runs several commands, like “work mode”.").secondaryText(.system(size: 14))
                    Button { add() } label: { Label("New routine", systemImage: "plus") }.buttonStyle(.puffyInk)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
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

/// What Butterfly learned by doing: one row per skill, forget any of them.
private struct SkillsPane: View {
    @ObservedObject var store: SkillStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
                PageTitle(title: "Things Butterfly learned")
                if store.skills.isEmpty {
                    Text("Nothing yet. The first time a request needs working out, the finished plan is kept here and runs instantly next time.")
                        .secondaryText(.system(size: 14))
                } else {
                    CardSection(title: "\(store.skills.count) skills", footer: "Patterns with {slots} match what you say; the steps run without any model call.") {
                        ForEach(store.skills.sorted { $0.lastUsed > $1.lastUsed }) { s in
                            VStack(spacing: 0) {
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.name).font(Design.body.weight(.medium)).foregroundStyle(Design.ink)
                                        Text("“\(s.pattern)”").font(Design.body).foregroundStyle(Design.ink.opacity(0.8))
                                        Text(s.steps.map(Planner.describe).joined(separator: " → ")).font(Design.label).foregroundStyle(Design.secondary).lineLimit(2)
                                        Text("\(s.uses) \(s.uses == 1 ? "use" : "uses") · last \(s.lastUsed.formatted(.relative(presentation: .named)))").font(Design.label).foregroundStyle(Design.secondary)
                                    }
                                    Spacer()
                                    Button("Forget", role: .destructive) { store.forget(s) }.buttonStyle(.puffy)
                                }
                                .padding(.horizontal, Design.pad).padding(.vertical, 12)
                                Rectangle().fill(Design.hairline).frame(height: 1)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Forget all", role: .destructive) { store.forgetAll() }.buttonStyle(.puffy)
                        }
                        .padding(.horizontal, Design.pad).padding(.vertical, 12)
                    }
                }
            }
            .padding(Design.margin)
        }
    }
}

/// Screen memory: on/off, which apps are never read, what's stored.
private struct ScreenMemoryPane: View {
    @State private var enabled = ScreenMemory.shared.enabled
    @State private var excluded = ScreenMemory.excludedApps
    @State private var newApp = ""
    @State private var count = ScreenMemory.shared.count
    @State private var bytes = ScreenMemory.diskUsage
    @FocusState private var adding: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
                PageTitle(title: "What was on your screen")
                CardSection(title: "Screen memory",
                            footer: "Every few seconds the front window is read (on-device OCR) and kept with its time and app, so you can ask “what was the price I saw on Stride?” or “what did I do in the last hour?”. Text stays 30 days, frames 7 days, encrypted with a key in your Keychain. Nothing leaves the Mac until you ask about it.") {
                    CardRow(title: "Remember my screen") {
                        InkToggle(isOn: $enabled)
                            .onChange(of: enabled) { ScreenMemory.shared.enabled = enabled }
                    }
                    CardRow(title: "\(count) screens · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", last: true) {
                        Button("Forget history", role: .destructive) { ScreenMemory.shared.forgetAll(); refresh() }.buttonStyle(.puffy)
                    }
                }
                CardSection(title: "Never read these apps",
                            footer: "Password managers, banks and private chats are skipped by default. Private and incognito browser windows are always skipped.") {
                    ForEach(excluded, id: \.self) { name in
                        VStack(spacing: 0) {
                            HStack {
                                Text(name).font(Design.body).foregroundStyle(Design.ink)
                                Spacer()
                                Button(role: .destructive) { excluded.removeAll { $0 == name } } label: { Image(systemName: "minus") }.buttonStyle(.puffy).help("Remove")
                            }
                            .padding(.horizontal, Design.pad).padding(.vertical, 9)
                            Rectangle().fill(Design.hairline).frame(height: 1)
                        }
                    }
                    HStack(spacing: 6) {
                        SoftField(prompt: "App name", text: $newApp).frame(width: 220).focused($adding).onSubmit(add)
                        Button { add() } label: { Label("Add", systemImage: "plus") }.buttonStyle(.puffy).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Button("Reset to defaults") { excluded = ScreenMemory.defaultExcluded }.buttonStyle(.puffy)
                    }
                    .padding(.horizontal, Design.pad).padding(.vertical, 12)
                }
            }
            .padding(Design.margin)
        }
        .onChange(of: excluded) { ScreenMemory.excludedApps = excluded }
        .onAppear(perform: refresh)
    }

    private func add() {
        let n = newApp.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !excluded.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        excluded.append(n); newApp = ""
    }

    private func refresh() { enabled = ScreenMemory.shared.enabled; count = ScreenMemory.shared.count; bytes = ScreenMemory.diskUsage }
}

/// Open at login (SMAppService). On by default the first time Butterfly runs from /Applications.
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
