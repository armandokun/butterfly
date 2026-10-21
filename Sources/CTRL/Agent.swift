import AppKit
import EventKit
import FoundationModels

/// Second layer: when Jev decides a request needs understanding (read something, pull out details, several steps),
/// Apple's on-device model plans it and calls these tools. Jev stays the fast first layer for everything else.
///
/// "Grab the last message and put it in my calendar" → reads the front window → create_calendar_event(…).
@MainActor
enum Agent {
    struct Done: Sendable {
        let symbol: String; let text: String
        var created: String? = nil   // calendar item identifier, so "undo" can remove it
    }

    /// Removes what the agent created (for "undo").
    static func remove(_ ids: [String]) -> Int {
        var n = 0
        for id in ids {
            if let e = store.event(withIdentifier: id) { if (try? store.remove(e, span: .thisEvent, commit: true)) != nil { n += 1 } }
            else if let r = store.calendarItem(withIdentifier: id) as? EKReminder { if (try? store.remove(r, commit: true)) != nil { n += 1 } }
        }
        return n
    }

    /// Runs a normal CTRL command ("open Slack", "set a timer for 5 minutes"); set by the notch model.
    static var runCommand: (@MainActor (String) async -> String)?
    static var typeText: (@MainActor (String) async -> Void)?
    /// CLI tests: tools report what they would do, nothing is saved.
    nonisolated(unsafe) static var dryRun = false

    /// `client`: Jev, used to point at the exact message/paragraph you mean (the small model is bad at "the last one").
    static func run(_ request: String, app: NSRunningApplication?, client: TypeSafeClient? = nil) async throws -> [Done] {
        var screen = ProcessInfo.processInfo.environment["CTRL_SCREEN"].map { (text: $0, selected: false) }
        if screen == nil { screen = await ScreenReader.text(of: app) }
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { try? (screen?.text ?? "").write(toFile: "/tmp/ctrl-screen.txt", atomically: true, encoding: .utf8) }
        var focus: String?
        if let screen, !screen.selected, let client {
            // Jev points at the item on a screenshot (it sees layout, columns, bubbles); only that part is read.
            if let app, let image = try? await ScreenReader.windowImage(app) {
                do { focus = try await locate(request, in: image, client: client) } catch { if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { print("  locate error:", error) } }
            }
            if focus == nil { focus = try? await pick(request, from: screen.text, client: client) }
        }
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" { print("  focus:", focus ?? "-") }
        let log = Log()
        let source = focus ?? request
        let tools: [any Tool] = [CreateEvent(log: log, source: source, request: request), CreateReminder(log: log, source: source), RunCommand(log: log), TypeText(log: log)]
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let instructions = """
        You carry out the user's spoken request on their Mac by calling tools. Do it, don't explain it.
        Now: \(f.string(from: now)) (\(TimeZone.current.identifier)). 
        For dates and times, pass the words as written ("Friday at 7pm", "tomorrow at 5"); the app works out the exact date.
        The screen text comes from OCR of the app in front and may include menus and buttons: ignore those.
        "The last message" is the bottom-most message in the conversation.
        If the request is only about apps, windows, music, volume, timers, or settings, use run_command with a short plain command.
        After the tools run, reply with one short sentence saying what you did.
        """
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        var prompt = "The user said: “\(request)”\nApp in front: \(app?.localizedName ?? "unknown")\n"
        if let focus {
            prompt += "The item the user means (use only this for details):\n---\n\(focus)\n---"
        } else if let screen {
            prompt += "\(screen.selected ? "Selected text" : "Text on screen"):\n---\n\(screen.text.suffix(6000))\n---"
        }
        let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
        let done = log.items
        if done.isEmpty { return [Done(symbol: "sparkles", text: r.content.trimmingCharacters(in: .whitespacesAndNewlines))] }
        return done
    }

