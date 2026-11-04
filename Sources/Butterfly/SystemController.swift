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
        case battery = "battery_status"
        case keyboardOn = "keyboard_light_on", keyboardOff = "keyboard_light_off"
        case keyboardUp = "keyboard_light_up", keyboardDown = "keyboard_light_down", keyboardSet = "keyboard_light_set"

        var isLevel: Bool { self == .volumeSet || self == .brightnessSet || self == .keyboardSet }
    }

    struct Result {
        let symbol: String; let title: String; let detail: String?
        var level: (kind: LevelKind, value: Int)? = nil
    }

    static let actionQuestion = TypeSafeClient.Question.choice("Which system control does the user want?", options: [
        "volume_up": "turn the sound/volume up, louder",
        "volume_down": "turn the sound/volume down, quieter, softer",
        "volume_set": "set the volume to a specific level (a number, percent, half, max, minimum)",
        "mute": "mute the sound, silence the Mac's audio output",
        "unmute": "unmute the sound",
        "brightness_up": "make the screen brighter, brightness up",
        "brightness_down": "make the screen dimmer/darker, brightness down",
        "brightness_set": "set screen brightness to a specific level (a number, percent, half, max, minimum)",
        "keyboard_light_on": "turn the keyboard backlight / keyboard light on ('light up the keyboard', 'keyboard light on')",
        "keyboard_light_off": "turn the keyboard backlight off",
        "keyboard_light_up": "make the keyboard backlight brighter",
        "keyboard_light_down": "make the keyboard backlight dimmer",
        "keyboard_light_set": "set the keyboard backlight to a specific level (a number, percent, half, max)",
        "lock": "lock the screen / lock the Mac",
        "sleep": "put the Mac to sleep",
        "display_off": "turn the display/screen off (but don't sleep the Mac)",
        "screenshot_full": "take a screenshot of the whole screen, or just 'take a screenshot' with no area or window mentioned",
        "screenshot_area": "take a screenshot of a selected area, region, or part of the screen (user wants to select/drag)",
        "screenshot_window": "take a screenshot of a window",
        "empty_trash": "empty the Trash / bin",
        "battery_status": "ASK how much battery is left right now (not showing it in the menu bar), the battery percentage, whether it's charging, or how long the battery will last",
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
            return Result(symbol: v == 0 ? "speaker.slash.fill" : "speaker.wave.\(v < 34 ? 1 : v < 67 ? 2 : 3).fill", title: "Volume \(v)%", detail: nil, level: (.volume, v))
        case .mute:
            Audio.setMuted(true)
            return Result(symbol: "speaker.slash.fill", title: "Muted", detail: nil, level: (.volume, 0))
        case .unmute:
            Audio.setMuted(false)
            return Result(symbol: "speaker.wave.2.fill", title: "Volume \(Audio.volume)%", detail: "Unmuted", level: (.volume, Audio.volume))
        case .brightnessUp, .brightnessDown, .brightnessSet:
            guard let now = Brightness.value else {
                return Result(symbol: "sun.max.trianglebadge.exclamationmark", title: "Can't change brightness", detail: "No built-in display found")
            }
            let step = level ?? 12
            let target = action == .brightnessSet ? (level ?? now) : now + (action == .brightnessUp ? step : -step)
            let v = Brightness.set(target)
            return Result(symbol: v < 50 ? "sun.min.fill" : "sun.max.fill", title: "Brightness \(v)%", detail: nil, level: (.brightness, v))
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
        case .keyboardOn, .keyboardOff, .keyboardUp, .keyboardDown, .keyboardSet:
            guard let now = KeyboardLight.level else {
                return Result(symbol: "keyboard", title: "No keyboard backlight", detail: "This keyboard has no light Butterfly can control")
            }
            let target = switch action {
            case .keyboardOn: level ?? (now > 0 ? max(now, 50) : 75)
            case .keyboardOff: 0
            case .keyboardSet: level ?? now
            default: now + (action == .keyboardUp ? 1 : -1) * (level ?? 20)
            }
            let v = KeyboardLight.set(target)
            return Result(symbol: v == 0 ? "light.min" : "light.max", title: v == 0 ? "Keyboard light off" : "Keyboard light \(v)%", detail: nil, level: (.keyboard, v))
        case .battery:
            guard let b = Battery.now else { return Result(symbol: "powerplug.fill", title: "No battery", detail: "This Mac runs on power") }
            return Result(symbol: Battery.symbol(b), title: "Battery \(b.percent)%", detail: Battery.detail(b))
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

/// Synthesized key presses (needs Accessibility, which Butterfly already has).
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

/// Keyboard backlight. No public API: CoreBrightness's KeyboardBrightnessClient (what Control Center uses).
/// Loaded at runtime; if Apple changes it, the command just reports "no keyboard backlight".
@MainActor
enum KeyboardLight {
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias Auto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    private static var keyboard: UInt64? {
        guard let c = client, c.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")) else { return nil }
        let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        return ids?.first?.uint64Value
    }

    /// 0…100, nil when there's no controllable backlight.
    static var level: Int? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let c = client, let k = keyboard, c.responds(to: sel) else { return nil }
        return Int((unsafeBitCast(c.method(for: sel), to: Get.self)(c, sel, k) * 100).rounded())
    }

    @discardableResult
    static func set(_ percent: Int) -> Int {
        let v = max(0, min(100, percent))
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let c = client, let k = keyboard, c.responds(to: sel) else { return level ?? 0 }
        // Ambient auto-dimming would undo a manual "on" in a bright room: turn it off when setting by voice.
        let auto = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        if c.responds(to: auto) { _ = unsafeBitCast(c.method(for: auto), to: Auto.self)(c, auto, false, k) }
        _ = unsafeBitCast(c.method(for: sel), to: Set.self)(c, sel, Float(v) / 100, k)
        return v
    }
}
