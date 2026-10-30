import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var timers = Timers.shared
    @State private var clock = Date()   // coarse tick so the recording pill can widen as the time gets longer
    private var closed: CGSize { _ = model.screenID; return NotchMetrics.closedSize }
    private var island: Bool { _ = model.screenID; return !NotchMetrics.hasNotch }

    /// DynamicNotch-style presentations: closed notch → compact live activity → expanded.
    private enum Presentation: Hashable { case closed, compact, expanded }
    private var presentation: Presentation {
        switch model.phase {
        case .idle: playingIdle || timerIdle || (model.recording != nil && model.recordingBadge) || model.transcribing != nil ? .compact : .closed
        case .listening where model.transcript.isEmpty: .compact   // just widen beside the notch
        case .level: .compact
        case .badge: .compact
        default: .expanded
        }
    }
    /// Idle + music playing: artwork left of the notch, equalizer right (DynamicNotch's "live activity").
    private var playingIdle: Bool { false }   // no persistent mini player: lean notch
    private var timerIdle: Bool { model.phase == .idle && timers.next != nil }
    private var isPlayer: Bool { model.phase == .nowPlaying && music.track != nil }
    private var answer: (title: String, text: String)? {
        if case .answer(let t, let x) = model.phase { return (t, x) }
        return nil
    }
    /// Calendar widget / playlist tiles: bigger cards with their own height.
    private var cardHeight: CGFloat? {
        switch model.phase {
        case .agenda(_, let ev, let more):
            AgendaCard.height(allDay: ev.filter(\.allDay).count, timed: ev.filter { !$0.allDay }.count, more: more)
        case .recap(_, _, let items): RecapCard.height(items: items.count)
        case .playlists: 168
        case .meetingPrompt, .recordingCard, .transcriptReady, .stopPrompt: 62
        default: nil
        }
    }
    /// Answer card height: grows with the text, up to ~6 lines.
    private var answerHeight: CGFloat {
        guard let a = answer else { return 0 }
        let lines = a.text.split(separator: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 68))) }
        return 44 + CGFloat(min(6, lines)) * 21
    }

    private var compactExtra: CGFloat {
        if case .level = model.phase { return 150 }
        if case .badge(_, let text, _) = model.phase { return min(260, 70 + CGFloat(text.count) * 7.5 * 2) }
        if model.phase == .idle, model.recordingBadge, let r = model.recording {
            // Room grows with the clock: 4:38 → 18:38 → 1:08:38 (otherwise the digits slide under the notch).
            let digits = Timers.format(clock.timeIntervalSince(r.since)).count
            return 150 + CGFloat(max(0, digits - 4)) * 18
        }
        if model.phase == .idle, model.transcribing != nil { return 250 }
        if timerIdle { return 110 }
        return playingIdle ? 80 : 92
    }

    private var size: CGSize {
        switch (presentation, island) {
        case (.closed, false): closed
        case (.compact, false): .init(width: closed.width + compactExtra, height: closed.height)
        case (.expanded, false) where cardHeight != nil: .init(width: max(closed.width + 300, 520), height: closed.height + cardHeight! + 10)
        case (.expanded, true) where cardHeight != nil: .init(width: 500, height: cardHeight! + 26)
        case (.expanded, false) where answer != nil: .init(width: max(closed.width + 300, 520), height: closed.height + answerHeight + 14)
        case (.expanded, true) where answer != nil: .init(width: 500, height: answerHeight + 30)
        case (.expanded, false): isPlayer ? .init(width: closed.width + 200, height: closed.height + 96)
                                          : .init(width: max(closed.width + 220, 420), height: closed.height + 64)
        case (.closed, true): .init(width: 120, height: 32)
        case (.compact, true): .init(width: 150 + compactExtra * 0.6, height: 34)
        case (.expanded, true): isPlayer ? .init(width: 380, height: 112) : .init(width: 400, height: 72)
        }
    }

    /// (top flare, bottom corner); for the island, `bottom` is the pill radius.
    private var radii: (top: CGFloat, bottom: CGFloat) {
        switch (presentation, island) {
        case (.expanded, false): isPlayer ? (24, 36) : (18, 28)
        case (_, false): (max(4, closed.height / 3 - 4), closed.height / 3 + 2)
        case (.expanded, true): (0, isPlayer ? 34 : 26)
        case (_, true): (0, size.height / 2)
        }
    }

    private var shape: SurfaceShape { SurfaceShape(island: island, top: radii.top, bottom: radii.bottom) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(.black)
                    .overlay { if island { shape.stroke(.white.opacity(0.12), lineWidth: 1) } }
                    .shadow(color: .black.opacity(presentation == .expanded ? 0.35 : 0), radius: 20, y: 6)

                Group {
                    switch presentation {
                    case .closed: EmptyView()
                    case .compact:
                        compact.transition(.notch(expanded: false, lift: 0))
                    case .expanded:
                        Group {
                            if isPlayer, let t = music.track { PlayerCard(track: t) }
                            else if let a = answer { AnswerCard(title: a.title, text: a.text) }
                            else if case .agenda(let day, let ev, let more) = model.phase { AgendaCard(day: day, events: ev, more: more) }
                            else if case .recap(let t, let r, let items) = model.phase { RecapCard(title: t, range: r, items: items) }
                            else if case .playlists(let t, let items) = model.phase { PlaylistCard(title: t, items: items) }
                            else if case .meetingPrompt(let app) = model.phase { MeetingPromptCard(app: app, answer: model.answerMeeting) }
                            else if model.phase == .recordingCard, let r = model.recording { RecordingCard(recording: r, stop: model.stopRecording) }
                            else if case .stopPrompt(let app) = model.phase { StopPromptCard(app: app, since: model.recording?.since, answer: model.answerStop) }
                            else if case .transcriptReady(let t, let file) = model.phase { TranscriptReadyCard(title: t) { model.openTranscript(file) } }
                            else { content }
                        }
                        .padding(.top, island ? (isPlayer || answer != nil || cardHeight != nil ? 14 : 0) : closed.height + (isPlayer ? 8 : answer != nil || cardHeight != nil ? 4 : 0))
                        .padding(.horizontal, island ? 22 : 30)
                        .padding(.bottom, isPlayer ? 16 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.notch(expanded: true, lift: 48))
                    }
                }
                .id(presentation == .compact ? "compact-\(compactKind)" : "\(presentation)")
                .mask { shape.padding(.horizontal, island ? 0 : 4).padding(.bottom, 2) }
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: size, initial: true) { _, s in NotchPanel.visible = s }
            // Idle: nothing drawn. The hardware notch hides it anyway, but screenshots and other screens showed a black bar.
            .opacity(presentation != .closed ? 1 : 0)
            .scaleEffect(presentation == .closed && island ? 0.6 : 1, anchor: .top)
            .offset(y: island ? 4 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: NotchPanel.size.width, height: NotchPanel.size.height)
        .animation(.spring(response: 0.47, dampingFraction: 0.7, blendDuration: 1), value: presentation)
        .animation(.spring(response: 0.47, dampingFraction: 0.7, blendDuration: 1), value: island)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .animation(.smooth(duration: 0.3), value: clock)
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { now in if model.recording != nil { clock = now } }
        .onChange(of: model.recording?.since) { _, _ in clock = Date() }
        .preferredColorScheme(.dark)
    }

    private var compactKind: String {
        if case .level = model.phase { return "level" }
        if case .badge(let s, _, _) = model.phase { return "badge-\(s)" }
        if timerIdle { return "timer" }
        if model.phase == .idle, model.recordingBadge, model.recording != nil { return "recording" }
        if model.phase == .idle, model.transcribing != nil { return "transcribing" }
        return playingIdle ? "music" : "listen"
    }

    /// Live activity: something left of the notch, something right of it.
    @ViewBuilder private var compact: some View {
        HStack(spacing: 0) {
            switch model.phase {
            case .idle:
                if model.recordingBadge, let r = model.recording {
                    ButterflyMark(size: island ? 18 : closed.height - 14)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Timers.format(ctx.date.timeIntervalSince(r.since)))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                        }
                        RecordingBars()
                    }
                } else if model.transcribing != nil {
                    ButterflyMark(size: island ? 18 : closed.height - 14)
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        Text("Transcribing").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        ProgressView().controlSize(.mini).tint(.orange)
                    }
                } else if let t = timers.next {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 0) {
                            TimerRing(progress: t.progress).frame(width: 16, height: 16)
                            Spacer(minLength: 0)
                            Text(Timers.format(t.remaining))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.default, value: Int(t.remaining))
                        }
                    }
                } else if let t = music.track {
                    Artwork(image: t.artwork, size: island ? 22 : closed.height - 12)
                    Spacer(minLength: 0)
                    Equalizer(playing: t.playing)
                }
            case .badge(let symbol, let text, let tint):
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 22, alignment: .leading)
                Spacer(minLength: 0)
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: compactExtra / 2 - 18, alignment: .trailing)
            case .level(let kind, let v):
                Image(systemName: kind.symbol(for: v))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, alignment: .leading)
                if island {
                    Text("\(v)%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        .padding(.leading, 6).contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                LevelBar(level: v, width: island ? 64 : 54)
            default:
                leading.frame(width: 20, height: 20)
                Spacer(minLength: 0)
                Waveform(levels: Array(model.levels.suffix(5)), maxHeight: 12)
            }
        }
        .padding(.horizontal, island ? 16 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 12) {
            leading.frame(minWidth: 28, maxHeight: 28).fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 2) {
                if model.phase == .listening, !model.transcript.isEmpty {
                    LiveTranscript(text: model.transcript)
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .modifier(Shimmer(active: isWorking))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .contentTransition(.opacity)
            Spacer(minLength: 8)
            trailing
        }
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .listening:
            if model.isLocked {
                Image(systemName: model.dictationOnly ? "character.cursor.ibeam" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(model.dictationOnly ? .blue : .white)
            } else if model.dictationOnly {
                Image(systemName: "character.cursor.ibeam").font(.system(size: 15, weight: .semibold)).foregroundStyle(.blue)
            } else {
                PulsingDot()
            }
        case .thinking:
            OrbitSparkles()
        case .opened(let targets, _):
            HStack(spacing: -6) {
                ForEach(targets, id: \.self) { target in
                    switch target {
                    case .app(let app):
                        Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                    case .site(let url):
                        Favicon(host: url.host() ?? "").frame(width: 24, height: 24).padding(2)
                    }
                }
            }
        case .unsure(let app?):
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
        case .media(let app?, _, _):
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
        case .media(nil, _, _):
            Image(systemName: "music.note").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
        case .system(let symbol, let title, _) where title.hasSuffix("…"):
            OrbitSparkles(symbol: symbol)
        case .system(let symbol, _, _):
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .unsure(nil), .message:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
        case .level(let k, let v):
            Image(systemName: k.symbol(for: v)).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
        case .nowPlaying:
            EmptyView()
        case .timerDone:
            Image(systemName: "timer").font(.system(size: 20, weight: .semibold)).foregroundStyle(.orange)
        case .badge(let s, _, let tint):
            Image(systemName: s).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
        case .idle, .answer, .agenda, .recap, .playlists, .meetingPrompt, .recordingCard, .transcriptReady, .stopPrompt:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.phase == .listening {
            Waveform(levels: model.levels)
        } else if case .system(_, let title, _) = model.phase, title.hasSuffix("…") {
            Elapsed()
        } else if model.feedbackRun != nil {
            HStack(spacing: 6) {
                Button("👍") { model.feedback(true) }.buttonStyle(NotchButton(fill: .white.opacity(0.14), ink: .white)).hotspot("feedback.up") { model.feedback(true) }
                Button("👎") { model.feedback(false) }.buttonStyle(NotchButton(fill: .white.opacity(0.14), ink: .white)).hotspot("feedback.down") { model.feedback(false) }
            }
            .onDisappear { NotchPanel.hotspots["feedback.up"] = nil; NotchPanel.hotspots["feedback.down"] = nil }
        }
    }

    /// Long waits ("Working on it…", "Reading the screen…"): shimmering title so it never looks frozen.
    private var isWorking: Bool {
        if case .system(_, let title, _) = model.phase { return title.hasSuffix("…") }
        return model.phase == .thinking
    }

    private var title: String {
        switch model.phase {
        case .listening: model.transcript.isEmpty ? (model.isLocked ? "Listening for commands…" : "Listening…") : model.transcript
        case .thinking: model.transcript
        case .opened(let targets, _): "Opening " + Self.list(targets.map(Self.name))
        case .media(_, let title, _): title
        case .system(_, let title, _): title
        case .unsure(let app?): "Did you mean \(app.name)?"
        case .unsure(nil): "Didn’t catch that"
        case .message(let text): text
        case .level(let k, let v): "\(k.label) \(v)%"
        case .nowPlaying: music.track?.title ?? "Nothing is playing"
        case .timerDone: "Time’s up"
        case .badge(_, let text, _): text
        case .answer(let t, _): t
        case .agenda: "Calendar"
        case .recap(let t, _, _): t
        case .playlists(let t, _): t
        case .meetingPrompt: "Record this meeting?"
        case .recordingCard: "Recording"
        case .transcriptReady: "Transcript ready"
        case .stopPrompt: "Call ended?"
        case .idle: ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .listening: model.isLocked ? (model.dictationOnly ? "Dictating · tap ⌥ to stop" : "Locked · tap ⌥ to stop") : model.dictationOnly ? "Dictating · release to type" : "Release ⌥ to run"
        case .thinking: "Working on it…"
        case .unsure: "Say it again a bit clearer"
        case .opened(_, let detail): detail
        case .media(_, _, let detail): detail
        case .system(_, _, let detail): detail
        case .timerDone(let label): label
        default: nil
        }
    }

    private static func name(_ t: WindowManager.Target) -> String {
        switch t {
        case .app(let a): a.name
        case .site(let u): u.host() ?? u.absoluteString
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " & " + names.last!
    }
}

/// "Record this meeting?" · Not now / Record. Shown when a call starts; no answer in 30 s = not recorded.
private struct MeetingPromptCard: View {
    let app: String
    let answer: (Bool) -> Void
    private var icon: NSImage? {
        let name = app.replacingOccurrences(of: " call", with: "")
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
    }
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 34, height: 34) }
                else { Image(systemName: "video.fill").font(.system(size: 20)).foregroundStyle(.white).frame(width: 34, height: 34) }
                Circle().fill(.red).frame(width: 11, height: 11).overlay(Circle().stroke(.black, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Record this meeting?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(app).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Not now") { answer(false) }
                .buttonStyle(NotchButton(fill: .white.opacity(0.14), ink: .white))
                .hotspot("meeting.no") { answer(false) }
            Button { answer(true) } label: { Label("Record", systemImage: "record.circle.fill") }
                .buttonStyle(NotchButton(fill: .red, ink: .white))
                .hotspot("meeting.yes") { answer(true) }
        }
        .frame(maxHeight: .infinity)
        .onDisappear { NotchPanel.hotspots["meeting.yes"] = nil; NotchPanel.hotspots["meeting.no"] = nil }
    }
}

