import AppKit
import ScreenCaptureKit

/// Hold left ⌥⇧: the screen dims a little and you can draw on it. Let go and Butterfly gets a screenshot with your
/// marks on it (plus a close-up of the marked area) to show the model. Also used by "what's this" (one stroke, then done).
@MainActor
final class MarkOverlay {
    static let shared = MarkOverlay()

    struct Marks {
        let images: [CGImage]   // [0] whole screen with the marks drawn, [1] close-up of the marked area
        let rect: CGRect        // marked area, global top-left origin
    }

    private var windows: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var strokeDone: CheckedContinuation<Bool, Never>?
    var isShowing: Bool { !windows.isEmpty }

    /// "What's this" by voice: show, wait for one stroke (or Esc), hide, return the marks.
    func selectOnce() async -> Marks? {
        guard windows.isEmpty else { return nil }
        show(singleStroke: true)
        let drew = await withCheckedContinuation { strokeDone = $0 }
        guard drew else { cancel(); return nil }
        return await hide()
    }

    func show(singleStroke: Bool = false) {
        guard windows.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen)
            w.canvas.hint = singleStroke ? "Circle what you mean   ·   Esc cancels" : "Draw on what you mean, talk if you have a question   ·   let go of ⌥⇧ when done"
            w.canvas.onStrokeEnd = { [weak self] in if singleStroke { self?.strokeDone?.resume(returning: true); self?.strokeDone = nil } }
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate()
        (windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first)?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }   // Esc
            self?.strokeDone?.resume(returning: false); self?.strokeDone = nil
            self?.cancel()
            return nil
        }
    }

    // MARK: passive marks (action mode: press-hold-drag, see MarkGesture)

    private var passive = false
    private var expiry: DispatchWorkItem?
    /// Something is drawn and waiting for the next sentence.
    var hasMarks: Bool { passive && windows.contains { w in w.canvas.strokes.contains { $0.count > 2 } } }

    /// Transparent, click-through canvases that only display what the gesture draws. Doesn't take focus.
    func showPassive() {
        if !windows.isEmpty && !passive { return }
        if windows.isEmpty {
            for screen in NSScreen.screens {
                let w = OverlayWindow(screen: screen)
                w.canvas.dim = false
                w.ignoresMouseEvents = true
                w.orderFrontRegardless()
                windows.append(w)
            }
            passive = true
        }
        expiry?.cancel()
    }

    /// `global` is a CGEvent location (top-left origin).
    func addPoint(global p: CGPoint, newStroke: Bool) {
        let main = NSScreen.screens[0].frame
        let ap = CGPoint(x: p.x, y: main.maxY - p.y)   // AppKit, bottom-left
        guard let w = windows.first(where: { $0.frame.contains(ap) }) ?? windows.first else { return }
        let local = CGPoint(x: ap.x - w.frame.minX, y: ap.y - w.frame.minY)
        if newStroke || w.canvas.strokes.isEmpty { w.canvas.strokes.append([local]) } else { w.canvas.strokes[w.canvas.strokes.count - 1].append(local) }
        w.canvas.needsDisplay = true
    }

    func endStroke() {
        for w in windows {
            // A long click or a twitch isn't a mark: needs some length to count.
            if let last = w.canvas.strokes.last, last.count <= 2 || zip(last, last.dropFirst()).reduce(0, { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }) < 24 {
                w.canvas.strokes.removeLast(); w.canvas.needsDisplay = true
            }
        }
        if !hasMarks { cancel(); return }
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in if self?.passive == true { self?.cancel() } }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)   // unused marks fade away
    }

    /// Takes the overlay down and returns the marked screenshot(s), or nil if nothing was drawn.
    func hide() async -> Marks? {
        let drawn = windows.compactMap { w -> (screen: NSScreen, strokes: [[CGPoint]])? in
            let s = w.canvas.strokes.filter { $0.count > 2 }
            return s.isEmpty ? nil : (w.target, s)
        }
        cancel()
        guard let (screen, strokes) = drawn.first else { return nil }
        try? await Task.sleep(for: .milliseconds(90))   // let the overlay vanish before the screenshot
        return await Self.capture(screen: screen, strokes: strokes)
    }

    func cancel() {
        let wasPassive = passive
        passive = false
        expiry?.cancel(); expiry = nil
        for w in windows { w.orderOut(nil) }
        windows = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard !wasPassive else { return }   // passive never took focus, nothing to give back
        NSApp.setActivationPolicy(.accessory)
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: screenshots with the marks drawn on

    private static func capture(screen: NSScreen, strokes: [[CGPoint]]) async -> Marks? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let bounds = CGDisplayBounds(id)   // global, top-left origin
        let main = NSScreen.screens[0].frame
        // View points (bottom-left, per screen) → display-local points (top-left origin).
        let local = strokes.map { s in s.map { p in CGPoint(x: screen.frame.minX + p.x - bounds.minX, y: (main.maxY - (screen.frame.minY + p.y)) - bounds.minY) } }
        var box = CGRect(origin: local[0][0], size: .zero)
        for s in local { for p in s { box = box.union(CGRect(origin: p, size: .zero)) } }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        func shot(_ rect: CGRect, scale: CGFloat) async -> CGImage? {
            let c = SCStreamConfiguration()
            c.sourceRect = rect
            c.width = Int(rect.width * scale); c.height = Int(rect.height * scale)
            c.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c) else { return nil }
            return annotate(img, strokes: local, rect: rect, scale: scale)
        }
        let full = CGRect(origin: .zero, size: bounds.size)
        let fullScale = min(1568 / max(bounds.width, bounds.height), 2)
        let zoom = box.insetBy(dx: -max(40, box.width * 0.3), dy: -max(40, box.height * 0.3)).intersection(full)
        var images: [CGImage] = []
        if let a = await shot(full, scale: fullScale) { images.append(a) }
        if let b = await shot(zoom, scale: min(2, 1200 / max(zoom.width, zoom.height))) { images.append(b) }
        guard !images.isEmpty else { return nil }
        return Marks(images: images, rect: box.offsetBy(dx: bounds.minX, dy: bounds.minY))
    }

    /// Draws the strokes (display-local, top-left origin) onto a screenshot of `rect` taken at `scale`.
    private static func annotate(_ img: CGImage, strokes: [[CGPoint]], rect: CGRect, scale: CGFloat) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for s in strokes {
            let pts = s.map { CGPoint(x: ($0.x - rect.minX) * scale, y: CGFloat(img.height) - ($0.y - rect.minY) * scale) }   // CG: bottom-left
            for (i, (color, width)) in glowLayers.enumerated() {
                ctx.setShadow(offset: .zero, blur: (i == glowLayers.count - 1 ? 8 : 0) * scale, color: glowTint.cgColor)
                ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width * scale)
                ctx.addLines(between: pts); ctx.strokePath()
            }
        }
        return ctx.makeImage() ?? img
    }

    /// Neon white: wide soft haze (slightly icy so it shows on white too), tighter glow, hot core with a blurred halo.
    static let glowTint = NSColor(red: 0.8, green: 0.93, blue: 1, alpha: 1)
    static let glowLayers: [(NSColor, CGFloat)] = [
        (glowTint.withAlphaComponent(0.14), 14),
        (glowTint.withAlphaComponent(0.3), 8),
        (NSColor.white.withAlphaComponent(0.7), 4),
        (NSColor.white, 2),
    ]

    // MARK: windows

    private final class OverlayWindow: NSWindow {
        let target: NSScreen
        let canvas: Canvas
        init(screen: NSScreen) {
            self.target = screen
            canvas = Canvas(frame: NSRect(origin: .zero, size: screen.frame.size))
            super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            isOpaque = false; backgroundColor = .clear; hasShadow = false
            level = .screenSaver
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            contentView = canvas
        }
        override var canBecomeKey: Bool { true }
    }

    private final class Canvas: NSView {
        var strokes: [[CGPoint]] = []
        var hint = ""
        var dim = true
        var onStrokeEnd: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with e: NSEvent) { strokes.append([convert(e.locationInWindow, from: nil)]); needsDisplay = true }
        override func mouseDragged(with e: NSEvent) { strokes[strokes.count - 1].append(convert(e.locationInWindow, from: nil)); needsDisplay = true }
        override func mouseUp(with e: NSEvent) {
            if let last = strokes.last, last.count <= 2 { strokes.removeLast() }   // a click, not a mark
            needsDisplay = true
            if strokes.last?.count ?? 0 > 2 { onStrokeEnd?() }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard dim else { drawStrokes(); return }
            NSColor.black.withAlphaComponent(0.18).setFill(); bounds.fill()
            if strokes.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.white]
                let s = NSAttributedString(string: hint, attributes: attrs)
                let size = s.size()
                s.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 90))
            }
            drawStrokes()
        }

        private func drawStrokes() {
            for stroke in strokes where stroke.count > 1 {
                let path = NSBezierPath()
                path.move(to: stroke[0])
                for p in stroke.dropFirst() { path.line(to: p) }
                path.lineCapStyle = .round; path.lineJoinStyle = .round
                let layers = MarkOverlay.glowLayers
                for (i, (color, width)) in layers.enumerated() {
                    NSGraphicsContext.saveGraphicsState()
                    if i == layers.count - 1 {   // the hot core carries a real blurred halo
                        let sh = NSShadow(); sh.shadowBlurRadius = 8; sh.shadowColor = MarkOverlay.glowTint; sh.set()
                    }
                    path.lineWidth = width
                    color.setStroke(); path.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }
}
