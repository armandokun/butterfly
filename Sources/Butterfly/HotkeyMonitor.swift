import AppKit
import ApplicationServices

/// Hold RIGHT Option (alone) = dictation: what you say gets typed. Left Option is left alone.
/// Right Option + any other key (e.g. ⌥← or typing "©") cancels, so normal shortcuts keep working.
/// Right Option + Shift = locked dictation (keeps typing each sentence). Tap right Option to stop.
@MainActor
final class HotkeyMonitor {
    var onBegin: (() -> Void)?
    var onArm: (() -> Void)?      // ⌥ just went down (before the hold delay): start the mic
    var onDisarm: (() -> Void)?   // …it was a shortcut or a tap after all
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?

    /// Short delay so quick ⌥-shortcuts never flash the notch.
    private let holdDelay: TimeInterval = 0.1
    private var pending: DispatchWorkItem?
    private var active = false
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
        // Right Option only: device-dependent bits 0x20 = left ⌥, 0x40 = right ⌥.
        let raw = event.modifierFlags.rawValue
        let rightOption = raw & 0x40 != 0 && raw & 0x20 == 0
        let rightOnly = mods == .option && rightOption
        let lockCombo = mods == [.option, .shift] && rightOption

        if locked {
            if mods.isEmpty { lockArmed = true; return }   // keys from the ⌥⇧ combo let go
            if lockArmed, rightOnly {                        // tap right ⌥ → stop
                locked = false
                lockArmed = false
                onUnlock?()
            }
            return
        }

        if lockCombo {
            if let pending { pending.cancel(); self.pending = nil }   // the lock starts listening: keep the armed mic
            locked = true
            lockArmed = false
            active = false
            onLock?()   // also upgrades a push-to-talk already listening
            return
        }

        if rightOnly, pending == nil, !active {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.active = true
                self.onBegin?()
            }
            pending = work
            onArm?()
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else if !rightOnly {
            if let pending { pending.cancel(); self.pending = nil; onDisarm?() }
            if active {
                active = false
                // Option released → finish. Another modifier added → treat as a shortcut.
                mods.isEmpty ? onEnd?() : onCancel?()
            }
        }
    }

    private func otherKeyPressed() {
        if locked { return }   // typing (yours or Butterfly's) doesn't stop locked mode
        if let pending { pending.cancel(); self.pending = nil; onDisarm?() }
        if active { active = false; onCancel?() }
    }
}
