import AppKit
import ApplicationServices

/// Volume, brightness, lock, sleep, screenshots, Trash.
@MainActor
enum SystemController {
    enum Action: String, CaseIterable {
        case volumeUp = "volume_up", volumeDown = "volume_down", volumeSet = "volume_set"
        case mute, unmute
        case brightnessUp = "brightness_up", brightnessDown = "brightness_down", brightnessSet = "brightness_set"
        case lock, sleep
        case displayOff = "display_off"
        case screenshotFull = "screenshot_full", screenshotArea = "screenshot_area", screenshotWindow = "screenshot_window"
        case emptyTrash = "empty_trash"

        var isLevel: Bool { self == .volumeSet || self == .brightnessSet }
    }

    struct Result { let symbol: String; let title: String; let detail: String? }

    static let actionQuestion = TypeSafeClient.Question.choice("Which system control does the user want?", options: [
        "volume_up": "turn the sound/volume up, louder",
        "volume_down": "turn the sound/volume down, quieter, softer",
        "volume_set": "set the volume to a specific level (a number, percent, half, max, minimum)",
        "mute": "mute the sound, silence the Mac's audio output",
        "unmute": "unmute the sound",
        "brightness_up": "make the screen brighter, brightness up",
        "brightness_down": "make the screen dimmer/darker, brightness down",
        "brightness_set": "set screen brightness to a specific level (a number, percent, half, max, minimum)",
        "lock": "lock the screen / lock the Mac",
        "sleep": "put the Mac to sleep",
        "display_off": "turn the display/screen off (but don't sleep the Mac)",
        "screenshot_full": "take a screenshot of the whole screen",
        "screenshot_area": "take a screenshot of a selected area / part of the screen, or a screenshot with no detail given",
        "screenshot_window": "take a screenshot of a window",
        "empty_trash": "empty the Trash / bin",
    ])

    static let levelQuestion = TypeSafeClient.Question.choice("What level (percent) does the user ask for? Speech-to-text may write numbers as words.", options: [
        "none": "no level given",
        "0": "0%, zero, minimum, lowest, off", "10": "10%", "20": "20%", "25": "25%, a quarter", "30": "30%",
        "40": "40%", "50": "50%, half, halfway", "60": "60%", "70": "70%", "75": "75%, three quarters",
        "80": "80%", "90": "90%", "100": "100%, max, maximum, full, all the way",
    ])

