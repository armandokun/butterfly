import AppKit

/// In action mode (left ⌥⇧ locked): press the mouse, hold still for a moment, then drag to draw on the screen.
/// Ordinary clicks and drags pass through untouched. The marks wait for your next sentence.
@MainActor
final class MarkGesture {
    static let shared = MarkGesture()

    var enabled = false {
        didSet {
            if enabled { start() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
            if !enabled { downAt = nil; marking = false; pressTimer?.cancel() }
        }
    }

    private var tap: CFMachPort?
    private var downAt: CGPoint?
    private var pressTimer: DispatchWorkItem?
    private var marking = false
    /// A stroke is in progress (mouse still down).
    var isMarking: Bool { marking }
    private let holdDelay = 0.5
    private static let ownTag: Int64 = 0xB7F1   // our synthetic events pass through the tap

    private func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, info in
            let g = Unmanaged<MarkGesture>.fromOpaque(info!).takeUnretainedValue()
            return MainActor.assumeIsolated { g.handle(type, event) }
        }, userInfo: me) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(e) }
        if e.getIntegerValueField(.eventSourceUserData) == Self.ownTag { return Unmanaged.passUnretained(e) }
        let p = e.location   // global, top-left origin
        switch type {
        case .leftMouseDown:
            guard enabled else { break }
            downAt = p
            marking = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.downAt != nil else { return }
                self.beginMark(at: p)
            }
            pressTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        case .leftMouseDragged:
            if marking { MarkOverlay.shared.addPoint(global: p, newStroke: false); return nil }
            if let d = downAt, hypot(p.x - d.x, p.y - d.y) > 6 { pressTimer?.cancel(); downAt = nil }   // a real drag
        case .leftMouseUp:
            pressTimer?.cancel(); downAt = nil
            if marking { marking = false; MarkOverlay.shared.endStroke(); return nil }
        default: break
        }
        return Unmanaged.passUnretained(e)
    }

    /// Held still long enough: the app gets a plain click (synthetic mouse-up), and the drag that follows draws.
    private func beginMark(at p: CGPoint) {
        marking = true
        downAt = nil
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: Self.ownTag)
            up.post(tap: .cghidEventTap)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        MarkOverlay.shared.showPassive()
        MarkOverlay.shared.addPoint(global: p, newStroke: true)
    }
}