extension View {
    /// Registers this view's frame (in the notch panel) as a click target, see `NotchPanel.sendEvent`.
    func hotspot(_ id: String, action: @escaping () -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { NotchPanel.hotspots[id] = (g.frame(in: .global), action) }
                .onChange(of: g.frame(in: .global)) { _, f in NotchPanel.hotspots[id] = (f, action) }
        })
    }
}

/// Hover the recording pill: app, elapsed time, Stop.
private struct RecordingCard: View {
    let recording: NotchModel.Recording
    let stop: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ButterflyMark(size: 26).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Recording · \(Timers.format(ctx.date.timeIntervalSince(recording.since)))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                }
                Text(recording.app).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            RecordingBars()
            Button { stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(NotchButton(fill: .red, ink: .white))
                .hotspot("recording.stop") { stop() }
        }
        .frame(maxHeight: .infinity)
        .onDisappear { NotchPanel.hotspots["recording.stop"] = nil }
    }
}

/// The Butterfly mark (menu bar glyph), white.
private struct ButterflyMark: View {
    var size: CGFloat = 18
    var body: some View {
        if let img = Bundle.main.image(forResource: "menubar") {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .foregroundStyle(.white).frame(width: size, height: size)
        } else {
            Image(systemName: "waveform").foregroundStyle(.white)
        }
    }
}

