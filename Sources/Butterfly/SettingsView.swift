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
        [Page(id: "agent", title: "Desktop Agent", icon: "sparkles", tint: Design.violet)],
        [Page(id: "meetings", title: "Meetings", icon: "video.fill", tint: Design.sky),
         Page(id: "screen", title: "Screen Memory", icon: "eye.fill", tint: Design.slate)],
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
                case "agent": ScrollView { AgentPane() }
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
    @AppStorage("settingsPane") private var pane = "meetings"

    var body: some View {
        PageBody {
            CardSection(title: "Recording", footer: "Zoom, Teams, Meet, Slack and FaceTime calls. Records the call audio and your mic. To record any time: menu bar icon → Record Meeting.") {
                CardRow(title: "Ask to record when a call starts", last: true) {
                    InkToggle(isOn: $ask)
                }
            }
            CardSection(title: "Transcripts", footer: "Gemini writes them, in Lithuanian or English. Saved in Documents › Butterfly Meetings (menu bar icon → Meeting Notes).") {
                if Keychain.geminiKey == nil {
                    CardRow(title: "Needs a Gemini API key") {
                        Button("Add Key") { pane = "keys" }.buttonStyle(.puffyInk)
                    }
                }
                CardRow(title: "Last meeting", last: true) {
                    Button("Transcribe Again") { Meetings.shared.retranscribeLast() }.buttonStyle(.puffy)
                }
            }
        }
    }
}

// MARK: - API keys

private struct KeysPane: View {
    var body: some View {
        PageBody {
            KeySection(title: "Gemini", footer: "Runs voice commands and writes meeting transcripts. Get one at aistudio.google.com.", prompt: "AIza…",
                       saved: Keychain.geminiKey != nil, save: Keychain.saveGemini)
            KeySection(title: "TypeSafe", footer: "Optional. Jev sorts each request in a quarter second, so opening apps, math and web questions skip the slower agent.", prompt: "ts_…",
                       saved: Keychain.apiKey != nil, save: Keychain.save)
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
        Item(title: "Accessibility", why: "Hotkey, typing, operating apps", pane: "Privacy_Accessibility", granted: { HotkeyMonitor.hasAccessibility }),
        Item(title: "Microphone", why: "Hearing what you say", pane: "Privacy_Microphone",
             granted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
             request: { guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
                        _ = await AVCaptureDevice.requestAccess(for: .audio) }),
        Item(title: "Speech Recognition", why: "On-device transcription", pane: "Privacy_SpeechRecognition",
             granted: { SFSpeechRecognizer.authorizationStatus() == .authorized },
             request: { guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
                        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } } }),
        Item(title: "Screen Recording", why: "Screen memory and reading the screen", pane: "Privacy_ScreenCapture",
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
                    CardRow(title: item.title, last: i == Self.items.count - 1) {
                        HStack(spacing: 8) {
                            Text(item.why).secondaryText()
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
    @State private var appCount = AppCatalog.shared.apps.count

    var body: some View {
        PageBody {
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

// MARK: - Vocabulary, Agent, Screen Memory

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

/// agent-desktop (vercel-labs): the hands for voice commands.
private struct AgentPane: View {
    @State private var status = "Checking…"
    @State private var ok = false
    var body: some View {
        PageBody {
            CardSection(title: "agent-desktop", footer: "Voice commands are carried out by a Gemini agent that operates your apps through agent-desktop (accessibility tree). Install: npm i -g agent-desktop") {
                CardRow(title: status) {
                    if ok { Tag(text: "Ready", tint: Design.green) }
                    else { Button("Copy install command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("npm i -g agent-desktop", forType: .string) }.buttonStyle(.puffy) }
                }
                CardRow(title: "Agent log", last: true) {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Butterfly/agent.log")]) }.buttonStyle(.puffy)
                }
            }
        }
        .task {
            guard let bin = DesktopAgent.binary else { status = "Not installed"; return }
            let v = await DesktopAgent.cli(["version"])
            let ver = (try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [String: Any]).flatMap { ($0["data"] as? [String: Any])?["version"] as? String }
            ok = ver != nil
            status = ver.map { "Version \($0) · \((bin as NSString).abbreviatingWithTildeInPath)" } ?? "Installed but not responding"
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
