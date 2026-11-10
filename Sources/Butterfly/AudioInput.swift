import CoreAudio
import IOKit
import Foundation

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