/// Red level bars that move with the call's sound (anyone speaking).
private struct RecordingBars: View {
    private static let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let level = CGFloat(Meetings.shared.level)
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(Self.shape.indices, id: \.self) { i in
                    // Idle: a low flicker so it still reads as "live"; speaking: tall, varied bars.
                    let wobble = 0.55 + 0.45 * abs(sin(t * 7 + Double(i) * 1.7))
                    Capsule().fill(.red)
                        .frame(width: 2.5, height: 4 + Self.shape[i] * (2 + level * 12 * wobble))
                }
            }
            .frame(height: 18)
            .animation(.easeOut(duration: 0.1), value: level)
        }
    }
}

/// The call app let go of the mic: "Call ended?" · Keep recording / Stop.
private struct StopPromptCard: View {
    let app: String
    let since: Date?
    let answer: (Bool) -> Void
    var body: some View {
        HStack(spacing: 12) {
            ButterflyMark(size: 26).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Call ended?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(since.map { "\(app) · \(Timers.format(ctx.date.timeIntervalSince($0))) recorded" } ?? app)
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Keep recording") { answer(false) }
                .buttonStyle(NotchButton(fill: .white.opacity(0.14), ink: .white))
                .hotspot("stop.keep") { answer(false) }
            Button { answer(true) } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(NotchButton(fill: .red, ink: .white))
                .hotspot("stop.stop") { answer(true) }
        }
        .frame(maxHeight: .infinity)
        .onDisappear { NotchPanel.hotspots["stop.keep"] = nil; NotchPanel.hotspots["stop.stop"] = nil }
    }
}

