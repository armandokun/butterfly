import AppKit
import SwiftUI

/// Developer mode: a small floating window, always on top and on every Space, that shows the decision tree
/// of the newest command as soon as it finishes. Movable; position and open state are remembered.
@MainActor
final class DecisionTreeWindow {
    static let shared = DecisionTreeWindow()
    private var panel: NSPanel?
    private(set) var wasShown = false

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        wasShown = true
        if panel == nil {
            let p = NSPanel(contentRect: .init(x: 0, y: 0, width: 640, height: 460),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Decision Tree"
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: DebugPane(follow: true).background(Backdrop()).preferredColorScheme(.light))
            p.setFrameAutosaveName("DecisionTree")
            if !p.setFrameUsingName("DecisionTree"), let s = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(.init(x: s.maxX - 660, y: s.minY + 20))
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
                UserDefaults.standard.set(false, forKey: "decisionTreeOpen")
            }
            panel = p
        }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "decisionTreeOpen")
    }

    func close() { panel?.close() }
}
