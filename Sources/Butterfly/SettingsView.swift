import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import Speech
import SwiftUI

/// Butterfly → Settings… (⌘,). Laid out like System Settings: a grouped sidebar on the left, one page on the right.
/// Each page holds only the controls that belong together; the last page is restored.
struct SettingsView: View {
    var run: (Routine) -> Void
    @AppStorage("settingsPane") private var pane = "general"

    struct Page: Identifiable { let id, title, icon: String; let tint: Color }
    static let groups: [[Page]] = [
        [Page(id: "general", title: "General", icon: "gearshape.fill", tint: Design.slate),
         Page(id: "listening", title: "Listening", icon: "waveform", tint: Design.pink),
         Page(id: "vocabulary", title: "Vocabulary", icon: "character.book.closed.fill", tint: Design.orange)],
        [Page(id: "routines", title: "Routines", icon: "bolt.fill", tint: Design.violet),
         Page(id: "skills", title: "Learned Skills", icon: "brain.fill", tint: Design.green)],
        [Page(id: "meetings", title: "Meetings", icon: "video.fill", tint: Design.sky),
         Page(id: "screen", title: "Screen Memory", icon: "eye.fill", tint: Design.slate)],
        [Page(id: "keys", title: "API Keys", icon: "key.fill", tint: Design.orange),
         Page(id: "permissions", title: "Permissions", icon: "hand.raised.fill", tint: Design.sky)],
        [Page(id: "developer", title: "Developer", icon: "hammer.fill", tint: Design.ink)],
    ]
    private var current: Page { Self.groups.joined().first { $0.id == pane } ?? Self.groups[0][0] }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(groups: Self.groups, selection: $pane)
            Group {
                switch current.id {
                case "listening": ScrollView { ListeningPane() }
                case "vocabulary": VocabularyPane()
                case "routines": RoutinesPane(store: .shared, run: run)
                case "skills": SkillsPane(store: .shared)
                case "meetings": ScrollView { MeetingsPane() }
                case "screen": ScreenMemoryPane()
                case "keys": ScrollView { KeysPane() }
                case "permissions": ScrollView { PermissionsPane() }
                case "developer": ScrollView { DeveloperPane() }
                default: ScrollView { GeneralPane() }
                }
            }
            .id(current.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 760, height: 600)
        .background(Backdrop())
        .containerBackground(.clear, for: .window)
        .navigationTitle(current.title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(Design.ink)
        .accentColor(Design.ink)
        .preferredColorScheme(.light)
    }
}

/// System Settings–style sidebar: groups separated by space, a colored icon square per page.
private struct Sidebar: View {
    let groups: [[SettingsView.Page]]
    @Binding var selection: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups.indices, id: \.self) { g in
                    VStack(spacing: 2) {
                        ForEach(groups[g]) { p in
                            Button { selection = p.id } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: p.icon)
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(p.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Text(p.title).font(Design.body).foregroundStyle(selection == p.id ? .white : Design.ink)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 7).frame(height: 32)
                                .background(selection == p.id ? Design.ink.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 16)
        }
        .frame(width: 210)
        .background(.white.opacity(0.35))
        .overlay(alignment: .trailing) { Rectangle().fill(Design.hairline).frame(width: 1) }
    }
}

/// Page body: sections stacked with even spacing.
private struct PageBody<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content() }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var login = LoginItem.enabled
    @State private var autoUpdate = Updates.controller.updater.automaticallyChecksForUpdates
    private var version: String {
        let i = Bundle.main.infoDictionary
        return "Version \(i?["CFBundleShortVersionString"] as? String ?? "dev") (\(i?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        PageBody {
            HStack(spacing: 14) {
                if let art = Bundle.main.image(forResource: "mark") {
                    Image(nsImage: art).resizable().scaledToFit().frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Butterfly").displayText(24)
                    Text("Hold ⌥ and speak. \(version)").secondaryText(.system(size: 12.5))
                }
            }
            CardSection(title: "Startup") {
                CardRow(title: "Open at login", last: !LoginItem.needsApproval) {
                    InkToggle(isOn: $login).onChange(of: login) { LoginItem.set(login); login = LoginItem.enabled }
                }
                if LoginItem.needsApproval {
                    CardRow(title: "Needs approval in Login Items", last: true) {
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.puffy)
                    }
                }
            }
            CardSection(title: "Updates", footer: Updates.bundled ? nil : "Updates are off in development builds.") {
                CardRow(title: "Check for updates automatically") {
                    InkToggle(isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { Updates.controller.updater.automaticallyChecksForUpdates = autoUpdate }
                        .disabled(!Updates.bundled)
                }
                CardRow(title: "Check now", last: true) {
                    Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }.buttonStyle(.puffy).disabled(!Updates.bundled)
                }
            }
        }
        .onAppear { login = LoginItem.enabled }
    }
}

