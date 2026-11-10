import AppKit
import ScreenCaptureKit
import Vision

/// Front-window capture + on-device OCR (for screen memory).
@MainActor
enum ScreenReader {
    /// The app's front window as an image (2× for sharp OCR).
    static func windowImage(_ app: NSRunningApplication) async throws -> CGImage? {
        try await windowCapture(app)?.image
    }

    /// The window image plus its frame on screen (global, top-left origin — same space as accessibility frames).
    static func windowCapture(_ app: NSRunningApplication) async throws -> (image: CGImage, frame: CGRect)? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 100 })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return (image, window.frame)
    }

    // MARK: Input masking

    private static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField", "AXSearchField", "AXComboBox"]

    /// Screen frames of every editable field in the app's focused window: what you type, never what you read.
    nonisolated static func inputFrames(pid: pid_t) async -> [CGRect] {
        await Task.detached(priority: .utility) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Electron apps (Slack, Cursor, Notion) only build their tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var win: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return [] }
            let wf = frame(w as! AXUIElement) ?? .zero
            var out: [CGRect] = [], stack: [(AXUIElement, Int)] = [(w as! AXUIElement, 0)], seen = 0
            let deadline = Date().addingTimeInterval(0.8)
            while let (el, depth) = stack.popLast(), seen < 4000, Date() < deadline {
                seen += 1
                if let kind = inputKind(el), let r = frame(el), r.width > 4, r.height > 4 {
                    // A field filling most of the window is a document or code editor: that's the work memory is for.
                    // Passwords are always masked.
                    if kind == .secure || r.width * r.height < wf.width * wf.height * 0.4 { out.append(r) }
                    continue
                }
                guard depth < 40 else { continue }
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
                    stack += arr.map { ($0, depth + 1) }
                }
            }
            return out
        }.value
    }

    private enum InputKind { case field, secure }

    nonisolated private static func inputKind(_ el: AXUIElement) -> InputKind? {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v) == .success, (v as? String) == "AXSecureTextField" { return .secure }
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success, let role = v as? String, inputRoles.contains(role) {
            return role == "AXSecureTextField" ? .secure : .field
        }
        // Web: contenteditable boxes (chat composers).
        if AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &v) == .success, let anc = v, CFEqual(anc, el) { return .field }
        return nil
    }

    nonisolated private static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Paints over each field so neither the stored frame nor its OCR text holds what was typed.
    nonisolated static func mask(_ image: CGImage, window: CGRect, fields: [CGRect]) -> CGImage {
        let hits = fields.map { $0.intersection(window) }.filter { !$0.isNull && $0.width > 2 && $0.height > 2 }
        guard !hits.isEmpty, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let sx = CGFloat(image.width) / window.width, sy = CGFloat(image.height) / window.height
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        for r in hits {
            // AX is top-left origin; the bitmap is bottom-left.
            let x = (r.minX - window.minX) * sx, y = CGFloat(image.height) - (r.maxY - window.minY) * sy
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: r.width * sx, height: r.height * sy), cornerWidth: 6, cornerHeight: 6, transform: nil))
        }
        ctx.fillPath()
        return ctx.makeImage() ?? image
    }

    /// Focused window title (accessibility).
    static func windowTitle(_ app: NSRunningApplication) -> String {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return "" }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return (title as? String) ?? ""
    }

    /// OCR, grouped into blocks (bubbles, paragraphs) that respect columns: a sidebar line never joins a message.
    nonisolated static func text(in image: CGImage) async throws -> String {
        try await Task.detached {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([req])
            let lines = (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { (text: $0.string, box: o.boundingBox) } }
                .sorted { $0.box.maxY > $1.box.maxY }
            var blocks: [(lines: [String], last: CGRect, top: CGFloat, left: CGFloat)] = []
            for l in lines {
                if let i = blocks.lastIndex(where: { b in
                    abs(b.left - l.box.minX) < 0.03 && b.last.minY - l.box.maxY < l.box.height * 0.8 && b.last.minY >= l.box.maxY - l.box.height * 0.5
                }) {
                    blocks[i].lines.append(l.text); blocks[i].last = l.box
                } else {
                    blocks.append(([l.text], l.box, l.box.maxY, l.box.minX))
                }
            }
            return blocks.sorted { $0.top > $1.top }.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n")
        }.value
    }
}
