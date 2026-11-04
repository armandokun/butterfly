import CoreAudio
import IOKit
import Foundation

/// "Switch sound to AirPods": lists output devices and sets the default output (and alert sounds) via CoreAudio.
enum AudioOutput {
    struct Device: Equatable { let id: AudioObjectID; let name: String; let bluetooth: Bool }

    private static func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reading every device's streams/name/transport costs ~90 ms, so routing uses a cached list,
    /// refreshed whenever macOS reports devices added or removed.
    nonisolated(unsafe) private static var cache: [Device]?
    nonisolated(unsafe) private static var watching = false
    static var cachedDevices: [Device] {
        if !watching {
            watching = true
            var a = address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.global(qos: .utility)) { _, _ in
                let fresh = AudioOutput.devices
                DispatchQueue.main.async { cache = fresh }
            }
        }
        if let cache { return cache }
        let fresh = devices
        cache = fresh
        return fresh
    }

    /// Call at launch so the first command doesn't pay for the scan.
    static func warm() { DispatchQueue.global(qos: .utility).async { let d = devices; DispatchQueue.main.async { if cache == nil { cache = d }; _ = cachedDevices } } }

    static var devices: [Device] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Outputs only: has at least one output stream.
            var s = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr, n > 0 else { return nil }
            var na = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let cf = name?.takeRetainedValue() else { return nil }
            var t = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var ts = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &t, 0, nil, &ts, &transport)
            // Hide virtual/aggregate helpers (Zoom, Teams, BlackHole…) unless they're all there is.
            if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate { return nil }
            return Device(id: id, name: cf as String,
                          bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    static var current: AudioObjectID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr ? id : nil
    }

    @discardableResult
    static func set(_ id: AudioObjectID) -> Bool {
        var dev = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, size, &dev) == noErr
        var s = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &s, 0, nil, size, &dev)
        return ok
    }

    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("macbook") || n.contains("speaker") && n.contains("built") { return "laptopcomputer" }
        if n.contains("headphone") || n.contains("beats") || n.contains("buds") { return "headphones" }
        if n.contains("tv") || n.contains("hdmi") || n.contains("display") || n.contains("monitor") { return "tv" }
        return "hifispeaker"
    }
}

/// Microphones. "Automatic" = the system's input, except when the lid is closed and that's the
/// built-in mic (it's off then): use a real external mic instead (Studio Display, USB, AirPods…).
enum AudioInput {
    struct Device: Identifiable, Hashable { let id: AudioObjectID; let uid: String; let name: String; let builtIn: Bool; var bluetooth = false }

    private static func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel); var v: Unmanaged<CFString>?; var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Real microphones only (no Teams/Zoom/Steam virtual devices).
    static var devices: [Device] {
        var a = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var s = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput); var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr, n > 0 else { return nil }
            var t = address(kAudioDevicePropertyTransportType); var transport: UInt32 = 0; var ts = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &t, 0, nil, &ts, &transport)
            if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate { return nil }
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, uid: uid, name: name, builtIn: transport == kAudioDeviceTransportTypeBuiltIn,
                          bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    static var systemDefault: AudioObjectID? {
        var a = address(kAudioHardwarePropertyDefaultInputDevice); var id: AudioObjectID = 0; var n = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &id) == noErr ? id : nil
    }

    /// Lid closed (clamshell with an external display): the built-in mic is off.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }

    /// "" = Automatic. Saved in Settings.
    static var preferredUID: String {
        get { UserDefaults.standard.string(forKey: "micUID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "micUID") }
    }

    /// The mic Butterfly should listen with right now.
    static var chosen: Device? {
        let list = devices
        if !preferredUID.isEmpty, let d = list.first(where: { $0.uid == preferredUID }) { return d }
        let lid = lidClosed
        let usable = list.filter { !($0.builtIn && lid) }
        let def = list.first { $0.id == systemDefault }
        // Never a Bluetooth mic when another works: turning on the AirPods mic flips them into call mode
        // (muffled mono music, a stutter on every ⌥ press).
        if let def, usable.contains(def), !def.bluetooth { return def }
        if let wired = usable.first(where: { !$0.bluetooth && !$0.builtIn }) ?? usable.first(where: { !$0.bluetooth }) { return wired }
        return def ?? usable.first ?? list.first
    }
}