// MARK: - Listening

private struct ListeningPane: View {
    @State private var mic = AudioInput.preferredUID
    @State private var mics = AudioInput.devices
    @AppStorage("listeningSounds") private var sounds = true
    @AppStorage("duckMusic") private var duck = true

    var body: some View {
        PageBody {
            CardSection(title: "Microphone", footer: "Automatic uses your Mac's mic, or an external one (like a Studio Display) when the lid is closed.") {
                CardRow(title: "Listen with", last: true) {
                    Picker("", selection: $mic) {
                        Text("Automatic · \(AudioInput.chosen.map(\.name) ?? "none")").tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().glassPicker().frame(width: 260)
                    .onChange(of: mic) { AudioInput.preferredUID = mic }
                }
            }
            CardSection(title: "While listening") {
                CardRow(title: "Play start and stop sounds") {
                    InkToggle(isOn: $sounds).onChange(of: sounds) { if sounds { Cues.listening() } }
                }
                CardRow(title: "Lower music volume", last: true) {
                    InkToggle(isOn: $duck)
                }
            }
        }
        .onAppear { mics = AudioInput.devices }
    }
}

// MARK: - Meetings

private struct MeetingsPane: View {
    @AppStorage("recordMeetings") private var ask = true
    @State private var recording = Meetings.shared.recordingApp
    @AppStorage("settingsPane") private var pane = "meetings"

    var body: some View {
        PageBody {
            CardSection(title: "Recording", footer: "Zoom, Teams, Meet, Slack and FaceTime calls. Records the call audio and your mic.") {
                CardRow(title: "Ask to record when a call starts") {
                    InkToggle(isOn: $ask)
                }
                CardRow(title: recording.map { "Recording · \($0)" } ?? "Record now", last: true) {
                    Button(recording == nil ? "Record" : "Stop") {
                        Meetings.shared.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { recording = Meetings.shared.recordingApp }
                    }
                    .buttonStyle(recording == nil ? .puffy : .puffyInk)
                }
            }
            CardSection(title: "Transcripts", footer: "Gemini writes them, in Lithuanian or English. Saved in Documents › Butterfly Meetings.") {
                if Keychain.geminiKey == nil {
                    CardRow(title: "Needs a Gemini API key") {
                        Button("Add Key") { pane = "keys" }.buttonStyle(.puffyInk)
                    }
                }
                CardRow(title: "Last meeting") {
                    Button("Transcribe Again") { Meetings.shared.retranscribeLast() }.buttonStyle(.puffy)
                }
                CardRow(title: "All meeting notes", last: true) {
                    Button("Open Folder") { Meetings.openFolder() }.buttonStyle(.puffy)
                }
            }
        }
    }
}

// MARK: - API keys

private struct KeysPane: View {
    var body: some View {
        PageBody {
            KeySection(title: "TypeSafe", footer: "Required for voice commands. Get one at typesafe.ai.", prompt: "apikey_…",
                       saved: Keychain.apiKey != nil, save: Keychain.save)
            KeySection(title: "Gemini", footer: "For meeting transcripts and reading your screen. Get one at aistudio.google.com.", prompt: "AIza…",
                       saved: Keychain.geminiKey != nil, save: Keychain.saveGemini)
            Text("Keys are stored in your Keychain and never leave this Mac except to call their service.").secondaryText().padding(.horizontal, 4)
        }
    }
}

private struct KeySection: View {
    let title: String, footer: String, prompt: String
    @State var saved: Bool
    let save: (String) -> Void
    @State private var key = ""

