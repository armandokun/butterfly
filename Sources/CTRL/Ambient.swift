import AppKit
import CoreBluetooth
import CoreLocation
import CoreWLAN
import IOBluetooth

// MARK: - Focus

/// Reading: ~/Library/DoNotDisturb/DB (needs Full Disk Access; without it we just don't announce changes).
/// Switching: the "CTRL Focus" shortcut (macOS has no public API). CTRL builds and signs it; you click Add once.
@MainActor
enum Focus {
    struct Mode { let name: String; let id: String }
    nonisolated static let shortcutName = "CTRL Focus"

    private static let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    static var modes: [Mode] {
        guard let d = try? Data(contentsOf: db.appendingPathComponent("ModeConfigurations.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cfg = ((j["data"] as? [[String: Any]])?.first?["modeConfigurations"]) as? [String: [String: Any]] else {
            return [Mode(name: "Do Not Disturb", id: "com.apple.donotdisturb.mode.default")]
        }
        return cfg.values.compactMap { $0["mode"] as? [String: Any] }.compactMap {
            guard let n = $0["name"] as? String, let id = $0["modeIdentifier"] as? String else { return nil }
            return Mode(name: n, id: id)
        }.sorted { $0.name < $1.name }
    }

    /// Active mode name, nil when off. Nil also when unreadable.
    static var active: String? {
        guard let d = try? Data(contentsOf: db.appendingPathComponent("Assertions.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rec = (j["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]],
              let id = rec.compactMap({ ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }).last
        else { return nil }
        return modes.first { $0.id == id }?.name ?? "Focus"
    }

    static func symbol(for name: String?) -> String {
        switch name?.lowercased() ?? "" {
        case "": "moon"
        case let n where n.contains("sleep"): "bed.double.fill"
        case let n where n.contains("work"): "briefcase.fill"
        case let n where n.contains("personal"): "person.fill"
        case let n where n.contains("driv"): "car.fill"
        case let n where n.contains("fitness"), let n where n.contains("workout"): "figure.run"
        case let n where n.contains("gaming"): "gamecontroller.fill"
        case let n where n.contains("reduce"): "rectangle.stack.badge.minus"
        default: "moon.fill"
        }
    }

    static var isInstalled: Bool { shortcutsList().contains(shortcutName) }

    private static func shortcutsList() -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// "Work" / "Do Not Disturb" / "off".
    static func set(_ mode: String) async -> Bool {
        await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", shortcutName, "-i", "-"]
            let input = Pipe(); p.standardInput = input
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            input.fileHandleForWriting.write(Data(mode.utf8)); try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }

    /// Builds, signs, and opens the shortcut (you click Add once).
    static func install() async {
        let actions = modes.flatMap { m in conditional(m.name, [action(m, on: true)]) }
            + conditional("off", modes.map { action($0, on: false) })
        let wf: [String: Any] = [
            "WFWorkflowActions": actions, "WFWorkflowClientVersion": "2607.0.0", "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowHasShortcutInputVariables": true, "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowTypes": [], "WFWorkflowImportQuestions": [], "WFQuickActionSurfaces": [],
            "WFWorkflowIcon": ["WFWorkflowIconGlyphNumber": 59511, "WFWorkflowIconStartColor": 1440408063],
        ]
        let dir = FileManager.default.temporaryDirectory
        let raw = dir.appendingPathComponent("ctrl-focus-unsigned.shortcut")
        let signed = dir.appendingPathComponent("\(shortcutName).shortcut")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0),
              (try? data.write(to: raw)) != nil else { return }
        try? FileManager.default.removeItem(at: signed)
        await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["sign", "--mode", "anyone", "--input", raw.path, "--output", signed.path]
            try? p.run(); p.waitUntilExit()
        }.value
        NSWorkspace.shared.open(signed)
    }

    private static let input: [String: Any] = ["Value": ["Type": "ExtensionInput"], "WFSerializationType": "WFTextTokenAttachment"]
    private static func conditional(_ text: String, _ body: [[String: Any]]) -> [[String: Any]] {
        let g = UUID().uuidString
        return [["WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
                 "WFWorkflowActionParameters": ["GroupingIdentifier": g, "WFControlFlowMode": 0, "WFCondition": 4,
                                                "WFConditionalActionString": text, "WFInput": ["Type": "Variable", "Variable": input]]]]
            + body
            + [["WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
                "WFWorkflowActionParameters": ["GroupingIdentifier": g, "WFControlFlowMode": 2]]]
    }
    private static func action(_ m: Mode, on: Bool) -> [String: Any] {
        ["WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
         "WFWorkflowActionParameters": ["Enabled": on ? 1 : 0, "AssertionType": "Turned Off",
                                        "FocusModes": ["Identifier": m.id, "DisplayString": m.name]]]
    }
}

// MARK: - Wi-Fi

@MainActor
final class WiFi: NSObject, CWEventDelegate, CLLocationManagerDelegate {
    static let shared = WiFi()
    var onChange: ((_ ssid: String?, _ on: Bool) -> Void)?
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private var last: (ssid: String?, on: Bool)?

    var ssid: String? { client.interface()?.ssid() }
    var isOn: Bool { client.interface()?.powerOn() ?? false }
    var known: [String] {
        guard let cfg = client.interface()?.configuration() else { return [] }
        return cfg.networkProfiles.array.compactMap { ($0 as? CWNetworkProfile)?.ssid }
    }

