import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel
    private var closed: CGSize { _ = model.screenID; return NotchMetrics.closedSize }

    private var isOpen: Bool { model.phase != .idle }
    private var size: CGSize {
        isOpen ? .init(width: max(closed.width + 220, 420), height: closed.height + 64) : closed
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(top: isOpen ? 19 : 6, bottom: isOpen ? 24 : 14)
                    .fill(.black)
                    .shadow(color: .black.opacity(isOpen ? 0.55 : 0), radius: 10, y: 4)

                if isOpen {
                    content
                        .padding(.top, closed.height)
                        .padding(.horizontal, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)).combined(with: .offset(y: -8)))
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(isOpen || NotchMetrics.hasNotch ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: NotchPanel.size.width, height: NotchPanel.size.height)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isOpen)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 12) {
            leading.frame(minWidth: 28, maxHeight: 28).fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
                Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
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
        case .system(let symbol, _, _):
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .unsure(nil), .message:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
        case .idle:
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
        case .listening: model.transcript.isEmpty ? (model.isLocked ? "Listening for commands…" : "Listening…") : model.transcript
        case .thinking: model.transcript
        case .opened(let targets, _): "Opening " + Self.list(targets.map(Self.name))
        case .media(_, let title, _): title
        case .system(_, let title, _): title
        case .unsure(let app?): "Did you mean \(app.name)?"
        case .unsure(nil): "Didn’t catch that"
        case .message(let text): text
        case .idle: ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .listening: model.isLocked ? "Locked · tap ⌥ to stop" : "Release ⌥ to run"
        case .thinking: "Jev is deciding…"
        case .unsure: "Say it again a bit clearer"
        case .opened(_, let detail): detail
        case .media(_, _, let detail): detail
        case .system(_, _, let detail): detail
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
    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + levels[i] * 18)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
