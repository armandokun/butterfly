import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var timers = Timers.shared
    private var closed: CGSize { _ = model.screenID; return NotchMetrics.closedSize }
    private var island: Bool { _ = model.screenID; return !NotchMetrics.hasNotch }

    /// DynamicNotch-style presentations: closed notch → compact live activity → expanded.
    private enum Presentation: Hashable { case closed, compact, expanded }
    private var presentation: Presentation {
        switch model.phase {
        case .idle: playingIdle || timerIdle ? .compact : .closed
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
    /// Answer card height: grows with the text, up to ~6 lines.
    private var answerHeight: CGFloat {
        guard let a = answer else { return 0 }
        let lines = a.text.split(separator: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 68))) }
        return 44 + CGFloat(min(6, lines)) * 21
    }

    private var compactExtra: CGFloat {
        if case .level = model.phase { return 150 }
        if case .badge(_, let text, _) = model.phase { return min(260, 70 + CGFloat(text.count) * 7.5 * 2) }
        if timerIdle { return 110 }
        return playingIdle ? 80 : 92
    }

    private var size: CGSize {
        switch (presentation, island) {
        case (.closed, false): closed
        case (.compact, false): .init(width: closed.width + compactExtra, height: closed.height)
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
                            else { content }
                        }
                        .padding(.top, island ? (isPlayer || answer != nil ? 14 : 0) : closed.height + (isPlayer ? 8 : answer != nil ? 4 : 0))
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
            .opacity(presentation != .closed || !island ? 1 : 0)
            .scaleEffect(presentation == .closed && island ? 0.6 : 1, anchor: .top)
            .offset(y: island ? 4 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: NotchPanel.size.width, height: NotchPanel.size.height)
        .animation(.spring(response: 0.47, dampingFraction: 0.7, blendDuration: 1), value: presentation)
        .animation(.spring(response: 0.47, dampingFraction: 0.7, blendDuration: 1), value: island)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .preferredColorScheme(.dark)
    }

    private var compactKind: String {
        if case .level = model.phase { return "level" }
        if case .badge(let s, _, _) = model.phase { return "badge-\(s)" }
        if timerIdle { return "timer" }
        return playingIdle ? "music" : "listen"
    }

    /// Live activity: something left of the notch, something right of it.
    @ViewBuilder private var compact: some View {
        HStack(spacing: 0) {
            switch model.phase {
            case .idle:
                if let t = timers.next {
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
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .modifier(Shimmer(active: isWorking))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .truncationMode(.head)
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
            ProgressView().controlSize(.small).tint(.white)
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
            Image(nsImage: app.icon).resizable().opacity(0.5)
        case .media(let app?, _, _):
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
        case .media(nil, _, _):
            Image(systemName: "music.note").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
        case .system(let symbol, let title, _) where title.hasSuffix("…"):
            WorkingIcon(symbol: symbol)
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
        case .idle, .answer:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if model.phase == .listening {
            Waveform(levels: model.levels)
        } else if case .system(_, let title, _) = model.phase, title.hasSuffix("…") {
            Elapsed()
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
        case .level(let k, let v): "\(k == .volume ? "Volume" : "Brightness") \(v)%"
        case .nowPlaying: music.track?.title ?? ""
        case .timerDone: "Time’s up"
        case .badge(_, let text, _): text
        case .answer(let t, _): t
        case .idle: ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .listening: model.isLocked ? (model.dictationOnly ? "Dictating · tap ⌥ to stop" : "Locked · tap ⌥ to stop") : model.dictationOnly ? "Dictating · release to type" : "Release ⌥ to run"
        case .thinking: "Jev is deciding…"
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

/// Busy icon: the symbol breathes inside a spinning gradient ring (Apple Intelligence colors).
private struct WorkingIcon: View {
    let symbol: String
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(AngularGradient(colors: [.purple, .pink, .orange, .yellow, .cyan, .purple], center: .center), style: .init(lineWidth: 2, lineCap: .round))
                .frame(width: 26, height: 26)
                .mask(Circle().trim(from: 0, to: 0.72).stroke(lineWidth: 3).frame(width: 26, height: 26))
                .rotationEffect(.degrees(spin ? 360 : 0))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        }
        .frame(width: 28, height: 28)
        .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true } }
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
