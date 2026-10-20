import AppKit
import ApplicationServices

/// Acts on the window that was in front when you pressed Option.
@MainActor
enum WindowCommands {
    enum Action: String {
        case left, right, top, bottom
        case topLeft = "top_left", topRight = "top_right", bottomLeft = "bottom_left", bottomRight = "bottom_right"
        case maximize, center, fullscreen
        case otherScreen = "other_screen"
        case minimize, close
        case hideApp = "hide_app", hideOthers = "hide_others", quitApp = "quit_app"
    }

    static let question = TypeSafeClient.Question.choice("What does the user want done with the current window or app?", options: [
        "left": "move/snap the window to the left half of the screen",
        "right": "move/snap the window to the right half of the screen",
        "top": "move the window to the top half",
        "bottom": "move the window to the bottom half",
        "top_left": "top-left quarter / corner",
        "top_right": "top-right quarter / corner",
        "bottom_left": "bottom-left quarter / corner",
        "bottom_right": "bottom-right quarter / corner",
        "maximize": "make the window bigger, maximize it, fill the screen (not macOS full screen mode)",
        "center": "center the window on screen",
        "fullscreen": "enter or exit macOS full screen mode for the window",
        "other_screen": "move the window to the other / next / second / external monitor or display",
        "minimize": "minimize the window to the Dock",
        "close": "close the window",
        "hide_app": "hide the app",
        "hide_others": "hide all other apps, hide everything else, focus on just this one",
        "quit_app": "quit / close the whole app",
    ])

    struct Result { let symbol: String; let title: String; let detail: String? }

    /// `app`: the app the command is about (named one, or the one in front).
    static func perform(_ action: Action, app: NSRunningApplication) async -> Result {
        let name = app.localizedName ?? "App"
        switch action {
        case .hideApp:
            app.hide()
            return Result(symbol: "eye.slash", title: "Hid \(name)", detail: nil)
        case .hideOthers:
            app.activate()
            for other in NSWorkspace.shared.runningApplications
            where other.activationPolicy == .regular && other != app && other.bundleIdentifier != "com.apple.finder" {
                other.hide()
            }
            return Result(symbol: "rectangle.on.rectangle.slash", title: "Only \(name)", detail: "Hid other apps")
        case .quitApp:
            app.terminate()
            return Result(symbol: "xmark.app", title: "Quit \(name)", detail: nil)
        default: break
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) ?? attr(axApp, kAXMainWindowAttribute) else {
            return Result(symbol: "macwindow.badge.plus", title: "No \(name) window", detail: nil)
        }
        app.activate()

        switch action {
        case .minimize:
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return Result(symbol: "arrow.down.right.and.arrow.up.left", title: "Minimized", detail: name)
        case .close:
            if let button: AXUIElement = attr(window, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            return Result(symbol: "xmark", title: "Closed window", detail: name)
        case .fullscreen:
            let on: Bool = attr(window, "AXFullScreen") ?? false
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!on) as CFBoolean)
            return Result(symbol: on ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          title: on ? "Exited full screen" : "Full screen", detail: name)
        default: break
        }

        // Leave macOS full screen first, or the window can't be moved.
        if (attr(window, "AXFullScreen") as Bool?) == true {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            try? await Task.sleep(for: .milliseconds(800))
        }

        guard let current = frame(of: window) else { return Result(symbol: "macwindow", title: "Can't move this window", detail: name) }
        let screen = screen(containing: current)
        let a = screen.visibleFrame
        let half = CGSize(width: a.width / 2, height: a.height / 2)

        let target: CGRect
        var detail = name
        switch action {
        case .left: target = CGRect(x: a.minX, y: a.minY, width: half.width, height: a.height)
        case .right: target = CGRect(x: a.midX, y: a.minY, width: half.width, height: a.height)
        case .top: target = CGRect(x: a.minX, y: a.midY, width: a.width, height: half.height)
        case .bottom: target = CGRect(x: a.minX, y: a.minY, width: a.width, height: half.height)
        case .topLeft: target = CGRect(origin: CGPoint(x: a.minX, y: a.midY), size: half)
        case .topRight: target = CGRect(origin: CGPoint(x: a.midX, y: a.midY), size: half)
        case .bottomLeft: target = CGRect(origin: CGPoint(x: a.minX, y: a.minY), size: half)
        case .bottomRight: target = CGRect(origin: CGPoint(x: a.midX, y: a.minY), size: half)
        case .maximize: target = a
        case .center:
            let size = CGSize(width: min(current.width, a.width), height: min(current.height, a.height))
            target = CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
        case .otherScreen:
            let screens = NSScreen.screens
            guard screens.count > 1, let i = screens.firstIndex(of: screen) else {
                return Result(symbol: "display", title: "Only one screen", detail: nil)
            }
            let next = screens[(i + 1) % screens.count]
            let b = next.visibleFrame
            // Same relative spot and size on the other screen.
            let rx = (current.minX - a.minX) / a.width, ry = (current.minY - a.minY) / a.height
            let rw = current.width / a.width, rh = current.height / a.height
            target = CGRect(x: b.minX + rx * b.width, y: b.minY + ry * b.height, width: min(1, rw) * b.width, height: min(1, rh) * b.height)
            detail = next.localizedName
        default: return Result(symbol: "macwindow", title: "", detail: nil)
        }
        WindowManager.setFrame(window, target)
        return Result(symbol: symbol(for: action), title: title(for: action), detail: detail)
    }

    private static func symbol(for a: Action) -> String {
        switch a {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .maximize: "rectangle.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .otherScreen: "rectangle.on.rectangle"
        default: "macwindow"
        }
    }

    private static func title(for a: Action) -> String {
        switch a {
        case .left: "Left half"
        case .right: "Right half"
        case .top: "Top half"
        case .bottom: "Bottom half"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .maximize: "Maximized"
        case .center: "Centered"
        case .otherScreen: "Moved to other screen"
        default: ""
        }
    }

    // MARK: AX geometry (AX: top-left origin; Cocoa: bottom-left)

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(window, kAXPositionAttribute), let s: AXValue = attr(window, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos)
        AXValueGetValue(s, .cgSize, &size)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }

    private static func screen(containing rect: CGRect) -> NSScreen {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
            ?? NSScreen.main!
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self { return (v as! T) }
        return v as? T
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