    /// A spoken number beats Jev's bucket ("volume 35" → 35, not 30/40).
    static func level(in text: String, jev: String?) -> Int? {
        if let m = text.firstMatch(of: #/(\d{1,3})\s*(?:%|percent)?/#), let n = Int(m.1), n <= 100 { return n }
        return jev.flatMap(Int.init)
    }

    static func perform(_ action: Action, level: Int?) async -> Result {
        switch action {
        case .volumeUp, .volumeDown, .volumeSet:
            let now = Audio.volume
            let step = level ?? 12   // "turn it up by 20" → 20
            let target = action == .volumeSet ? (level ?? now) : now + (action == .volumeUp ? step : -step)
            let v = Audio.setVolume(target)
            return Result(symbol: v == 0 ? "speaker.slash.fill" : "speaker.wave.\(v < 34 ? 1 : v < 67 ? 2 : 3).fill", title: "Volume \(v)%", detail: nil)
        case .mute:
            Audio.setMuted(true)
            return Result(symbol: "speaker.slash.fill", title: "Muted", detail: nil)
        case .unmute:
            Audio.setMuted(false)
            return Result(symbol: "speaker.wave.2.fill", title: "Volume \(Audio.volume)%", detail: "Unmuted")
        case .brightnessUp, .brightnessDown, .brightnessSet:
            guard let now = Brightness.value else {
                return Result(symbol: "sun.max.trianglebadge.exclamationmark", title: "Can't change brightness", detail: "No built-in display found")
            }
            let step = level ?? 12
            let target = action == .brightnessSet ? (level ?? now) : now + (action == .brightnessUp ? step : -step)
            let v = Brightness.set(target)
            return Result(symbol: v < 50 ? "sun.min.fill" : "sun.max.fill", title: "Brightness \(v)%", detail: nil)
        case .lock:
            // Let the notch show first; locking freezes the screen.
            Task { try? await Task.sleep(for: .milliseconds(500)); lockScreen() }
            return Result(symbol: "lock.fill", title: "Locking", detail: nil)
        case .sleep:
            Task { try? await Task.sleep(for: .milliseconds(700)); run("/usr/bin/pmset", ["sleepnow"]) }
            return Result(symbol: "moon.fill", title: "Going to sleep", detail: nil)
        case .displayOff:
            Task { try? await Task.sleep(for: .milliseconds(700)); run("/usr/bin/pmset", ["displaysleepnow"]) }
            return Result(symbol: "display", title: "Display off", detail: nil)
        case .screenshotFull, .screenshotArea, .screenshotWindow:
            // The system shortcuts keep your save location, thumbnail, and sound.
            Task {
                try? await Task.sleep(for: .milliseconds(action == .screenshotFull ? 900 : 300))   // full: wait for the notch to close
                switch action {
                case .screenshotFull: Keys.press(20, flags: [.maskCommand, .maskShift])                     // ⌘⇧3
                case .screenshotArea: Keys.press(21, flags: [.maskCommand, .maskShift])                     // ⌘⇧4
                default:
                    Keys.press(21, flags: [.maskCommand, .maskShift])                                       // ⌘⇧4, then Space
                    try? await Task.sleep(for: .milliseconds(250))
                    Keys.press(49, flags: [])
                }
            }
            let what = action == .screenshotFull ? "Screenshot" : action == .screenshotArea ? "Select an area" : "Click a window"
            return Result(symbol: "camera.viewfinder", title: what, detail: nil)
        case .emptyTrash:
            let n = Int(osa("tell application \"Finder\" to count items of trash") ?? "") ?? 0
            guard n > 0 else { return Result(symbol: "trash", title: "Trash is already empty", detail: nil) }
            _ = osa("tell application \"Finder\" to empty trash")
            return Result(symbol: "trash.fill", title: "Emptied Trash", detail: "\(n) item\(n == 1 ? "" : "s")")
        }
    }

    // MARK: Volume (AppleScript in-process: fast, no extra permission)

    @MainActor enum Audio {
        static var volume: Int { Int(osa("output volume of (get volume settings)") ?? "") ?? 50 }
        @discardableResult static func setVolume(_ v: Int) -> Int {
            let v = min(100, max(0, v))
            _ = osa("set volume output volume \(v) without output muted")
            return v
        }
        static func setMuted(_ m: Bool) { _ = osa("set volume \(m ? "with" : "without") output muted") }
    }

    // MARK: Brightness (DisplayServices, the framework the brightness keys use)

    @MainActor enum Brightness {
        private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        private typealias Set = @convention(c) (UInt32, Float) -> Int32
        private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        private static let get = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        private static let setFn = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

        private static var display: UInt32? {
            var ids = [CGDirectDisplayID](repeating: 0, count: 8)
            var n: UInt32 = 0
            CGGetOnlineDisplayList(8, &ids, &n)
            return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
        }

        static var value: Int? {
            guard let get, let d = display else { return nil }
            var b: Float = 0
            guard get(d, &b) == 0 else { return nil }
            return Int((b * 100).rounded())
        }

        @discardableResult static func set(_ v: Int) -> Int {
            let v = min(100, max(0, v))
            if let setFn, let d = display { _ = setFn(d, Float(v) / 100) }
            return v
        }
    }

    // MARK: Helpers

    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let s = dlsym(h, "SACLockScreenImmediate") {
            unsafeBitCast(s, to: Lock.self)()
        } else {
            Keys.press(12, flags: [.maskCommand, .maskControl])   // ⌃⌘Q
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    @discardableResult
    static func osa(_ source: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
    }
}

/// Synthesized key presses (needs Accessibility, which CTRL already has).
enum Keys {
    static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
