import SwiftUI

/// "4:38", "1:08:38".
enum Duration {
    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @State private var clock = Date()   // coarse tick so the recording pill can widen as the time gets longer
    private var closed: CGSize { _ = model.screenID; return NotchMetrics.closedSize }
    private var island: Bool { _ = model.screenID; return !NotchMetrics.hasNotch }

    /// DynamicNotch-style presentations: closed notch → compact live activity → expanded.
    private enum Presentation: Hashable { case closed, compact, expanded }
    private var presentation: Presentation {
        switch model.phase {
        case .idle: (model.recording != nil && model.recordingBadge) || model.transcribing != nil ? .compact : .closed
        case .listening: .compact   // just widen beside the notch: no live text
        case .badge: .compact
        default: .expanded
        }
    }
    /// Cards with their own height.
    private var cardHeight: CGFloat? {
        switch model.phase {
        case .meetingPrompt, .recordingCard, .transcriptReady, .stopPrompt: 62
        default: nil
        }
    }

    private var compactExtra: CGFloat {
        if case .badge(_, let text, _) = model.phase { return min(260, 70 + CGFloat(text.count) * 7.5 * 2) }
        if model.phase == .idle, model.recordingBadge, let r = model.recording {
            // Room grows with the clock: 4:38 → 18:38 → 1:08:38 (otherwise the digits slide under the notch).
            let digits = Duration.format(clock.timeIntervalSince(r.since)).count
            return 150 + CGFloat(max(0, digits - 4)) * 18
        }
        if model.phase == .idle, model.transcribing != nil { return 250 }
        return 92
    }

    private var size: CGSize {
        switch (presentation, island) {
        case (.closed, false): closed
        case (.compact, false): .init(width: closed.width + compactExtra, height: closed.height)
        case (.expanded, false) where cardHeight != nil: .init(width: max(closed.width + 300, 520), height: closed.height + cardHeight! + 10)
        case (.expanded, true) where cardHeight != nil: .init(width: 500, height: cardHeight! + 26)
        case (.expanded, false): .init(width: max(closed.width + 220, 420), height: closed.height + 64)
        case (.closed, true): .init(width: 120, height: 32)
        case (.compact, true): .init(width: 150 + compactExtra * 0.6, height: 34)
        case (.expanded, true): .init(width: 400, height: 72)
        }
    }

    /// (top flare, bottom corner); for the island, `bottom` is the pill radius.
    private var radii: (top: CGFloat, bottom: CGFloat) {
        switch (presentation, island) {
        case (.expanded, false): (18, 28)
        case (_, false): (max(4, closed.height / 3 - 4), closed.height / 3 + 2)
        case (.expanded, true): (0, 26)
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
                            if case .meetingPrompt(let app) = model.phase { MeetingPromptCard(app: app, answer: model.answerMeeting) }
                            else if model.phase == .recordingCard, let r = model.recording { RecordingCard(recording: r, stop: model.stopRecording) }
                            else if case .stopPrompt(let app) = model.phase { StopPromptCard(app: app, since: model.recording?.since, answer: model.answerStop) }
                            else if case .transcriptReady(let t, let file) = model.phase { TranscriptReadyCard(title: t) { model.openTranscript(file) } }
                            else { content }
                        }
                        .padding(.top, island ? (cardHeight != nil ? 14 : 0) : closed.height + (cardHeight != nil ? 4 : 0))
                        .padding(.horizontal, island ? 22 : 30)
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
        if case .badge(let s, _, _) = model.phase { return "badge-\(s)" }
        if model.phase == .idle, model.recordingBadge, model.recording != nil { return "recording" }
        if model.phase == .idle, model.transcribing != nil { return "transcribing" }
        return "listen"
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
                            Text(Duration.format(ctx.date.timeIntervalSince(r.since)))
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
                }
            case .badge(let symbol, let text, let tint):
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 22, alignment: .leading)
                Spacer(minLength: 0)
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: compactExtra / 2 - 18, alignment: .trailing)
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
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
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
            Image(systemName: model.isLocked ? "lock.fill" : "character.cursor.ibeam")
                .font(.system(size: model.isLocked ? 14 : 15, weight: .semibold)).foregroundStyle(.blue)
        case .system(let symbol, _, _):
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .message:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
        case .badge(let s, _, let tint):
            Image(systemName: s).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
        case .idle, .meetingPrompt, .recordingCard, .transcriptReady, .stopPrompt:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.phase == .listening {
            Waveform(levels: model.levels)
        }
    }

    private var title: String {
        switch model.phase {
        case .listening: "Listening…"
        case .system(_, let title, _): title
        case .message(let text): text
        case .badge(_, let text, _): text
        case .meetingPrompt: "Record this meeting?"
        case .recordingCard: "Recording"
        case .transcriptReady: "Transcript ready"
        case .stopPrompt: "Call ended?"
        case .idle: ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .listening: model.isLocked ? "Dictating · tap ⌥ to stop" : "Dictating · release to type"
        case .system(_, _, let detail): detail
        default: nil
        }
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
                Text("Record this meeting?").displayText(15, color: .white)
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
                    Text("Recording · \(Duration.format(ctx.date.timeIntervalSince(recording.since)))")
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
                Text("Call ended?").displayText(15, color: .white)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(since.map { "\(app) · \(Duration.format(ctx.date.timeIntervalSince($0))) recorded" } ?? app)
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
                Text("Transcript ready").displayText(15, color: .white)
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

/// The puffy pill on black: glossy top highlight, soft inner shade, hairline edge.
private struct NotchButton: ButtonStyle {
    let fill: Color, ink: Color
    var square = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium)).tracking(-0.1).foregroundStyle(ink)
            .padding(.horizontal, square ? 0 : 13).frame(width: square ? 32 : nil, height: 28)
            .background(Capsule()
                .fill(fill.opacity(configuration.isPressed ? 0.7 : 1)
                    .shadow(.inner(color: .white.opacity(0.35), radius: 1, y: 1))
                    .shadow(.inner(color: .black.opacity(0.18), radius: 3, y: -2)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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