    func start() {
        // macOS hides network names from apps without Location access.
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        client.delegate = self
        for e in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange] { try? client.startMonitoringEvent(with: e) }
        last = (ssid, isOn)
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.report() } }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.report() } }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.report() } }

    private func report() {
        let now = (ssid, isOn)
        guard now.0 != last?.ssid || now.1 != last?.on else { return }
        // Roaming briefly reports nil between networks: wait a beat.
        let before = last
        last = now
        Task {
            try? await Task.sleep(for: .milliseconds(now.0 == nil && now.1 ? 1500 : 0))
            guard self.ssid == now.0 || now.0 != nil else { return }
            if before?.ssid != nil, now.0 == nil, now.1, self.ssid != nil { return }
            self.onChange?(now.0, now.1)
        }
    }

    /// Joins a saved network (password from Keychain).
    func join(_ name: String) async -> Bool {
        guard let iface = client.interface() else { return false }
        if !iface.powerOn() { try? iface.setPower(true); try? await Task.sleep(for: .seconds(2)) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-setairportnetwork", iface.interfaceName ?? "en0", name]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        return await Task.detached {
            guard (try? p.run()) != nil else { return false }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(decoding: d, as: UTF8.self)
            return p.terminationStatus == 0 && !text.localizedCaseInsensitiveContains("error") && !text.localizedCaseInsensitiveContains("could not")
        }.value
    }
}

// MARK: - Bluetooth

@MainActor
final class Bluetooth: NSObject {
    static let shared = Bluetooth()
    struct Device { let name: String; let address: String; let connected: Bool; let symbol: String }
    /// name, battery % (nil if unknown), connected
    var onChange: ((_ name: String, _ symbol: String, _ battery: Int?, _ connected: Bool) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var started = Date()

    /// Cached from system_profiler (no Bluetooth permission needed; IOBluetooth's list blocks on a prompt).
    private(set) var paired: [Device] = []

    func refresh() {
        Task.detached {
            let list = Self.profilerDevices()
            await MainActor.run { self.paired = list }
        }
    }
    func refreshNow() { paired = Self.profilerDevices() }   // CLI tests

    nonisolated private static func profilerDevices() -> [Device] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ctrl = (j["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        var devices: [Device] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in ctrl[key] as? [[String: Any]] ?? [] {
                for (name, info) in entry {
                    guard let addr = (info as? [String: Any])?["device_address"] as? String else { continue }
                    devices.append(Device(name: name, address: addr, connected: connected, symbol: symbol(for: name)))
                }
            }
        }
        return devices
    }

    func start() {
        started = Date()
        refresh()
        // Connect notifications need Bluetooth permission; only register once it's granted (no prompt at launch).
        if CBManager.authorization == .allowedAlways {
            connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name, let addr = device.addressString else { return }
        disconnectNotes[addr] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        // At launch macOS reports every already-connected device: stay quiet.
        guard Date().timeIntervalSince(started) > 3 else { return }
        let sym = Self.symbol(for: name)
        Task {
            try? await Task.sleep(for: .seconds(2))   // battery shows up shortly after connecting
            self.onChange?(name, sym, await Self.battery(of: name), true)
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name else { return }
        disconnectNotes[device.addressString ?? ""] = nil
        onChange?(name, Self.symbol(for: name), nil, false)
    }

    func connect(_ address: String, on: Bool) async -> Bool {
        defer { refresh() }
        let ok = await Task.detached { () -> Bool in
            guard let d = IOBluetoothDevice(addressString: address) else { return false }
            return (on ? d.openConnection() : d.closeConnection()) == kIOReturnSuccess
        }.value
        // First use granted permission: start announcing connects from now on.
        if connectNote == nil, CBManager.authorization == .allowedAlways {
            connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        }
        return ok
    }

    /// AirPods report left/right/case; we show the lowest bud (that's the one that'll die first).
    static func battery(of name: String) async -> Int? {
        await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ctrl = (j["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
            for key in ["device_connected", "device_not_connected"] {
                for entry in ctrl[key] as? [[String: Any]] ?? [] {
                    guard let info = entry[name] as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain", "device_batteryLevel"]
                        .compactMap { (info[$0] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    if let m = levels.min() { return m }
                }
            }
            return nil
        }.value
    }

    nonisolated static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") || n.contains("wh-1000") || n.contains("headphone") { return "headphones" }
        if n.contains("keyboard") { return "keyboard.fill" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if n.contains("mouse") || n.contains("mx ") { return "computermouse.fill" }
        if n.contains("controller") || n.contains("dualsense") { return "gamecontroller.fill" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("jbl") || n.contains("speaker") || n.contains("woburn") || n.contains("acton") || n.contains("onyx") { return "hifispeaker.fill" }
        return "wave.3.right"
    }
}

// MARK: - Downloads & screenshots

/// Watches Downloads and the screenshot folder; reports each new finished file once.
@MainActor
final class FileDrops {
    static let shared = FileDrops()
    enum Kind { case download, screenshot }
    var onNew: ((Kind, URL) -> Void)?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var seen: Set<String> = []

    static var screenshotFolder: URL {
        let d = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return d.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    func start() {
        for (kind, dir) in [(Kind.download, Self.downloads), (.screenshot, Self.screenshotFolder)] {
            seen.formUnion(list(dir).map(\.path))
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan(kind, dir) } }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources.append(s)
        }
    }

    private func list(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private func scan(_ kind: Kind, _ dir: URL) {
        for url in list(dir) where !seen.contains(url.path) {
            let ext = url.pathExtension.lowercased()
            // Still downloading (Safari .download, Chrome .crdownload, Firefox .part): wait for the final file.
            if ["download", "crdownload", "part", "partial", "tmp"].contains(ext) { continue }
            if kind == .screenshot, !(["png", "jpg", "jpeg", "heic", "mov"].contains(ext)) { continue }
            seen.insert(url.path)
            onNew?(kind, url)
        }
    }
}
