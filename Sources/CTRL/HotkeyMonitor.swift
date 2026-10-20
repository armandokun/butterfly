import AppKit
import ApplicationServices

/// Hold LEFT Option (alone) = push-to-talk command. Hold RIGHT Option = dictation only (words typed, no commands).
/// Option + any other key (e.g. ⌥← or typing "©") cancels, so normal shortcuts keep working.
/// Left Option + Shift = lock commands; Right Option + Shift = lock dictation. Tap Option to stop.
@MainActor
final class HotkeyMonitor {
    var onBegin: ((_ dictation: Bool) -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLock: ((_ dictation: Bool) -> Void)?
    var onUnlock: (() -> Void)?

    /// Short delay so quick ⌥-shortcuts never flash the notch.
    private let holdDelay: TimeInterval = 0.15
    private var pending: DispatchWorkItem?
    private var active = false
    private var activeSide = false   // true: the right ⌥ (dictation) started it
    private var locked = false
    private var lockArmed = false   // every key released since locking; the next ⌥ tap unlocks
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
        let rightOption = raw & 0x40 != 0 && raw & 0x20 == 0
        let optionOnly = mods == .option && leftOption
        let rightOnly = mods == .option && rightOption
        let lockCombo = mods == [.option, .shift] && (leftOption || rightOption)

        if locked {
            if mods.isEmpty { lockArmed = true; return }   // keys from the ⌥⇧ combo let go
            if lockArmed, optionOnly || rightOnly {          // tap either ⌥ → stop
                locked = false
                lockArmed = false
                onUnlock?()
            }
            return
        }

        if lockCombo {
            if let pending { pending.cancel(); self.pending = nil }
            locked = true
            lockArmed = false
            active = false
            onLock?(rightOption)   // right ⌥⇧ = locked dictation; also upgrades a push-to-talk already listening
            return
        }

        if (optionOnly || rightOnly), pending == nil, !active {
            let dictation = rightOnly
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.active = true
                self.activeSide = dictation
                self.onBegin?(dictation)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else if !(activeSide ? rightOnly : optionOnly) {
            if let pending { pending.cancel(); self.pending = nil }
            if active {
                active = false
                // Option released → finish. Another modifier added → treat as a shortcut.
                mods.isEmpty ? onEnd?() : onCancel?()
            }
        }
    }

    private func otherKeyPressed() {
        if locked { return }   // typing (yours or CTRL's) doesn't stop locked mode
        if let pending { pending.cancel(); self.pending = nil }
        if active { active = false; onCancel?() }
    }
}