/// After a meeting: "Transcript ready" · Open.
private struct TranscriptReadyCard: View {
    let title: String
    let open: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ButterflyMark(size: 26).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript ready").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { open() } label: { Label("Open", systemImage: "doc.text") }
                .buttonStyle(NotchButton(fill: .white, ink: .black))
                .hotspot("transcript.open") { open() }
        }
        .frame(maxHeight: .infinity)
        .onDisappear { NotchPanel.hotspots["transcript.open"] = nil }
    }
}

/// Red recording light, gently pulsing.
private struct RecordingDot: View {
    var size: CGFloat = 9
    @State private var on = false
    var body: some View {
        Circle().fill(.red).frame(width: size, height: size)
            .shadow(color: .red.opacity(0.8), radius: on ? 4 : 1)
            .opacity(on ? 1 : 0.55)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}

private struct NotchButton: ButtonStyle {
    let fill: Color, ink: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
    }
}

/// Site's own favicon (we're opening the site anyway); globe until it loads.
private struct Favicon: View {
    let host: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "globe").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .task(id: host) {
            guard let url = URL(string: "https://\(host)/favicon.ico"),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = NSImage(data: data)
        }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .shadow(color: .red.opacity(0.8), radius: on ? 6 : 2)
            .scaleEffect(on ? 1.15 : 0.85)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    var maxHeight: CGFloat = 18
    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + levels[i] * maxHeight)
            }
        }
        .frame(height: maxHeight + 4)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// "What did I do in the last five minutes?" — a timeline: period header, then one row per activity with
