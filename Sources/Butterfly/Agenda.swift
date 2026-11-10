import AppKit
import EventKit

/// Calendar events: Meetings uses them to name recordings and tell a call from a stray mic.
@MainActor
final class Agenda {
    static let shared = Agenda()

    /// Heads-up: (event, minutes until start).
    var onSoon: ((EKEvent, Int) -> Void)?

    private let store = EKEventStore()
    private var warned: Set<String> = []
    private var ticker: Timer?

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return false }
        NSApp.activate()   // the prompt shows in front of the app asking
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Warnings only start once you've given access (no prompt at launch).
    func start() {
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard hasAccess else { return }
        for e in events(from: Date(), to: Date().addingTimeInterval(6 * 60)) where e.startDate > Date() {
            let key = (e.eventIdentifier ?? e.title ?? "") + "\(e.startDate.timeIntervalSince1970)"
            guard !warned.contains(key) else { continue }
            let minutes = Int((e.startDate.timeIntervalSinceNow / 60).rounded())
            guard minutes <= 5 else { continue }
            warned.insert(key)
            onSoon?(e, max(1, minutes))
        }
    }

    /// Timed events (no all-day ones), in progress or upcoming, soonest first.
    func events(from: Date, to: Date, allDay: Bool = false) -> [EKEvent] {
        guard hasAccess else { return [] }
        let p = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: p)
            .filter { (allDay || !$0.isAllDay) && $0.endDate > from && $0.status != .canceled && !Self.declined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    var next: EKEvent? {
        let now = Date()
        let list = events(from: now, to: now.addingTimeInterval(7 * 86400))
        // A meeting that started up to 10 min ago still counts as "next" (you're probably late for it).
        return list.first { $0.startDate > now.addingTimeInterval(-600) } ?? list.first
    }

    func day(_ offset: Int) -> [EKEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return events(from: offset == 0 ? Date() : start, to: end, allDay: true)
    }

    /// The meeting link: the event URL, or a Zoom/Meet/Teams/FaceTime link in location or notes.
    static func meetingURL(_ e: EKEvent) -> URL? {
        if let u = e.url, ["zoom", "meet.google", "teams", "facetime", "webex", "whereby", "around"].contains(where: { u.absoluteString.contains($0) }) { return u }
        let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|facetime\.apple\.com|webex\.com|whereby\.com)[^\s<>"]*"#
        return text.range(of: pattern, options: .regularExpression).flatMap { URL(string: String(text[$0])) } ?? e.url
    }

    /// "in 25 min · 14:00", "now · until 15:30", "tomorrow 09:00".
    static func when(_ e: EKEvent) -> String {
        let now = Date()
        let time = e.startDate.formatted(date: .omitted, time: .shortened)
        if e.isAllDay { return Calendar.current.isDateInToday(e.startDate) || e.startDate <= now ? "All day today" : "All day · " + e.startDate.formatted(.dateTime.weekday(.wide)) }
        if e.startDate <= now { return "Now · until \(e.endDate.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.startDate.timeIntervalSince(now) / 60)
        if mins < 60 { return "In \(max(1, mins)) min · \(time)" }
        if Calendar.current.isDateInToday(e.startDate) { return "In \(mins / 60) h \(mins % 60) min · \(time)" }
        if Calendar.current.isDateInTomorrow(e.startDate) { return "Tomorrow · \(time)" }
        return e.startDate.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined
    }
}
