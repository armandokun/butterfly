import EventKit
import Foundation

/// Writes calendar events and reminders for the planner's create_event / create_reminder steps.
/// Dates are worked out here, in code, from the words the model copied ("Friday at 7pm", "10.21 17:30"):
/// models are bad at date arithmetic, Foundation isn't.
enum CalendarWriter {
    nonisolated(unsafe) static let store = EKEventStore()

    struct Created { let symbol: String; let text: String; let id: String }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// `source`: the on-screen text the details came from, so a time the model dropped can still be read from it.
    /// `request`: what the user said (a calendar they named wins).
    static func createEvent(title: String, start: String, durationMinutes: Int?, location: String?, notes: String?, calendar: String?, allDay: Bool, source: String, request: String) async throws -> Created {
        guard let date = resolve(start, source: source) else { throw Failure(message: "Couldn't read the date “\(start)”. Say it like “Friday at 7pm”.") }
        guard (try? await store.requestFullAccessToEvents()) == true else { throw Failure(message: "Allow Calendar access for Butterfly") }
        guard let cal = self.calendar(named: calendar ?? "", request: request) else { throw Failure(message: "No writable calendar") }
        let allDay = allDay && !hasTime(start) && !hasTime(source)   // "17:30" is never all-day
        let e = EKEvent(eventStore: store)
        e.calendar = cal
        e.title = title.isEmpty ? "Event" : title
        e.isAllDay = allDay
        e.startDate = date
        e.endDate = allDay ? date.addingTimeInterval(86400) : date.addingTimeInterval(TimeInterval(min(1440, max(5, durationMinutes ?? 60)) * 60))
        if let l = location?.trimmingCharacters(in: .whitespaces), !l.isEmpty, !["messages", "mail", "slack"].contains(l.lowercased()) { e.location = l }
        if let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { e.notes = n }
        try store.save(e, span: .thisEvent)
        return Created(symbol: "calendar.badge.plus", text: "\(e.title ?? "") · \(short(date, allDay: allDay)) · \(cal.title)", id: e.eventIdentifier)
    }

    static func createReminder(title: String, due: String?, source: String) async throws -> Created {
        guard (try? await store.requestFullAccessToReminders()) == true else { throw Failure(message: "Allow Reminders access for Butterfly") }
        let r = EKReminder(eventStore: store)
        r.calendar = store.defaultCalendarForNewReminders()
        r.title = title.isEmpty ? "Reminder" : title
        let when = due.flatMap { resolve($0, source: source) }
        if let d = when {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            r.addAlarm(EKAlarm(absoluteDate: d))
        }
        try store.save(r, commit: true)
        return Created(symbol: "checklist", text: r.title + (when.map { " · " + short($0) } ?? ""), id: r.calendarItemIdentifier)
    }

    /// Removes what was created (for "undo"). Returns how many went.
    static func remove(_ ids: [String]) -> Int {
        var n = 0
        for id in ids {
            if let e = store.event(withIdentifier: id) { if (try? store.remove(e, span: .thisEvent, commit: true)) != nil { n += 1 } }
            else if let r = store.calendarItem(withIdentifier: id) as? EKReminder { if (try? store.remove(r, commit: true)) != nil { n += 1 } }
        }
        return n
    }

    // MARK: Dates

    /// "friday at 7", "tomorrow at 5pm", "Oct 24 14:00". A bare hour 1–7 means afternoon ("call at 5" → 17:00), like people mean it.
    static func date(_ s: String) -> Date? {
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
    static func numericDate(_ t: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let lower = t.lowercased()
        var time: (Int, Int)?
        if let m = lower.firstMatch(of: #/\b(\d{1,2}):(\d{2})\b/#), let h = Int(m.1), let mi = Int(m.2), h < 24, mi < 60 { time = (h, mi) }
        else if let m = lower.firstMatch(of: #/\b(\d{1,2})\s*(am|pm)\b/#), let h = Int(m.1), h <= 12 { time = ((h % 12) + (m.2 == "pm" ? 12 : 0), 0) }
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
    static let defaultCalendarName = "Home"

    /// A calendar you named in the request ("…in my Work calendar") wins; then the model's pick; then Home; then the system default.
    static func calendar(named model: String, request: String) -> EKCalendar? {
        let all = store.calendars(for: .event).filter(\.allowsContentModifications)
        let said = request.lowercased()
        if let c = all.filter({ said.contains($0.title.lowercased()) }).max(by: { $0.title.count < $1.title.count }) { return c }
        func exact(_ n: String) -> EKCalendar? {
            let n = n.trimmingCharacters(in: .whitespaces).lowercased()
            guard !n.isEmpty else { return nil }
            return all.filter { $0.title.lowercased() == n }.min { ($0.type == .subscription ? 1 : 0) < ($1.type == .subscription ? 1 : 0) }
        }
        return exact(model) ?? exact(defaultCalendarName) ?? store.defaultCalendarForNewEvents ?? all.first
    }

    /// The model's date words, checked against the source text: if it dropped the time (or the date),
    /// the one written in the message wins.
    static func resolve(_ words: String, source: String) -> Date? {
        let fromSource = hasTime(source) ? (numericDate(source) ?? date(source)) : nil
        guard let d = date(words) else { return fromSource }
        guard let s = fromSource else { return d }
        if !hasTime(words), Calendar.current.isDate(d, inSameDayAs: s) { return s }   // "10.21" + message says 17:30
        return d
    }

    /// Does the text name a clock time? (Then it's never an all-day event.)
    static func hasTime(_ t: String) -> Bool {
        t.lowercased().firstMatch(of: #/\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\bat \d/#) != nil
    }

    private static func isoDate(_ t: String) -> Date? {
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.dateFormat = fmt; f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    static func short(_ d: Date, allDay: Bool = false) -> String {
        allDay ? d.formatted(.dateTime.weekday(.abbreviated).day().month()) : d.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
    }
}