/// time, the app's icon and a short line. Same bones as the calendar card.
private struct RecapCard: View {
    let title: String
    let range: String
    let items: [NotchModel.RecapItem]

    static let header: CGFloat = 34, row: CGFloat = 24, gap: CGFloat = 8
    static func height(items: Int) -> CGFloat { header + gap + CGFloat(items) * row + CGFloat(max(0, items - 1)) * 4 + 10 }

    private func icon(_ app: String) -> NSImage? {
        AppCatalog.shared.apps.first { $0.name.caseInsensitiveCompare(app) == .orderedSame }?.icon
            ?? NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame }?.icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(range).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("\(items.count) \(items.count == 1 ? "activity" : "activities")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(height: Self.header)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    let it = items[i]
                    HStack(spacing: 8) {
                        Text(it.time)
                            .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 44, alignment: .leading)
                        // Thread line: dot per activity, joined top to bottom.
                        ZStack {
                            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                                .padding(.top, i == 0 ? Self.row / 2 : 0).padding(.bottom, i == items.count - 1 ? Self.row / 2 : 0)
                            Circle().fill(.white.opacity(0.7)).frame(width: 5, height: 5)
                        }
                        .frame(width: 8, height: Self.row + 4)
                        if let img = icon(it.app) {
                            Image(nsImage: img).resizable().interpolation(.high).frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4)).frame(width: 18, height: 18)
                        }
                        Text(it.text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.row)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// DynamicNotch-style expanded card: a header row, then either event rows (agenda) or a short paragraph (answers).
