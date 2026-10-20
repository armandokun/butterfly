import AudioToolbox
import CoreAudio
import SwiftUI

/// Volume / brightness level, shown as a compact live activity beside the notch (DynamicNotch's HUD).
enum LevelKind: Equatable {
    case volume, brightness

    func symbol(for level: Int) -> String {
        switch self {
        case .brightness: level < 50 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            switch level {
            case ..<1: "speaker.slash.fill"
            case ..<20: "speaker.fill"
            case ..<50: "speaker.wave.1.fill"
            case ..<70: "speaker.wave.2.fill"
            default: "speaker.wave.3.fill"
            }
        }
    }
}

/// DynamicNotch's bar: green → red with level, soft glow.
struct LevelBar: View {
    let level: Int
    var width: CGFloat = 54
    var height: CGFloat = 6

    private var p: CGFloat { CGFloat(max(0, min(100, level))) / 100 }
    private var tint: Color {
        level <= 0 ? .white.opacity(0.45) : Color(hue: 0.33 * (1 - Double(p)), saturation: 0.86, brightness: 0.98)
    }

    var body: some View {
        Capsule().fill(.white.opacity(0.18))
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * p, height: height)
                    .shadow(color: tint.opacity(0.8), radius: 5)
            }
            .animation(.snappy(duration: 0.28, extraBounce: 0.12), value: level)
    }
}

/// Any volume change (keys, Control Center, other apps) → callback with 0–100 (0 when muted).
@MainActor
final class VolumeObserver {
    var onChange: ((Int) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: Int?

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private lazy var levelBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.report() } }
    }
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.attach() } }
    }

    func start() {
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, deviceBlock)
        attach()
        last = Self.level(of: device)
    }

    private func attach() {
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] where device != kAudioObjectUnknown {
            var a = Self.address(sel, kAudioDevicePropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(device, &a, .main, levelBlock)
        }
        device = Self.defaultOutput()
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = Self.address(sel, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, levelBlock)
        }
    }

    private func report() {
        guard let v = Self.level(of: device), v != last else { return }
        last = v
        onChange?(v)
    }

    private static func defaultOutput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func level(of device: AudioObjectID) -> Int? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var m = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if AudioObjectGetPropertyData(device, &m, 0, nil, &size, &muted) == noErr, muted != 0 { return 0 }
        var v: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
        return Int((v * 100).rounded())
    }
}
