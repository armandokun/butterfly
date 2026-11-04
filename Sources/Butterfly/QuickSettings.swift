import AppKit
import IOBluetooth

/// Settings Butterfly changes itself instead of opening System Settings: "always show the menu bar", "hide the Dock",
/// "turn on Night Shift", "show hidden files"… Each one applies immediately (no logout).
@MainActor
enum QuickSettings {
    struct Setting {
        let key: String
        let title: String         // notch: "<title> on/off"
        let description: String   // what Jev reads
        let get: () -> Bool?
        let set: (Bool) -> Void
    }

    static let all: [Setting] = [
        Setting(key: "menu_bar_always", title: "Menu bar always shown",
                description: "always show / display the menu bar (top bar) at all times, also in full screen; off = auto-hide the menu bar",
                get: { !(globalBool("_HIHideMenuBar") ?? false) && (globalBool("AppleMenuBarVisibleInFullscreen") ?? false) },
                set: { on in
                    setGlobal("AppleMenuBarVisibleInFullscreen", on)
                    osa("tell application \"System Events\" to set autohide menu bar of dock preferences to \(!on)")
                    // What System Settings sends; without it running apps keep the old full-screen behavior.
                    for n in ["AppleInterfaceFullScreenMenuBarVisibilityChangedNotification", "AppleInterfaceMenuBarHidingChangedNotification"] {
                        DistributedNotificationCenter.default().postNotificationName(.init(n), object: nil, userInfo: nil, deliverImmediately: true)
                    }
                }),
        Setting(key: "dock_always", title: "Dock always shown",
                description: "always show the Dock; off = hide the Dock / auto-hide the Dock",
                get: { osa("tell application \"System Events\" to get autohide of dock preferences") == "false" },
                set: { on in osa("tell application \"System Events\" to set autohide of dock preferences to \(!on)") }),
        Setting(key: "dock_magnification", title: "Dock magnification",
                description: "Dock magnification, icons grow when hovered",
                get: { osa("tell application \"System Events\" to get magnification of dock preferences") == "true" },
                set: { on in osa("tell application \"System Events\" to set magnification of dock preferences to \(on)") }),
        Setting(key: "night_shift", title: "Night Shift",
                description: "Night Shift, warmer screen colors, blue light filter",
                get: { NightShift.enabled },
                set: { on in NightShift.set(on) }),
        Setting(key: "bluetooth_power", title: "Bluetooth",
                description: "turn Bluetooth itself on or off (the radio, not a specific device)",
                get: { IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON },
                set: { on in BluetoothPower.set(on) }),
        Setting(key: "desktop_icons", title: "Desktop icons",
                description: "show the files and icons on the desktop (off = hide desktop icons, clean desktop)",
                get: { defaultsBool("com.apple.finder", "CreateDesktop") ?? true },
                set: { on in defaults("com.apple.finder", "CreateDesktop", on); restartFinder() }),
        Setting(key: "hidden_files", title: "Hidden files",
                description: "show hidden files (dotfiles) in Finder",
                get: { defaultsBool("com.apple.finder", "AppleShowAllFiles") ?? false },
                set: { on in defaults("com.apple.finder", "AppleShowAllFiles", on); restartFinder() }),
        Setting(key: "file_extensions", title: "File extensions",
                description: "show all file name extensions (.pdf, .png) in Finder",
                get: { globalBool("AppleShowAllExtensions") ?? false },
                set: { on in setGlobal("AppleShowAllExtensions", on); restartFinder() }),
        Setting(key: "clock_seconds", title: "Seconds in clock",
                description: "show seconds in the menu bar clock",
                get: { defaultsBool("com.apple.menuextra.clock", "ShowSeconds") ?? false },
                set: { on in defaults("com.apple.menuextra.clock", "ShowSeconds", on); restart("ControlCenter") }),
        Setting(key: "battery_percent", title: "Battery percentage",
                description: "show or hide the battery percentage number in the menu bar",
                get: { currentHostBool("com.apple.controlcenter", "BatteryShowPercentage") ?? false },
                set: { on in
                    run("/usr/bin/defaults", ["-currentHost", "write", "com.apple.controlcenter", "BatteryShowPercentage", "-bool", on ? "true" : "false"])
                    restart("ControlCenter")
                }),
        Setting(key: "stage_manager", title: "Stage Manager",
                description: "Stage Manager (window grouping on the side of the screen)",
                get: { defaultsBool("com.apple.WindowManager", "GloballyEnabled") ?? false },
                set: { on in defaults("com.apple.WindowManager", "GloballyEnabled", on) }),
    ]

    static func setting(_ key: String) -> Setting? { all.first { $0.key == key } }

    static let question: TypeSafeClient.Question = {
        var opts = ["none": "none of these: a different setting, or just opening a settings page"]
        for s in all { opts[s.key] = s.description }
        return .choice("Which of these Mac settings does the user want changed?", options: opts)
    }()

    /// `on`: nil = flip it.
    static func apply(_ s: Setting, on: Bool?) -> (title: String, symbol: String) {
        let target = on ?? !(s.get() ?? false)
        s.set(target)
        return ("\(s.title) \(target ? "on" : "off")", target ? "checkmark.circle.fill" : "circle.slash")
    }

    // MARK: Helpers

    private static func globalBool(_ key: String) -> Bool? {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? Bool
    }
    private static func setGlobal(_ key: String, _ on: Bool) {
        run("/usr/bin/defaults", ["write", "NSGlobalDomain", key, "-bool", on ? "true" : "false"])
    }
    private static func defaultsBool(_ domain: String, _ key: String) -> Bool? {
        UserDefaults(suiteName: domain)?.object(forKey: key) as? Bool
    }
    private static func currentHostBool(_ domain: String, _ key: String) -> Bool? {
        CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool
    }
    private static func defaults(_ domain: String, _ key: String, _ on: Bool) {
        run("/usr/bin/defaults", ["write", domain, key, "-bool", on ? "true" : "false"])
    }
    private static func restartFinder() { restart("Finder") }
    private static func restart(_ process: String) { run("/usr/bin/killall", [process]) }
    private static func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    @discardableResult private static func osa(_ s: String) -> String? { SystemController.osa(s) }

    /// CoreBrightness's CBBlueLightClient (what Control Center uses).
    enum NightShift {
        private static let client: NSObject? = {
            _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
            return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
        }()
        static var enabled: Bool? {
            // getBlueLightStatus: fills a struct whose second byte is "enabled".
            guard let client, client.responds(to: Selector(("getBlueLightStatus:"))) else { return nil }
            var status = [UInt8](repeating: 0, count: 64)
            typealias Get = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
            let sel = Selector(("getBlueLightStatus:"))
            let f = unsafeBitCast(client.method(for: sel), to: Get.self)
            guard status.withUnsafeMutableBytes({ f(client, sel, $0.baseAddress!) }) else { return nil }
            return status[1] != 0
        }
        static func set(_ on: Bool) {
            guard let client else { return }
            typealias Set = @convention(c) (NSObject, Selector, Bool) -> Bool
            let sel = Selector(("setEnabled:"))
            guard client.responds(to: sel) else { return }
            _ = unsafeBitCast(client.method(for: sel), to: Set.self)(client, sel, on)
        }
    }

    enum BluetoothPower {
        private typealias Set = @convention(c) (Int32) -> Void
        private static let setter: Set? = {
            guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
                  let s = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
            return unsafeBitCast(s, to: Set.self)
        }()
        static func set(_ on: Bool) { setter?(on ? 1 : 0) }
    }
}
