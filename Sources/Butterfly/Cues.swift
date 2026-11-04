import AppKit

/// Short sounds when listening starts and stops. Off in Settings → System → Sounds.
@MainActor
enum Cues {
    private static func load(_ name: String, volume: Float) -> NSSound? {
        let s = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        s?.volume = volume
        return s
    }
    private static let start = load("Tink", volume: 0.35)
    private static let stop = load("Pop", volume: 0.3)

    static var enabled: Bool { UserDefaults.standard.object(forKey: "listeningSounds") as? Bool ?? true }

    static func listening() { play(start) }
    static func stopped() { play(stop) }

    private static let queue = DispatchQueue(label: "butterfly.cues", qos: .userInitiated)

    /// Off the main thread: with AirPods, play() blocks ~0.7 s while they switch to mic mode.
    private static func play(_ s: NSSound?) {
        guard enabled, let s else { return }
        nonisolated(unsafe) let sound = s
        queue.async { sound.stop(); sound.play() }
    }
}

/// Turns music down while listening and back up after. Only when something is playing.
@MainActor
enum Ducker {
    private static var original: Int?
    private static var lowered: Int?
    private static var fade: Task<Void, Never>?

    static var enabled: Bool { UserDefaults.standard.object(forKey: "duckMusic") as? Bool ?? true }

    static func duck() {
        guard enabled, original == nil, NowPlaying.shared.track?.playing == true else { return }
        let v = SystemController.Audio.volume
        guard v > 8 else { return }
        let target = max(4, v * 35 / 100)
        original = v
        lowered = target
        ramp(from: v, to: target)
    }

    static func restore() {
        guard let o = original, let l = lowered else { return }
        original = nil; lowered = nil
        // Volume changed while listening ("volume up", keys): keep what you chose.
        guard fade != nil || SystemController.Audio.volume == l else { return }
        ramp(from: l, to: o)
    }

    /// ~150 ms in 5 steps, so it doesn't jump.
    private static func ramp(from a: Int, to b: Int) {
        fade?.cancel()
        fade = Task {
            for i in 1...5 {
                guard !Task.isCancelled else { return }
                _ = osaVolume(a + (b - a) * i / 5)
                try? await Task.sleep(for: .milliseconds(30))
            }
            fade = nil
        }
    }

    private static func osaVolume(_ v: Int) -> Int { SystemController.Audio.setVolume(v) }
}
