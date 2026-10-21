import AppKit
import AVFoundation
import FoundationModels
import ScreenCaptureKit
import Vision

/// "Summarize this page", "what does this error say", "how much is it", "reply saying I'll be there", "read this aloud".
/// Reads the selected text, or the front window's text (on-device OCR), and asks Apple's on-device model.
@MainActor
enum ScreenReader {
    enum Action: String { case summarize, explain, ask, reply, readAloud = "read_aloud", stopReading = "stop_reading" }

    static let actionQuestion = TypeSafeClient.Question.choice("What does the user want done with what's on screen?", options: [
        "summarize": "summarize / give the gist / tl;dr of this page, article, email, document, or window",
        "explain": "explain or tell what this error, message, dialog, or text says / means",
        "ask": "answer a specific question about what's on screen (e.g. 'what's the price', 'when is the deadline', 'who sent this')",
        "reply": "write and type a reply or response to this email/message with the given content (e.g. 'reply saying I'll be there')",
        "read_aloud": "read the selected text or this page out loud",
        "stop_reading": "stop reading aloud, be quiet, shut up",
    ])

    static var available: Bool { SystemLanguageModel.default.isAvailable }

    private static let voice = AVSpeechSynthesizer()

    // MARK: Text on screen

    /// Selected text if there is some, else everything readable in the front window.
    static func text(of app: NSRunningApplication?) async -> (text: String, selected: Bool)? {
        if let s = selectedText(), s.count > 2, ProcessInfo.processInfo.environment["CTRL_WINDOW_PNG"] == nil { return (s, true) }
        guard let app, let t = try? await ocr(app), !t.isEmpty else { return nil }
        return (t, false)
    }

    private static func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        return (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app's front window as an image (2× for sharp OCR).
    static func windowImage(_ app: NSRunningApplication) async throws -> CGImage? {
        if let path = ProcessInfo.processInfo.environment["CTRL_WINDOW_PNG"] {   // CLI tests
            return NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 100 })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    private static func ocr(_ app: NSRunningApplication) async throws -> String {
        guard let image = try await windowImage(app) else { return "" }
        return try await text(in: image)
    }

    /// OCR, grouped into blocks (bubbles, paragraphs) that respect columns: a sidebar line never joins a message.
    /// Blocks are separated by blank lines, top to bottom.
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
                // Join the block right above it in the same column (same left edge, small gap).
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

    // MARK: Apple's on-device model

    /// `request`: what you said. Returns the answer (or reply text to type).
    static func answer(_ action: Action, request: String, text: String, app: String?) async throws -> String {
        let instructions: String
        switch action {
        case .reply:
            instructions = """
            You write replies for the user. Output only the reply text, ready to send, in the user's voice: \
            no subject line, no quotes, no greeting placeholders like [Name], no explanation. Match the language and tone of the message. Keep it short.
            """
        default:
            instructions = """
            You help the user understand what's on their screen. The screen text comes from OCR and may contain menus, buttons, and noise: ignore those. \
            Answer in at most 3 short sentences, plain text, no markdown, no preamble.
            """
        }
        let session = LanguageModelSession(instructions: instructions)
        let screen = String(text.prefix(7000))
        let prompt = """
        The user said: “\(request)”
        App: \(app ?? "unknown")
        Text on screen:
        ---
        \(screen)
        ---
        \(action == .reply ? "Write the reply." : action == .summarize ? "Summarize it." : action == .explain ? "Explain what it says and what to do, if anything." : "Answer the user's question.")
        """
        let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3))
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
    }

    // MARK: Speech

    static func speak(_ text: String) {
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(text.prefix(4000)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        voice.speak(u)
    }

    @discardableResult static func stop() -> Bool {
        guard voice.isSpeaking else { return false }
        voice.stopSpeaking(at: .immediate)
        return true
    }
}
