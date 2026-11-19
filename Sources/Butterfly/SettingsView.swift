import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import Speech
import SwiftUI

/// Butterfly → Settings… (⌘,). Laid out like System Settings: a grouped sidebar on the left, one page on the right.
/// Each page holds only the controls that belong together; the last page is restored.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = "general"

    struct Page: Identifiable { let id, title, icon: String; let tint: Color }
    static let groups: [[Page]] = [
        [Page(id: "general", title: "General", icon: "gearshape.fill", tint: Design.slate),
         Page(id: "listening", title: "Listening", icon: "waveform", tint: Design.pink),
         Page(id: "vocabulary", title: "Vocabulary", icon: "character.book.closed.fill", tint: Design.orange)],
        [Page(id: "meetings", title: "Meetings", icon: "video.fill", tint: Design.sky)],
        [Page(id: "keys", title: "API Keys", icon: "key.fill", tint: Design.orange),
         Page(id: "permissions", title: "Permissions", icon: "hand.raised.fill", tint: Design.sky)],
        [Page(id: "developer", title: "Diagnostics", icon: "hammer.fill", tint: Design.ink)],
    ]
    private var current: Page { Self.groups.joined().first { $0.id == pane } ?? Self.groups[0][0] }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(groups: Self.groups, selection: $pane)
            Group {
                switch current.id {
                case "listening": ScrollView { ListeningPane() }
                case "vocabulary": VocabularyPane()
                case "meetings": ScrollView { MeetingsPane() }
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
                    Text("Meeting notes and dictation. \(version)").secondaryText(.system(size: 12.5))
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
    @AppStorage("listeningSounds") private var sounds = true
    @AppStorage("duckMusic") private var duck = true

    var body: some View {
        PageBody {
            CardSection(title: "While dictating", footer: "Hold right ⌥ and speak: your words are typed where the cursor is. Right ⌥⇧ keeps dictating until you tap right ⌥.") {
                CardRow(title: "Play start and stop sounds") {
                    InkToggle(isOn: $sounds).onChange(of: sounds) { if sounds { Cues.listening() } }
                }
                CardRow(title: "Lower music volume", last: true) {
                    InkToggle(isOn: $duck)
                }
            }
        }
    }
}

// MARK: - Meetings

private struct MeetingsPane: View {
    @AppStorage("recordMeetings") private var ask = true
    @AppStorage("settingsPane") private var pane = "meetings"
    @State private var mic = AudioInput.preferredUID
    @State private var mics = AudioInput.devices

    var body: some View {
        PageBody {
            CardSection(title: "Recording", footer: "Zoom, Teams, Meet, Slack and FaceTime calls. Records the call audio and your mic. To record any time: menu bar icon → Record Meeting.") {
                CardRow(title: "Ask to record when a call starts", last: true) {
                    InkToggle(isOn: $ask)
                }
            }
            CardSection(title: "Microphone", footer: "Used for meetings and dictation. Automatic uses your Mac's mic, or an external one (like a Studio Display) when the lid is closed.") {
                CardRow(title: "Listen with", last: true) {
                    Picker("", selection: $mic) {
                        Text("Automatic · \(AudioInput.chosen.map(\.name) ?? "none")").tag("")
                        ForEach(mics) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().glassPicker().frame(width: 260)
                    .onChange(of: mic) { AudioInput.preferredUID = mic }
                }
            }
            CardSection(title: "Transcripts", footer: "Gemini writes the transcript, summary and action items. Lithuanian with English work terms is kept as spoken, never translated. Saved in Documents › Butterfly Meetings.") {
                if Keychain.geminiKey == nil {
                    CardRow(title: "Needs a Gemini API key") {
                        Button("Add Key") { pane = "keys" }.buttonStyle(.puffyInk)
                    }
                }
                CardRow(title: "Folder", last: true) {
                    Button("Open") { Meetings.openFolder() }.buttonStyle(.puffy)
                }
            }
            CardSection(title: "Cortex", footer: "Sends each transcript to Cortex, which remembers the decisions, people and plans in it. Connect from Cortex › Connectors › Butterfly.") {
                CardRow(title: Cortex.connected ? "Connected" : "Not connected", last: true) {
                    if Cortex.connected { Button("Resend All") { Cortex.sendAll(again: true) }.buttonStyle(.puffy) }
                }
            }
            let shown = showAll ? recordings : Array(recordings.prefix(10))
            VStack(alignment: .leading, spacing: 10) {
                CardSection(title: "Recordings", footer: recordings.isEmpty ? "No recordings yet." : nil) {
                    ForEach(shown.indices, id: \.self) { i in
                        RecordingRow(rec: shown[i], busy: busy.contains(shown[i].id), last: i == shown.count - 1,
                                     canTranscribe: Keychain.geminiKey != nil) { retranscribe(shown[i]) }
                    }
                }
                if recordings.count > shown.count {
                    Button("Show all (\(recordings.count))") { showAll = true }.buttonStyle(.puffy)
                }
            }
        }
        .onAppear { reload(); mics = AudioInput.devices }
    }

    @State private var recordings: [Meetings.Recording] = []
    @State private var busy: Set<String> = []
    @State private var showAll = false

    private func reload() { recordings = Meetings.recordings() }

    private func retranscribe(_ r: Meetings.Recording) {
        busy.insert(r.id)
        Meetings.shared.retranscribeLast(folder: r.folder) { _ in
            busy.remove(r.id)
            reload()
        }
    }
}

/// One recording: title, when, transcript status, and Transcribe Again.
private struct RecordingRow: View {
    let rec: Meetings.Recording
    let busy: Bool, last: Bool, canTranscribe: Bool
    let retranscribe: () -> Void
    @State private var showWhy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title).font(Design.body).foregroundStyle(Design.ink).lineLimit(1).truncationMode(.tail)
                    Text(rec.date?.formatted(date: .abbreviated, time: .shortened) ?? rec.name).secondaryText(.system(size: 11.5))
                }
                Spacer(minLength: 12)
                if rec.status == .failed && !busy {
                    Button { showWhy.toggle() } label: { Tag(text: "Failed", tint: Design.pink) }
                        .buttonStyle(.plain).help("Why it failed")
                        .popover(isPresented: $showWhy, arrowEdge: .bottom) {
                            Text(rec.reason ?? "No details.")
                                .font(.system(size: 12)).foregroundStyle(Design.ink).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 320, alignment: .leading).padding(14)
                        }
                }
                if busy { ProgressView().controlSize(.small).frame(width: 34) }
                else if rec.status != .done {
                    Button(rec.status == .failed ? "Transcribe Again" : "Transcribe", action: retranscribe).buttonStyle(.puffy).disabled(!canTranscribe)
                } else {
                    Button("Open") { NSWorkspace.shared.open(rec.folder.appendingPathComponent("transcript.md")) }.buttonStyle(.puffy)
                    Menu {
                        Button("Transcribe Again", action: retranscribe).disabled(!canTranscribe)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([rec.folder]) }
                    } label: {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Design.ink)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                        .help("More")
                }
            }
            .padding(.horizontal, Design.pad).frame(minHeight: 52)
            if !last { Rectangle().fill(Design.hairline).frame(height: 1).padding(.leading, Design.pad) }
        }
    }
}

