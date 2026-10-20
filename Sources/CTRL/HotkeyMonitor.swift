import AppKit
import ApplicationServices

/// Hold LEFT Option (alone) = push-to-talk. Right Option is ignored.
/// Option + any other key (e.g. ⌥← or typing "©") cancels, so normal shortcuts keep working.
@MainActor
final class HotkeyMonitor {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Short delay so quick ⌥-shortcuts never flash the notch.
    private let holdDelay: TimeInterval = 0.15
    private var pending: DispatchWorkItem?
    private var active = false
    private var monitors: [Any] = []

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.otherKeyPressed() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    private func flagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Left Option only: device-dependent bits 0x20 = left ⌥, 0x40 = right ⌥.
        let raw = event.modifierFlags.rawValue
        let leftOption = raw & 0x20 != 0 && raw & 0x40 == 0
        let optionOnly = mods == .option && leftOption

        if optionOnly, pending == nil, !active {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.active = true
                self.onBegin?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else if !optionOnly {
            if let pending { pending.cancel(); self.pending = nil }
            if active {
                active = false
                // Option released → finish. Another modifier added → treat as a shortcut.
                mods.isEmpty ? onEnd?() : onCancel?()
            }
        }
    }

    private func otherKeyPressed() {
        if let pending { pending.cancel(); self.pending = nil }
        if active { active = false; onCancel?() }
    }
}
