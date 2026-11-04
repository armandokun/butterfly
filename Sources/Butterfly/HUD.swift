import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

/// Volume / brightness level, shown as a compact live activity beside the notch (DynamicNotch's HUD).
enum LevelKind: Equatable {
    case volume, brightness, keyboard
    var label: String { switch self { case .volume: "Volume"; case .brightness: "Brightness"; case .keyboard: "Keyboard light" } }

    func symbol(for level: Int) -> String {
        switch self {
        case .brightness: level < 50 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: level == 0 ? "light.min" : "light.max"
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
    /// macOS volume/brightness HUD: plain off-white fill on a dim track.
    private var tint: Color { Color(white: level <= 0 ? 0.5 : 0.94) }

    var body: some View {
        Capsule().fill(.white.opacity(0.18))
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: width * p, height: height)
            }
            .animation(.snappy(duration: 0.28, extraBounce: 0.12), value: level)
    }
}

/// Brightness keys (built-in and external keyboards) → the same HUD as voice brightness.
@MainActor
final class BrightnessKeys {
    var onChange: ((Int) -> Void)?
    private var monitor: Any?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined, .keyDown]) { [weak self] e in
            let isBrightness: Bool
            if e.type == .systemDefined {
                // NX_SYSDEFINED subtype 8 = special keys; key 2/3 = brightness up/down; 0xA = key down.
                let code = (e.data1 & 0xFFFF0000) >> 16, down = (e.data1 & 0xFF00) >> 8 == 0xA
                isBrightness = e.subtype.rawValue == 8 && down && (code == 2 || code == 3)
            } else {
                isBrightness = e.keyCode == 144 || e.keyCode == 145   // F15/F14 on some external keyboards
            }
            guard isBrightness else { return }
            // The system applies the step a moment after the key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Task { @MainActor in
                    if let v = SystemController.Brightness.value { self?.onChange?(v) }
                }
            }
        }
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
        DispatchQueue.main.async { Task { @MainActor in self?.report() } }
    }
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { Task { @MainActor in self?.attach() } }
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
