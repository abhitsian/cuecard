import EventKit

/// The meeting happening now (or starting within 15 minutes) from the Mac's calendars: title, people, notes.
enum CalendarContext {
    struct Now {
        let title: String
        let attendees: [String]
        let notes: String
        let start: Date
    }

    private static let store = EKEventStore()

    static func current(_ done: @escaping (Now?) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            guard granted else { DispatchQueue.main.async { done(nil) }; return }
            let now = Date()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(20 * 60), calendars: nil)
            let candidates = store.events(matching: predicate).filter {
                !$0.isAllDay && $0.endDate > now.addingTimeInterval(-3 * 60) && $0.startDate < now.addingTimeInterval(15 * 60)
                    && $0.availability != .free
            }
            // Prefer the one that started most recently, and real meetings (with people) over blocks.
            let event = candidates.sorted {
                let a = ($0.attendees?.isEmpty == false ? 0 : 1, abs($0.startDate.timeIntervalSince(now)))
                let b = ($1.attendees?.isEmpty == false ? 0 : 1, abs($1.startDate.timeIntervalSince(now)))
                return a < b
            }.first
            let result = event.map { event -> Now in
                let people = (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
                    .filter { !$0.isEmpty }
                return Now(title: event.title ?? "Meeting", attendees: Array(people.prefix(12)), notes: clean(event.notes ?? ""), start: event.startDate)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Drops the join-link boilerplate Teams and Zoom paste into invites.
    static func clean(_ notes: String) -> String {
        let noise = ["microsoft teams", "join the meeting", "meeting id", "passcode", "dial in", "zoom.us", "teams.microsoft",
                     "learn more", "meeting options", "________", "join on your computer", "or call in", "phone conference id",
                     "need help?", "system reference", "for organizers"]
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && !line.hasPrefix("http") && !line.hasPrefix("<http") && !noise.contains { line.lowercased().contains($0) }
                && line.rangeOfCharacter(from: .letters) != nil
        }
        return String(lines.joined(separator: "\n").prefix(3000))
    }
}