    var body: some View {
        CardSection(title: title, footer: footer) {
            CardRow(title: "API key", last: true) {
                HStack(spacing: 8) {
                    if saved && key.isEmpty { Tag(text: "Saved", tint: Design.green) }
                    SoftField(prompt: saved ? "Replace key" : prompt, text: $key, secure: true).frame(width: 190)
                    Button("Save") {
                        save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; saved = true
                    }
                    .buttonStyle(.puffyInk)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Permissions

/// Every permission Butterfly uses, with its live status and a shortcut to the right System Settings pane.
private struct PermissionsPane: View {
    struct Item { let title, why, pane: String; let granted: () -> Bool }
    private static let items: [Item] = [
        Item(title: "Accessibility", why: "Hotkey, typing and clicking", pane: "Privacy_Accessibility", granted: { HotkeyMonitor.hasAccessibility }),
        Item(title: "Microphone", why: "Hearing what you say", pane: "Privacy_Microphone",
             granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }),
        Item(title: "Speech Recognition", why: "On-device transcription", pane: "Privacy_SpeechRecognition",
             granted: { SFSpeechRecognizer.authorizationStatus() == .authorized }),
        Item(title: "Screen Recording", why: "Screen memory and reading the screen", pane: "Privacy_ScreenCapture",
             granted: { CGPreflightScreenCaptureAccess() }),
        Item(title: "Calendars", why: "Adding events, your agenda", pane: "Privacy_Calendars",
             granted: { EKEventStore.authorizationStatus(for: .event) == .fullAccess }),
        Item(title: "Reminders", why: "Creating reminders", pane: "Privacy_Reminders",
             granted: { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }),
    ]
    @State private var status: [Bool] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        PageBody {
            CardSection(title: "Privacy", footer: "Butterfly asks for each one the first time it's needed.") {
                ForEach(Self.items.indices, id: \.self) { i in
                    let item = Self.items[i]
                    CardRow(title: item.title, last: i == Self.items.count - 1) {
                        HStack(spacing: 8) {
                            Text(item.why).secondaryText()
                            if status.indices.contains(i), status[i] { Tag(text: "Allowed", tint: Design.green) }
                            else {
                                Button("Allow…") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(item.pane)")!)
                                }
                                .buttonStyle(.puffy)
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }   // reflects changes made in System Settings
    }

    private func refresh() { status = Self.items.map { $0.granted() } }
}

// MARK: - Developer

private struct DeveloperPane: View {
    @AppStorage("developerMode") private var developer = false
    @State private var exported: String?
    @State private var appCount = AppCatalog.shared.apps.count

    var body: some View {
        PageBody {
            CardSection(title: "Developer mode", footer: "Saves a trace, screenshots and a video of each command.") {
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
            CardSection(title: "Diagnostics", footer: "Crash reports are written when Butterfly crashes or is killed. Attach them to bug reports.") {
                CardRow(title: "Crash reports") {
                    Button("Reveal") { NSWorkspace.shared.open(CrashReporter.dir.deletingLastPathComponent()) }.buttonStyle(.puffy)
                }
                CardRow(title: "App index · \(appCount) apps", last: true) {
                    Button("Rescan") { AppCatalog.shared.reload(); appCount = AppCatalog.shared.apps.count }.buttonStyle(.puffy)
                }
            }
        }
    }
}

// MARK: - Vocabulary, Routines, Learned Skills, Screen Memory

private struct VocabularyPane: View {
    struct Word: Identifiable, Equatable { var id = UUID(); var text: String }
    @State private var words: [Word] = Vocabulary.words.map { Word(text: $0) }
    @FocusState private var focused: Word.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
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
            .padding(.horizontal, 24).padding(.vertical, 20)
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
            .frame(width: 160)
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
            .padding(.horizontal, 24).padding(.vertical, 20)
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
            .padding(.horizontal, 24).padding(.vertical, 20)
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