/// Agenda lines are "time  title" (two spaces).
private struct AnswerCard: View {
    let title: String
    let text: String

    private var rows: [(time: String, title: String)]? {
        let lines = text.split(separator: "\n").map(String.init)
        let parsed = lines.compactMap { l -> (String, String)? in
            guard let r = l.range(of: "  ") else { return l.hasPrefix("+") ? ("", l) : nil }
            return (String(l[..<r.lowerBound]), String(l[r.upperBound...]))
        }
        return parsed.count == lines.count ? parsed : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: rows == nil ? "sparkles" : "calendar")
                    .foregroundStyle(rows == nil ? AnyShapeStyle(LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(.red))
                Text(title).foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold))

            if let rows {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        HStack(spacing: 10) {
                            Capsule().fill(r.time.isEmpty ? .clear : r.time == "All day" ? Color.orange : Color.red)
                                .frame(width: 3, height: 16)
                            Text(r.time)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 52, alignment: .leading)
                            Text(r.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(r.time.isEmpty ? .white.opacity(0.5) : .white)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(6)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Busy icon: sparkles circling an invisible orbit, tilted so they swing nearer (bigger, brighter) and farther (smaller, dimmer).
/// With a symbol (e.g. a magnifier), it sits still in the middle while the sparkles orbit it.
private struct OrbitSparkles: View {
    var symbol: String? = nil
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let a = t * 2.4 + Double(i) * 2 * .pi / 3
                    let depth = (sin(a) + 1) / 2                  // 0 far · 1 near
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(0.45 + depth * 0.75)
                        .opacity(0.35 + depth * 0.65)
                        .rotationEffect(.radians(a * 0.5))
                        .offset(x: cos(a) * 10, y: sin(a) * 4)    // flat ellipse = a tilted circle
                        .zIndex(depth)
                }
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).zIndex(0.5)
                }
            }
            .frame(width: 28, height: 28)
        }
    }
}

/// Seconds since it started: proof it's still going.
private struct Elapsed: View {
    @State private var start = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text("\(Int(ctx.date.timeIntervalSince(start)))s")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .contentTransition(.numericText())
        }
    }
}

/// A light band sweeping across the text.
/// Live transcript as a ticker: each word fades and slides in from the right, and the line glides left
/// to make room; the oldest words fade out at the left edge.
private struct LiveTranscript: View {
    let text: String

