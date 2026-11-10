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

    /// What you typed, never what you read: password fields, plus every field you've typed into in this window
    /// (the one you're in now, and ones you filled and left). Pre-filled text, URLs and labels stay readable.
    struct Field: Sendable { let rect: CGRect; let chars: Int }

    /// Fields you typed into, per window. Captures run one at a time, so no lock.
    nonisolated(unsafe) private static var typedInto: (window: AXUIElement?, fields: [AXUIElement]) = (nil, [])

    nonisolated static func inputFrames(pid: pid_t) async -> [Field] {
        await Task.detached(priority: .utility) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Electron apps (Slack, Cursor, Notion) only build their tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var win: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return [] }
            let window = w as! AXUIElement, wf = frame(window) ?? .zero
            if typedInto.window.map({ !CFEqual($0, window) }) ?? true { typedInto = (window, []) }
            // A document or code editor filling most of the window is the work memory is for: never masked.
            func small(_ r: CGRect) -> Bool { r.width * r.height < wf.width * wf.height * 0.4 }

            // The field you're in, if you typed in the last few seconds.
            var focused: CFTypeRef?
            if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 6,
               AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let f = focused,
               let field = inputAncestor(f as! AXUIElement), !typedInto.fields.contains(where: { CFEqual($0, field) }) {
                typedInto.fields.append(field)
            }
            var out: [Field] = []
            for el in typedInto.fields { if let r = frame(el), r.width > 4, r.height > 4, small(r) { out.append(Field(rect: r, chars: length(el))) } }

            // Sensitive fields wherever they are, typed or autofilled: passwords, cards, IBANs, codes.
            var stack: [(AXUIElement, Int)] = [(window, 0)], seen = 0
            let deadline = Date().addingTimeInterval(0.8)
            while let (el, depth) = stack.popLast(), seen < 4000, Date() < deadline {
                seen += 1
                if let kind = inputKind(el) {
                    if kind == .secure || sensitive(el), let r = frame(el), r.width > 4, r.height > 4,
                       !out.contains(where: { $0.rect == r }) { out.append(Field(rect: r, chars: kind == .secure ? max(length(el), 8) : length(el))) }
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

    /// The editable field containing `el` (web composers focus an inner node).
    nonisolated private static func inputAncestor(_ el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        for _ in 0..<6 {
            guard let c = cur else { return nil }
            if inputKind(c) != nil { return c }
            var p: CFTypeRef?
            cur = AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &p) == .success ? (p as! AXUIElement) : nil
        }
        return nil
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

    /// Labels that mean "don't remember this" (English + Lithuanian), matched on the field's placeholder, label, title and id.
    private static let sensitiveWords = ["card", "cvc", "cvv", "csc", "security code", "expir", "mm/yy", "mm / yy", "iban", "swift code", "bic",
                                         "account number", "routing", "sort code", "ssn", "social security", "pin", "otp", "one-time",
                                         "verification code", "2fa", "passcode", "tax id", "personal code", "kortel", "asmens kod", "sąskait"]

    nonisolated private static func sensitive(_ el: AXUIElement) -> Bool {
        var label = ""
        for attr in ["AXPlaceholderValue", kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, "AXDOMIdentifier", kAXIdentifierAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let t = v as? String { label += " " + t.lowercased() }
        }
        var t: CFTypeRef?, tv: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXTitleUIElementAttribute as CFString, &t) == .success, let te = t,
           AXUIElementCopyAttributeValue(te as! AXUIElement, kAXValueAttribute as CFString, &tv) == .success, let s = tv as? String { label += " " + s.lowercased() }
        let words = Set(label.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        // Phrases anywhere; single words at a word start ("cardholder", not "dashboard"); short ones whole ("pin", not "pinned").
        if sensitiveWords.contains(where: { k in
            k.contains(" ") || k.contains("/") || k.contains("-") ? label.contains(k) : k.count <= 3 ? words.contains(k) : words.contains { $0.hasPrefix(k) }
        }) { return true }
        // Unlabelled but looks like a card number.
        if let v = value(el) { return luhn(v) }
        return false
    }

    /// 13–19 digits passing the Luhn check: a card number.
    nonisolated private static func luhn(_ s: String) -> Bool {
        let d = s.filter { $0 != " " && $0 != "-" }
        guard (13...19).contains(d.count), d.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (i, c) in d.reversed().enumerated() { var n = c.wholeNumberValue!; if i % 2 == 1 { n *= 2; if n > 9 { n -= 9 } }; sum += n }
        return sum % 10 == 0
    }

    nonisolated private static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let t = v as? String else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// How many characters are typed in the field (0 = empty, shows as empty).
    nonisolated private static func length(_ el: AXUIElement) -> Int {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let t = v as? String {
            return t.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success, let n = v as? Int { return n }
        return 8
    }

    nonisolated private static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Replaces what's typed in each field with asterisks (one per character, on the field's own background),
    /// so neither the stored frame nor its OCR text holds it.
    nonisolated static func mask(_ image: CGImage, window: CGRect, fields: [Field]) -> CGImage {
        let sx = CGFloat(image.width) / window.width, sy = CGFloat(image.height) / window.height
        let rects = fields.compactMap { f -> (CGRect, Int)? in
            let r = f.rect.intersection(window)
            guard !r.isNull, r.width >= 3, r.height >= 3 else { return nil }
            return (CGRect(x: (r.minX - window.minX) * sx, y: (r.minY - window.minY) * sy, width: r.width * sx, height: r.height * sy), f.chars)
        }
        return paint(image, rects, scale: sy)
    }

    /// `rects` in image pixels, top-left origin, each with how many asterisks to draw.
    nonisolated private static func paint(_ image: CGImage, _ rects: [(CGRect, Int)], scale sy: CGFloat) -> CGImage {
        guard !rects.isEmpty, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = data.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
        // Bitmap memory is top row first, like our rects.
        func color(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let xi = min(max(Int(x), 0), image.width - 1), yi = min(max(Int(y), 0), image.height - 1), o = yi * bpr + xi * 4
            return (CGFloat(px[o]) / 255, CGFloat(px[o + 1]) / 255, CGFloat(px[o + 2]) / 255)
        }
        // Sample every background before painting anything.
        let jobs = rects.map { r, n in (CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height), color(r.minX + 1, r.minY + 1), n) }
        for (r, bg, chars) in jobs {
            ctx.setFillColor(CGColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)); ctx.fill(r)
            guard chars > 0 else { continue }
            let dark = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2 < 0.5
            let size = min(r.height * 0.6, 14 * sy)
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let fit = max(1, Int((r.width - 4 * sy) / (size * 0.62)))
            let str = NSAttributedString(string: String(repeating: "*", count: min(chars, fit)), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 1 : 0, alpha: 0.55)])
            // Single-line: centred. Tall boxes: first line.
            let baseline = r.height < 44 * sy ? r.midY - size * 0.35 : r.maxY - 8 * sy - size
            ctx.textPosition = CGPoint(x: r.minX + (r.height < 30 * sy ? 2 * sy : 6 * sy), y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
        }
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