// MARK: - API keys

private struct KeysPane: View {
    var body: some View {
        PageBody {
            KeySection(title: "Gemini", footer: "Writes meeting notes and transcribes dictation. Get one at aistudio.google.com.", prompt: "AIza…",
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
    struct Item { let title, why, pane: String; let granted: () -> Bool; var request: (() async -> Void)? = nil }
    private static let items: [Item] = [
        Item(title: "Accessibility", why: "Hotkey and typing", pane: "Privacy_Accessibility", granted: { HotkeyMonitor.hasAccessibility }),
        Item(title: "Microphone", why: "Meetings and dictation", pane: "Privacy_Microphone",
             granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
             request: { guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
                        _ = await AVCaptureDevice.requestAccess(for: .audio) }),
        Item(title: "Speech Recognition", why: "On-device dictation", pane: "Privacy_SpeechRecognition",
             granted: { SFSpeechRecognizer.authorizationStatus() == .authorized },
             request: { guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
                        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } } }),
        Item(title: "Screen Recording", why: "Recording call audio", pane: "Privacy_ScreenCapture",
             granted: { CGPreflightScreenCaptureAccess() }),
        Item(title: "Calendars", why: "Naming meeting recordings", pane: "Privacy_Calendars",
             granted: { EKEventStore.authorizationStatus(for: .event) == .fullAccess },
             request: { guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
                        _ = try? await EKEventStore().requestFullAccessToEvents() }),
    ]
    @State private var status: [Bool] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        PageBody {
            CardSection(title: "Privacy", footer: "Butterfly asks for each one the first time it's needed.") {
                ForEach(Self.items.indices, id: \.self) { i in
                    let item = Self.items[i]
                    CardRow(title: item.title, subtitle: item.why, last: i == Self.items.count - 1) {
                        HStack(spacing: 8) {
                            if status.indices.contains(i), status[i] { Tag(text: "Allowed", tint: Design.green) }
                            else {
                                Button("Allow…") {
                                    // Ask macOS first (the only way onto Calendars/Reminders); declined, or listed with +, → System Settings.
                                    Task { @MainActor in
                                        await item.request?()
                                        refresh()
                                        if !status[i] {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(item.pane)")!)
                                        }
                                    }
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
    var body: some View {
        PageBody {
            CardSection(title: "Diagnostics", footer: "Crash reports are written when Butterfly crashes or is killed. Attach them to bug reports.") {
                CardRow(title: "Crash reports", last: true) {
                    Button("Reveal") { NSWorkspace.shared.open(CrashReporter.dir.deletingLastPathComponent()) }.buttonStyle(.puffy)
                }
            }
        }
    }
}

// MARK: - Vocabulary

private struct VocabularyPane: View {
    struct Word: Identifiable, Equatable { var id = UUID(); var text: String }
    @State private var words: [Word] = Vocabulary.words.map { Word(text: $0) }
    @FocusState private var focused: Word.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.section) {
                CardSection(title: "Vocabulary",
                            footer: "Names and web addresses, like “openmail.sh” or a colleague's name. Helps dictation and meeting transcripts spell them right.") {
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
