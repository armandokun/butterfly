import SwiftUI

/// Countdown ring (fills as time passes).
struct TimerRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress).stroke(.orange, style: .init(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

/// Album art with a soft corner; music note when the app gives none.
struct Artwork: View {
    let image: NSImage?
    var size: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// DynamicNotch's equalizer bars: bounce while playing, settle flat when paused.
struct Equalizer: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 4 + 9 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i))) : 3
                    Capsule().fill(.white).frame(width: 3, height: h)
                }
            }
            .frame(width: 20, height: 14)
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }
}

/// Expanded Now Playing: artwork, title, artist, progress. Display only: you control it by voice.
struct PlayerCard: View {
    let track: NowPlaying.Track

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: track.artwork, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if let artist = track.artist {
                        Text(artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if let app = track.app {
                    Image(nsImage: app.icon).resizable().frame(width: 20, height: 20).opacity(0.85)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                ProgressLine(track: track)
            }
        }
    }
}

private struct ProgressLine: View {
    let track: NowPlaying.Track
    var body: some View {
        let p = track.progress ?? 0
        HStack(spacing: 8) {
            Text(Self.time(track.duration.map { $0 * p })).frame(width: 34, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * p) }
            }
            .frame(height: 4)
            Text(Self.time(track.duration)).frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }
    static func time(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "--:--" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
