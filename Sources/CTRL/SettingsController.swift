import AppKit

/// Settings decision tree. Every level is asked in the SAME Jev request ("speculative fan-out");
/// code walks the tree afterwards using only the answers on the chosen path.
///
///   intent = settings
///     └─ settings_page   (52 real System Settings pages)
///          └─ settings_action   (open page / turn on / turn off) — only some pages can toggle
@MainActor
enum SettingsController {
    struct Page {
        let key: String          // Jev option key
        let title: String        // shown in the notch
        let description: String  // what Jev reads
        let paneID: String       // x-apple.systempreferences:<paneID>
        var toggle: Toggle? = nil
    }

    enum Toggle: Equatable { case wifi, darkMode }

    enum Action: String { case open, turnOn = "turn_on", turnOff = "turn_off" }

    static let pages: [Page] = [
        Page(key: "wifi", title: "Wi-Fi", description: "Wi-Fi, wireless internet, networks to join", paneID: "com.apple.wifi-settings-extension", toggle: .wifi),
        Page(key: "bluetooth", title: "Bluetooth", description: "Bluetooth, pairing devices, AirPods, wireless keyboard or mouse", paneID: "com.apple.BluetoothSettings"),
        Page(key: "network", title: "Network", description: "network, ethernet, firewall, proxies, internet connection", paneID: "com.apple.Network-Settings.extension"),
        Page(key: "vpn", title: "VPN", description: "VPN", paneID: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"),
        Page(key: "notifications", title: "Notifications", description: "notifications, alerts, banners, badges", paneID: "com.apple.Notifications-Settings.extension"),
        Page(key: "sound", title: "Sound", description: "sound, volume, speakers, microphone input, output device, alert sounds", paneID: "com.apple.Sound-Settings.extension"),
        Page(key: "focus", title: "Focus", description: "Focus, Do Not Disturb, sleep mode", paneID: "com.apple.Focus-Settings.extension"),
        Page(key: "screen_time", title: "Screen Time", description: "Screen Time, app limits, usage", paneID: "com.apple.Screen-Time-Settings.extension"),
        Page(key: "general", title: "General", description: "general settings", paneID: "com.apple.systempreferences.GeneralSettings"),
        Page(key: "about", title: "About", description: "about this Mac, serial number, model, macOS version", paneID: "com.apple.SystemProfiler.AboutExtension"),
        Page(key: "software_update", title: "Software Update", description: "software update, update macOS, upgrade", paneID: "com.apple.Software-Update-Settings.extension"),
        Page(key: "storage", title: "Storage", description: "storage, disk space, free up space", paneID: "com.apple.settings.Storage"),
        Page(key: "airdrop_handoff", title: "AirDrop & Handoff", description: "AirDrop, Handoff, AirPlay receiver, Continuity", paneID: "com.apple.AirDrop-Handoff-Settings.extension"),
        Page(key: "login_items", title: "Login Items", description: "login items, apps that open at startup, background items", paneID: "com.apple.LoginItems-Settings.extension"),
        Page(key: "language_region", title: "Language & Region", description: "language, region, date format, translation", paneID: "com.apple.Localization-Settings.extension"),
        Page(key: "date_time", title: "Date & Time", description: "date, time, clock, time zone", paneID: "com.apple.Date-Time-Settings.extension"),
        Page(key: "sharing", title: "Sharing", description: "sharing, file sharing, screen sharing, remote login, computer name", paneID: "com.apple.Sharing-Settings.extension"),
        Page(key: "time_machine", title: "Time Machine", description: "Time Machine, backups", paneID: "com.apple.Time-Machine-Settings.extension"),
        Page(key: "transfer_reset", title: "Transfer or Reset", description: "transfer or reset, erase this Mac, factory reset", paneID: "com.apple.Transfer-Reset-Settings.extension"),
        Page(key: "startup_disk", title: "Startup Disk", description: "startup disk, boot disk", paneID: "com.apple.Startup-Disk-Settings.extension"),
        Page(key: "appearance", title: "Appearance", description: "appearance, dark mode, light mode, accent color, theme", paneID: "com.apple.Appearance-Settings.extension", toggle: .darkMode),
        Page(key: "accessibility", title: "Accessibility", description: "accessibility, VoiceOver, zoom, larger text, reduce motion", paneID: "com.apple.Accessibility-Settings.extension"),
        Page(key: "control_center", title: "Control Center", description: "Control Center, menu bar items, battery percentage in menu bar", paneID: "com.apple.ControlCenter-Settings.extension"),
        Page(key: "siri", title: "Apple Intelligence & Siri", description: "Siri, Apple Intelligence, voice assistant", paneID: "com.apple.Siri-Settings.extension"),
        Page(key: "spotlight", title: "Spotlight", description: "Spotlight search settings", paneID: "com.apple.Spotlight-Settings.extension"),
        Page(key: "privacy", title: "Privacy & Security", description: "privacy, security, permissions, camera or microphone access, location services, FileVault", paneID: "com.apple.settings.PrivacySecurity.extension"),
        Page(key: "desktop_dock", title: "Desktop & Dock", description: "desktop, Dock, Mission Control, hot corners, Stage Manager, window tiling", paneID: "com.apple.Desktop-Settings.extension"),
        Page(key: "displays", title: "Displays", description: "displays, monitor, screen resolution, brightness, Night Shift, external display", paneID: "com.apple.Displays-Settings.extension"),
        Page(key: "wallpaper", title: "Wallpaper", description: "wallpaper, desktop background picture, screen saver", paneID: "com.apple.Wallpaper-Settings.extension"),
        Page(key: "battery", title: "Battery", description: "battery, energy, low power mode, charging, power adapter", paneID: "com.apple.Battery-Settings.extension"),
        Page(key: "lock_screen", title: "Lock Screen", description: "lock screen, screen turns off, require password after sleep", paneID: "com.apple.Lock-Screen-Settings.extension"),
        Page(key: "touch_id", title: "Touch ID & Password", description: "Touch ID, fingerprint, login password", paneID: "com.apple.Touch-ID-Settings.extension"),
        Page(key: "users_groups", title: "Users & Groups", description: "users, groups, accounts on this Mac, guest user", paneID: "com.apple.Users-Groups-Settings.extension"),
        Page(key: "internet_accounts", title: "Internet Accounts", description: "internet accounts, email accounts, Google account, calendars", paneID: "com.apple.Internet-Accounts-Settings.extension"),
        Page(key: "apple_account", title: "Apple Account", description: "Apple ID, Apple Account, iCloud, subscriptions", paneID: "com.apple.systempreferences.AppleIDSettings"),
        Page(key: "family", title: "Family", description: "Family Sharing", paneID: "com.apple.Family-Settings.extension"),
        Page(key: "wallet", title: "Wallet & Apple Pay", description: "Wallet, Apple Pay, cards", paneID: "com.apple.WalletSettingsExtension"),
        Page(key: "game_center", title: "Game Center", description: "Game Center", paneID: "com.apple.Game-Center-Settings.extension"),
        Page(key: "game_controllers", title: "Game Controllers", description: "game controllers, gamepad", paneID: "com.apple.Game-Controller-Settings.extension"),
        Page(key: "keyboard", title: "Keyboard", description: "keyboard, shortcuts, key repeat, input sources, dictation, keyboard backlight", paneID: "com.apple.Keyboard-Settings.extension"),
        Page(key: "mouse", title: "Mouse", description: "mouse, scrolling direction, tracking speed", paneID: "com.apple.Mouse-Settings.extension"),
        Page(key: "trackpad", title: "Trackpad", description: "trackpad, gestures, tap to click, force click", paneID: "com.apple.Trackpad-Settings.extension"),
        Page(key: "printers", title: "Printers & Scanners", description: "printers, scanners, add a printer", paneID: "com.apple.Print-Scan-Settings.extension"),
        Page(key: "headphones", title: "Headphones", description: "headphones, AirPods settings, spatial audio", paneID: "com.apple.HeadphoneSettings"),
        Page(key: "extensions", title: "Extensions", description: "extensions, share menu, Finder extensions", paneID: "com.apple.ExtensionsSettings.DefaultExtensionEnablement"),
        Page(key: "profiles", title: "Profiles", description: "device management profiles, MDM", paneID: "com.apple.Profiles-Settings.extension"),
    ]

    static func page(_ key: String) -> Page? { pages.first { $0.key == key } }

    // MARK: Jev questions (added to the main request)

    /// Dark/light is its own tiny branch: "turn on" is ambiguous for "go to light mode".
    static let themeQuestion: TypeSafeClient.Question = .choice(
        "Which appearance does the user want?",
        options: [
            "dark": "dark mode, dark theme, night look",
            "light": "light mode, light theme, bright look",
            "unspecified": "no dark or light preference mentioned",
        ]
    )

    static var pageQuestion: TypeSafeClient.Question {
        var options: [String: String] = [:]
        for p in pages { options[p.key] = "the \(p.title) settings page: \(p.description)" }
        return .choice("Which System Settings page or setting is the user talking about?", options: options)
    }

    static let actionQuestion: TypeSafeClient.Question = .choice(
        "What does the user want to do with that setting?",
        options: [
            "open": "open or show the settings page, or change something on it",
            "turn_on": "turn it on, enable it, switch to it (e.g. turn on Wi-Fi, switch to dark mode)",
            "turn_off": "turn it off, disable it, switch away from it (e.g. turn off Wi-Fi, switch to light mode)",
        ]
    )

    // MARK: Doing it

    struct Result { let title: String; let detail: String? }

    static func perform(_ page: Page, action: Action) -> Result {
        if action != .open, let toggle = page.toggle {
            let on = action == .turnOn
            switch toggle {
            case .wifi:
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                p.arguments = ["-setairportpower", wifiDevice() ?? "en0", on ? "on" : "off"]
                try? p.run()
                p.waitUntilExit()
                return Result(title: "Wi-Fi " + (on ? "on" : "off"), detail: nil)
            case .darkMode:
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")?
                    .executeAndReturnError(&error)
                if error == nil { return Result(title: on ? "Dark mode" : "Light mode", detail: nil) }
            }
        }
        open(page)
        let hint = action != .open && page.toggle == nil ? "Opened so you can change it" : nil
        return Result(title: page.title, detail: hint ?? "Settings")
    }

    static func open(_ page: Page) {
        guard let url = URL(string: "x-apple.systempreferences:\(page.paneID)") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { app, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app?.activate() }
        }
    }

    static var settingsApp: InstalledApp? { AppCatalog.shared.app(named: "System Settings") }

    private static func wifiDevice() -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallhardwareports"]
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = out.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("Wi-Fi") }), i + 1 < lines.count else { return nil }
        return lines[i + 1].components(separatedBy: ": ").last
    }
}