    // Stable ids: a word keeps its id while recognition rewrites later words, so only new/changed words animate.
    private var words: [(id: String, word: String)] {
        text.split(separator: " ").enumerated().map { ("\($0.offset)-\($0.element)", String($0.element)) }
    }

    @State private var lineWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(words, id: \.id) { w in
                    Text(w.word)
                        .fixedSize()
                        .transition(.asymmetric(
                            insertion: .modifier(active: WordIn(progress: 0), identity: WordIn(progress: 1)),
                            removal: .opacity))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { lineWidth = g.size.width }.onChange(of: g.size.width) { _, w in lineWidth = w } })
            // Short: starts at the left. Longer than the space: slides left so the newest word stays in view.
            .offset(x: min(0, geo.size.width - lineWidth))
            .frame(width: geo.size.width, alignment: .leading)
            .mask(LinearGradient(stops: [.init(color: lineWidth > geo.size.width ? .clear : .black, location: 0),
                                         .init(color: .black, location: 0.12), .init(color: .black, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: text)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: lineWidth)
        }
        .frame(height: 17)
        .clipped()
    }
}

private struct WordIn: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 4)
            .offset(x: (1 - progress) * 10)
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var x: CGFloat = -1
    func body(content: Content) -> some View {
        if !active { content } else {
            content
                .overlay {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: x * g.size.width * 1.5)
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                }
                .opacity(0.85)
                .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { x = 1 } }
        }
    }
}

/// iOS Calendar widget, notch-sized: date tile + day header, all-day events as tinted pills on one line,
/// then one row per timed event (time · color bar · title).
private struct AgendaCard: View {
    let day: Date
    let events: [NotchModel.AgendaItem]
    let more: Int

    static let header: CGFloat = 34, pills: CGFloat = 22, row: CGFloat = 22, gap: CGFloat = 8
    static func height(allDay: Int, timed: Int, more: Int) -> CGFloat {
        header + gap + (allDay > 0 ? pills + gap : 0) + CGFloat(timed) * row + CGFloat(max(0, timed - 1)) * 4 + (more > 0 ? 18 : 0) + 10
    }

    private var allDay: [NotchModel.AgendaItem] { events.filter(\.allDay) }
    private var timed: [NotchModel.AgendaItem] { events.filter { !$0.allDay } }
    private var dayName: String {
        Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInTomorrow(day) ? "Tomorrow" : day.formatted(.dateTime.weekday(.wide))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 10) {
                // Calendar app icon: red weekday over the date.
                VStack(spacing: -1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.black)
                }
                .frame(width: 32, height: 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(dayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(day.formatted(.dateTime.month(.wide).day())).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("\(events.count + more) event\(events.count + more == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(height: Self.header)

            if !allDay.isEmpty {
                HStack(spacing: 6) {
                    ForEach(allDay.indices, id: \.self) { i in
                        let e = allDay[i]
                        Text(e.title)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(e.color.mix(with: .white, by: 0.35))
                            .lineLimit(1)
                            .padding(.horizontal, 8).frame(height: Self.pills)
                            .background(e.color.opacity(0.22), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(timed.indices, id: \.self) { i in
                    let e = timed[i]
                    HStack(spacing: 8) {
                        Text(e.time)
                            .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 44, alignment: .leading)
                        Capsule().fill(e.color).frame(width: 3, height: 14)
                        Text(e.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.row)
                }
                if more > 0 {
                    Text("+\(more) more").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 55).frame(height: 14)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Which playlist?": cover tiles you can pick by name or number.
private struct PlaylistCard: View {
    let title: String
    let items: [NotchModel.PlaylistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list").foregroundStyle(.pink)
                Text(title).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("Say one").foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 11, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        Group {
                            if let art = items[i].artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                            else { LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .overlay(Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.85))) }
                        }
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                                .frame(width: 16, height: 16).background(.black.opacity(0.55), in: Circle()).padding(5)
                        }
                        Text(items[i].name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
