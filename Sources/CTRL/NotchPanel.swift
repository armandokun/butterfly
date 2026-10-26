import AppKit
import SwiftUI

/// Transparent, click-through panel pinned to the top-center of the notch screen, above everything.
final class NotchPanel: NSPanel {
    static let size = CGSize(width: 640, height: 320)   // tallest card fits; clicks pass through anyway

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .init(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: rootView)
        host.frame = .init(origin: .zero, size: Self.size)
        contentView = host
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        guard let screen = NotchMetrics.screen else { return }
        let f = screen.frame
        setFrameOrigin(.init(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height))
    }

    /// Trackpad / mouse-wheel swipe over the notch (the panel stays click-through, so this listens globally).
    /// Fires once per gesture when it moves up or sideways past a small threshold, within the top strip.
    private var swipeMonitor: Any?
    private var travel = CGSize.zero
    private var fired = false
    private var lastScroll = Date.distantPast
    func onSwipeAway(_ action: @escaping @MainActor () -> Void) {
        swipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.momentumPhase.isEmpty else { return }   // ignore inertia after the fingers lift
            // A new gesture: trackpad says .began; a mouse wheel just pauses.
            if e.phase == .began || Date().timeIntervalSince(self.lastScroll) > 0.35 { self.travel = .zero; self.fired = false }
            self.lastScroll = Date()
            let zone = NSRect(x: self.frame.midX - 220, y: self.frame.maxY - 140, width: 440, height: 140)
            guard !self.fired, NSMouseInRect(NSEvent.mouseLocation, zone, false) else { return }
            // Fingers moving up (either scrolling direction setting).
            let up = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
            self.travel.width += abs(e.scrollingDeltaX)
            self.travel.height += up
            if self.travel.height > 30 || self.travel.width > 60 {
                self.fired = true
                Task { @MainActor in action() }
            }
        }
    }
}

enum NotchMetrics {
    /// The screen you're working on (set when you press ⌥). Nil → the built-in notch display.
    @MainActor static var active: NSScreen?

    /// Screen under the mouse: where you're looking.
    @MainActor static var screenUnderMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    /// Active screen, else the built-in display with a notch.
    @MainActor static var screen: NSScreen? {
        if let active, NSScreen.screens.contains(active) { return active }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    @MainActor static var hasNotch: Bool { (screen?.safeAreaInsets.top ?? 0) > 0 }

    @MainActor static var closedSize: CGSize {
        guard let s = screen else { return .init(width: 185, height: 32) }
        var width: CGFloat = 185
        if let l = s.auxiliaryTopLeftArea?.width, let r = s.auxiliaryTopRightArea?.width {
            width = s.frame.width - l - r + 4
        }
        let height = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : max(24, s.frame.maxY - s.visibleFrame.maxY)
        return .init(width: width, height: height)
    }
}