    /// Jev Box on the window screenshot → crop → OCR just that. Nil when the request is about the whole screen.
    private static func locate(_ request: String, in image: CGImage, client: TypeSafeClient) async throws -> String? {
        guard let jpeg = Self.jpeg(image, maxSide: 1568) else { return nil }
        let ref = "win-" + UUID().uuidString
        let r = try await client.systemOne(
            state: ["spoken_command": request, "window": ref, "note": "In chat apps the newest message is the bottom-most bubble in the conversation, not the chat list on the left."],
            questions: [
                "item": .box("the one specific item in `window` the user refers to in `spoken_command` (a message bubble, email, invite, event details, paragraph). Include all of its text"),
                "specific": .noul("Does `spoken_command` refer to one specific item on screen (a message, email, invite), rather than the whole screen?"),
            ],
            images: [.init(ref: ref, jpeg: jpeg)])
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1" {
            print("  box: \(r.box("item").map { "\($0.box) conf=\(String(format: "%.2f", $0.confidence))" } ?? "-") specific=\(String(format: "%.2f", r.noul("specific") ?? -1))")
        }
        guard (r.noul("specific") ?? 0) >= 0.5, let b = r.box("item"), b.confidence >= 0.3 else { return nil }
        // A little margin so edge lines aren't cut.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: max(0, b.box.left - 0.015) * w, y: max(0, b.box.top - 0.015) * h,
                          width: (min(1, b.box.right + 0.015) - max(0, b.box.left - 0.015)) * w,
                          height: (min(1, b.box.bottom + 0.015) - max(0, b.box.top - 0.015)) * h)
        guard rect.width > 20, rect.height > 10, let crop = image.cropping(to: rect.integral) else { return nil }
        let text = try await ScreenReader.text(in: crop).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 8 ? text : nil
    }

    /// Jev takes images up to ~1568 px on the long side.
    private static func jpeg(_ image: CGImage, maxSide: CGFloat) -> Data? {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
    }

    /// Jev picks the block of screen text the request is about ("the last message", "this email", "the invite").
    /// Nil when the request is about the whole screen or nothing fits.
    private static func pick(_ request: String, from text: String, client: TypeSafeClient) async throws -> String? {
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 12 }
        guard blocks.count >= 2 else { return nil }
        let recent = Array(blocks.suffix(40))
        var opts = ["all": "the request is about the whole screen or page, not one specific item"]
        for (i, b) in recent.enumerated() {
            let pos = i == recent.count - 1 ? "the last / bottom-most block" : "block \(i + 1) of \(recent.count) from the top"
            opts["b\(i)"] = "\(pos): “\(b.replacingOccurrences(of: "\n", with: " ").prefix(220))”"
        }
        let r = try await client.systemOne(state: ["spoken_command": request, "note": "Blocks are the screen's text from top to bottom. In chats, the newest message is at the bottom."],
                                           questions: ["item": .choice("Which block of on-screen text is the specific thing the user refers to (e.g. the last message, the invite, this email)?", options: opts)])
        if ProcessInfo.processInfo.environment["CTRL_DEBUG"] == "1", let a = r.choice("item") { print("  item: \(a.choice) (\(String(format: "%.2f", a.confidence)))") }
        guard let a = r.choice("item"), a.choice != "all", a.confidence >= 0.35, let i = Int(a.choice.dropFirst()), recent.indices.contains(i) else { return nil }
        return recent[i]
    }

    // MARK: Shared

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Done] = []
        func add(_ d: Done) { lock.withLock { list.append(d) } }
        var items: [Done] { lock.withLock { list } }
    }

    nonisolated(unsafe) static let store = EKEventStore()

    /// "friday at 7", "tomorrow at 5pm", "Oct 24 14:00". Code does the date math, not the model.
    /// A bare hour 1–7 means afternoon ("call at 5" → 17:00), like people mean it.
    nonisolated static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let iso = isoDate(t) { return iso }
        if let n = numericDate(t) { return n }
        let words = t.lowercased()
        let cal = Calendar.current
        let now = Date()
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              var d = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))?.date else { return nil }
        let hasMeridiem = words.range(of: #"\b(am|pm|a\.m\.|p\.m\.|morning|noon|midnight)\b"#, options: .regularExpression) != nil
        let h = cal.component(.hour, from: d)
        if !hasMeridiem, (1...7).contains(h) { d = d.addingTimeInterval(12 * 3600) }
        // Weekday names mean the next one coming, not one in the past.
        if d < now.addingTimeInterval(-3600), !words.contains("yesterday") { d = cal.date(byAdding: .day, value: 7, to: d) ?? d }
        return d
    }

    /// "10.21 17:30", "21.10 17:30", "10/21 5:30", "2026.10.21 17:30", "rytoj 17:30" — formats Apple's detector misreads.
    /// Month/day order: whichever is valid; if both are, the one closest ahead.
    nonisolated static func numericDate(_ t: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let lower = t.lowercased()
        var time: (Int, Int)?
        if let m = lower.firstMatch(of: #/\b(\d{1,2}):(\d{2})\b/#), let h = Int(m.1), let mi = Int(m.2), h < 24, mi < 60 { time = (h, mi) }
        else if let m = lower.firstMatch(of: #/\b(\d{1,2})\s*(am|pm)\b/#), let h = Int(m.1), h <= 12 { time = ((h % 12) + (m.2 == "pm" ? 12 : 0), 0) }
        // Date part: [yyyy.]a.b  (not the time itself)
        var candidates: [DateComponents] = []
        if let m = lower.firstMatch(of: #/(?:\b(\d{4})[-./])?\b(\d{1,2})[./](\d{1,2})\b/#), let a = Int(m.2), let b = Int(m.3) {
            let year = m.1.flatMap { Int($0) }
            for (mo, d) in [(a, b), (b, a)] where (1...12).contains(mo) && (1...31).contains(d) {
                candidates.append(DateComponents(year: year ?? cal.component(.year, from: now), month: mo, day: d))
            }
        }
        // Relative days (English + Lithuanian, since that's what messages here are in).
        if candidates.isEmpty {
            var offset: Int?
            if lower.contains("tomorrow") || lower.contains("rytoj") { offset = 1 }
            else if lower.contains("poryt") { offset = 2 }
            else if lower.contains("today") || lower.contains("šiandien") || lower.contains("siandien") || lower.contains("tonight") { offset = 0 }
            guard let offset, time != nil else { return nil }
            candidates.append(cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: offset, to: now)!))
        }
        let dates: [Date] = candidates.compactMap { c in
            var c = c
            c.hour = time?.0 ?? 0; c.minute = time?.1 ?? 0
            guard var d = cal.date(from: c) else { return nil }
            if d < now.addingTimeInterval(-86400 * 2), c.year == cal.component(.year, from: now) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
            return d
        }
        return dates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    /// Default calendar for new events (yours, not a shared one that happens to be the system default).
    nonisolated static let defaultCalendarName = "Home"

    /// A calendar you named in the request ("…in my Work calendar") wins; then the model's pick; then Home; then the system default.
    nonisolated static func calendar(named model: String, request: String) -> EKCalendar? {
        let all = store.calendars(for: .event).filter(\.allowsContentModifications)
        let said = request.lowercased()
        // Longest name you actually said ("Brigitos Home" beats "Home").
        if let c = all.filter({ said.contains($0.title.lowercased()) }).max(by: { $0.title.count < $1.title.count }) { return c }
        func exact(_ n: String) -> EKCalendar? {
            let n = n.trimmingCharacters(in: .whitespaces).lowercased()
            guard !n.isEmpty else { return nil }
            // Your own calendar over a shared one with the same name.
            return all.filter { $0.title.lowercased() == n }.min { ($0.type == .subscription ? 1 : 0) < ($1.type == .subscription ? 1 : 0) }
        }
        return exact(model) ?? exact(defaultCalendarName) ?? store.defaultCalendarForNewEvents ?? all.first
    }

    /// The model's date words, checked against the source text: if it dropped the time (or the date),
    /// the one written in the message wins. Code reads "10.21 17:30" more reliably than the small model copies it.
    nonisolated static func resolve(_ words: String, source: String) -> Date? {
        let fromSource = hasTime(source) ? (numericDate(source) ?? date(source)) : nil
        guard let d = date(words) else { return fromSource }
        guard let s = fromSource else { return d }
        let cal = Calendar.current
        if !hasTime(words), cal.isDate(d, inSameDayAs: s) { return s }   // "10.21" + message says 17:30
        return d
    }

    /// Does the text name a clock time? (Then it's never an all-day event.)
    nonisolated static func hasTime(_ t: String) -> Bool {
        t.lowercased().firstMatch(of: #/\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\bat \d/#) != nil
    }

    nonisolated private static func isoDate(_ t: String) -> Date? {
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    nonisolated static func short(_ d: Date, allDay: Bool = false) -> String {
        allDay ? d.formatted(.dateTime.weekday(.abbreviated).day().month()) : d.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
    }

    // MARK: Tools

    enum Kind { case string, int, bool }

    nonisolated static func schema(_ name: String, _ props: [(String, String, Kind)]) -> GenerationSchema {
        let root = DynamicGenerationSchema(name: name, properties: props.map { p in
            let type: DynamicGenerationSchema = switch p.2 {
            case .string: DynamicGenerationSchema(type: String.self)
            case .int: DynamicGenerationSchema(type: Int.self)
            case .bool: DynamicGenerationSchema(type: Bool.self)
            }
            return DynamicGenerationSchema.Property(name: p.0, description: p.1, schema: type)
        })
        return try! GenerationSchema(root: root, dependencies: [])
    }

    nonisolated static func str(_ c: GeneratedContent, _ key: String) -> String {
        ((try? c.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct CreateEvent: Tool {
        let log: Log
        let source: String   // the message/request the details come from
        let request: String  // what you said ("…in my Work calendar")
        let name = "create_calendar_event"
        let description = "Adds an event to the user's calendar. Use for meetings, invites, appointments, dinners, flights, anything with a date."

        // Schema built at runtime (no @Generable macro: works with Command Line Tools, no Xcode needed).
        var parameters: GenerationSchema { Agent.schema("CreateEvent", [
            ("title", "Short title saying what it is, in the message's language, e.g. 'Dinner with Tom', 'Odontologė Urtė'", .string),
            ("start", "When it starts, copied as words from the message or request, exactly as written including the numbers, e.g. '10.21 17:30', 'rytoj 17:30', 'Friday at 7pm', 'tomorrow at 5'. Don't calculate or translate dates yourself", .string),
            ("durationMinutes", "Length in minutes; 60 if unknown", .int),
            ("allDay", "True only for all-day events like birthdays or holidays", .bool),
            ("location", "Street address, place, or meeting link from the message; empty if none. Never the app name", .string),
            ("notes", "Extra details worth keeping (who, agenda, link), or empty", .string),
            ("calendar", "Calendar name only if the user said one (e.g. 'Work'), else empty", .string),
        ]) }
        struct Arguments: ConvertibleFromGeneratedContent {
            var title, start, location, notes, calendar: String
            var durationMinutes: Int
            var allDay: Bool
            init(_ c: GeneratedContent) throws {
                title = Agent.str(c, "title"); start = Agent.str(c, "start"); location = Agent.str(c, "location")
                notes = Agent.str(c, "notes"); calendar = Agent.str(c, "calendar")
                durationMinutes = min(1440, max(5, (try? c.value(Int.self, forProperty: "durationMinutes")) ?? 60))
                allDay = (try? c.value(Bool.self, forProperty: "allDay")) ?? false
            }
        }

        func call(arguments a: Arguments) async throws -> String {
            guard let start = Agent.resolve(a.start, source: source) else { return "Couldn't read the date '\(a.start)'. Say it like 'Friday at 7pm'." }
            if Agent.dryRun {
                let allDay = a.allDay && !Agent.hasTime(a.start) && !Agent.hasTime(source)
                log.add(Done(symbol: "calendar.badge.plus", text: "[dry] \(a.title) · \(Agent.short(start, allDay: allDay)) · cal=\(Agent.calendar(named: a.calendar, request: request)?.title ?? "-") · \(a.durationMinutes)m · \(a.location) · \(a.notes.prefix(60))"))
                return "Added."
            }
            guard (try? await Agent.store.requestFullAccessToEvents()) == true else { return "Calendar access denied." }
            let allDay = a.allDay && !Agent.hasTime(a.start) && !Agent.hasTime(source)   // "17:30" is never all-day
            let e = EKEvent(eventStore: Agent.store)
            guard let cal = Agent.calendar(named: a.calendar, request: request) else { return "No writable calendar." }
            e.calendar = cal
            e.title = a.title
            e.isAllDay = allDay
            e.startDate = start
            e.endDate = allDay ? start.addingTimeInterval(86400) : start.addingTimeInterval(TimeInterval(a.durationMinutes * 60))
            if !a.location.isEmpty, a.location.lowercased() != "messages", a.location.lowercased() != "mail" { e.location = a.location }
            if !a.notes.isEmpty { e.notes = a.notes }
            try Agent.store.save(e, span: .thisEvent)
            log.add(Done(symbol: "calendar.badge.plus", text: "\(a.title) · \(Agent.short(start, allDay: allDay)) · \(cal.title)", created: e.eventIdentifier))
            return "Added '\(a.title)' on \(Agent.short(start, allDay: allDay))."
        }
    }

    struct CreateReminder: Tool {
        let log: Log
        let source: String
        let name = "create_reminder"
        let description = "Adds a to-do to the user's Reminders. Use for tasks without a fixed meeting time ('remind me to…', 'add to my to-do list')."

        var parameters: GenerationSchema { Agent.schema("CreateReminder", [
            ("title", "What to do, e.g. 'Call mom'", .string),
            ("due", "When to remind, copied as words, e.g. 'tomorrow at 5', 'Monday morning'; empty for no time. Don't calculate dates yourself", .string),
        ]) }
        struct Arguments: ConvertibleFromGeneratedContent {
            var title, due: String
            init(_ c: GeneratedContent) throws { title = Agent.str(c, "title"); due = Agent.str(c, "due") }
        }

        func call(arguments a: Arguments) async throws -> String {
            if Agent.dryRun { log.add(Done(symbol: "checklist", text: "[dry] \(a.title) · due \(Agent.resolve(a.due, source: source).map { Agent.short($0) } ?? "none")")); return "Added." }
            guard (try? await Agent.store.requestFullAccessToReminders()) == true else { return "Reminders access denied." }
            let r = EKReminder(eventStore: Agent.store)
            r.calendar = Agent.store.defaultCalendarForNewReminders()
            r.title = a.title
            if let d = Agent.resolve(a.due, source: source) {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                r.addAlarm(EKAlarm(absoluteDate: d))
            }
            try Agent.store.save(r, commit: true)
            log.add(Done(symbol: "checklist", text: a.title + (Agent.resolve(a.due, source: source).map { " · " + Agent.short($0) } ?? ""), created: r.calendarItemIdentifier))
            return "Reminder added: \(a.title)."
        }
    }

    struct RunCommand: Tool {
        let log: Log
        let name = "run_command"
        let description = "Runs one simple Mac command, phrased like the user would say it: 'open Slack', 'set a timer for 10 minutes', 'turn on do not disturb', 'move this window left', 'play music'."

        var parameters: GenerationSchema { Agent.schema("RunCommand", [("command", "One short command", .string)]) }
        struct Arguments: ConvertibleFromGeneratedContent {
            var command: String
            init(_ c: GeneratedContent) throws { command = Agent.str(c, "command") }
        }

        func call(arguments a: Arguments) async throws -> String {
            let run = await MainActor.run { Agent.runCommand }
            let result = run == nil ? "unavailable" : await run!(a.command)
            log.add(Done(symbol: "command", text: a.command))
            return result
        }
    }

    struct TypeText: Tool {
        let log: Log
        let name = "type_text"
        let description = "Types text into the text field the user is in (a reply, a note, a message)."

        var parameters: GenerationSchema { Agent.schema("TypeText", [("text", "Exactly the text to type", .string)]) }
        struct Arguments: ConvertibleFromGeneratedContent {
            var text: String
            init(_ c: GeneratedContent) throws { text = Agent.str(c, "text") }
        }

        func call(arguments a: Arguments) async throws -> String {
            if let t = await MainActor.run(body: { Agent.typeText }) { await t(a.text) }
            log.add(Done(symbol: "keyboard", text: "Typed “\(a.text.prefix(40))”"))
            return "Typed."
        }
    }
}
