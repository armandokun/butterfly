import AppKit
import SwiftUI

/// Transparent, click-through panel pinned to the top-center of the notch screen, above everything.
final class NotchPanel: NSPanel {
    static let size = CGSize(width: 640, height: 220)

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
}

enum NotchMetrics {
    /// Prefer the built-in display with a notch.
    @MainActor static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    @MainActor static var hasNotch: Bool { (screen?.safeAreaInsets.top ?? 0) > 0 }

    @MainActor static var closedSize: CGSize {
        guard let s = screen else { return .init(width: 185, height: 32) }
        var width: CGFloat = 185
        if let l = s.auxiliaryTopLeftArea?.width, let r = s.auxiliaryTopRightArea?.width {
            width = s.frame.width - l - r + 4
        }
        let height = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : s.frame.maxY - s.visibleFrame.maxY
        return .init(width: width, height: height)
    }
}
