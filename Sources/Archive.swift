import AppKit

/// Saves each meeting as Markdown in ~/Documents/Cuecard: recap, what was captured, questions, transcript.
enum Archive {
    static func write(_ m: Meeting) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let safe = m.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").prefix(60)
        let named = Prefs.meetingsFolder.appendingPathComponent("\(stamp.string(from: m.started)) \(safe).md")
        if m.file == nil {
            m.file = named
        } else if let old = m.file, old != named {
            // The title changed (named from what was said, or by the recap): rename the note and drop its old page.
            try? FileManager.default.moveItem(at: old, to: named)
            try? FileManager.default.removeItem(at: Pages.page(for: old))
            m.file = named
        }
        guard let file = m.file else { return }
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy, HH:mm"
        var out = "# \(m.title)\n\n\(day.string(from: m.started)) · \(m.elapsed) · \(m.mode.label)"
        if !m.attendees.isEmpty { out += " · with \(m.attendees.joined(separator: ", "))" }
        out += "\n"
        if !m.goal.isEmpty { out += "\nGoal: \(m.goal)\n" }
        if let recap = m.recap, !recap.isEmpty { out += "\n\(recap.trimmingCharacters(in: .whitespacesAndNewlines))\n" }

        out += "\n---\n\n## Captured live\n"
        let sections: [(CardKind, String)] = [(.action, "Action items"), (.decision, "Decisions"), (.question, "Open questions"),
                                              (.nextStep, "Next steps"), (.risk, "Risks"), (.signal, "Signals"), (.fact, "Key facts")]
        for (kind, heading) in sections {
            let items = m.cards.filter { $0.kind == kind && !$0.dismissed }
            guard !items.isEmpty else { continue }
            out += "\n### \(heading)\n"
            for c in items {
                switch kind {
                case .action:
                    out += "- [\(c.done ? "x" : " ")] \(c.owner.map { "\($0): " } ?? "")\(c.text)\(c.due.map { " (\($0))" } ?? "")\n"
                case .question:
                    out += "- \(c.resolved != nil ? "~~\(c.text)~~ answered" : c.text)\n"
                case .signal:
                    out += "- \(c.source ?? "Signal") at \(m.clock(c.at)): \"\(c.text)\"\n"
                default:
                    out += "- \(c.text)\n"
                }
            }
        }
        let suggestions = m.cards.filter { $0.kind.isSuggestion && !$0.dismissed }
        if !suggestions.isEmpty {
            out += "\n### What Cuecard suggested\n"
            for c in suggestions { out += "- \(m.clock(c.at)) \(c.kind.label): \(c.text.replacingOccurrences(of: "\n", with: " "))\n" }
        }
        let prepared = m.bank.filter { !$0.live }
        if !prepared.isEmpty {
            out += "\n### Prepared questions (\(prepared.filter(\.asked).count) of \(prepared.count) asked)\n"
            for q in prepared { out += "- [\(q.asked ? "x" : " ")] \(q.topic): \(q.text)\n" }
        }
        out += "\n---\n\n## Transcript\n\n\(m.transcript().replacingOccurrences(of: "\n", with: "  \n"))\n"
        do { try out.write(to: file, atomically: true, encoding: .utf8) } catch { Log.write("archive: \(error)") }
    }

    static func recent(limit: Int = 8) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Prefs.meetingsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit).map { $0 }
    }
}
