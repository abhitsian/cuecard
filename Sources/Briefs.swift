import Foundation

/// A situation prepared before the meeting, with what to say or ask when it comes up. Jev watches each turn from
/// the other side for these; when one happens, its card appears.
struct Cue: Identifiable, Equatable {
    let id = UUID()
    var situation: String
    var say: String?
    var ask: String?
    var shownAt: Date?
}

/// A brief written before the call into ~/Documents/Cuecard/briefs/ by any tool (the meeting-prep skill writes
/// them). Markdown with a small front matter block:
///
///     ---
///     title: "Theming sync"
///     when: "2026-09-28T14:00"
///     mode: "Meeting"
///     people: "Nishant, Uday"
///     goal: "Agree the October radius scope"
///     ---
///     # Theming sync
///     ## Goal ... ## Ask (a list: becomes the question bank) ... ## Cue cards
///     ### When they say the radius defects won't close in time
///     Say: ...
///     Ask: ...
///
/// Everything except the cue cards becomes the meeting's context.
struct Brief: Identifiable {
    var id: String { file.path }
    let file: URL
    var title: String
    var when: Date?
    var mode: Playbook.Mode
    var people: [String]
    var goal: String
    var context: String
    var asks: [String]
    var cues: [Cue]

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Cuecard/briefs")

    /// Today's briefs, the nearest to now first. Ones more than an hour past are left out.
    static func today() -> [Brief] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let now = Date()
        return files.filter { $0.pathExtension == "md" }.compactMap(parse)
            .filter { b in guard let w = b.when else { return false }
                return Calendar.current.isDateInToday(w) && w.timeIntervalSince(now) > -3600 }
            .sorted { abs($0.when!.timeIntervalSince(now)) < abs($1.when!.timeIntervalSince(now)) }
    }

    /// The brief for a call starting about now (20 minutes either side), if there is exactly one clear match.
    static func now() -> Brief? {
        let near = today().filter { abs($0.when!.timeIntervalSinceNow) < 1200 }
        return near.count == 1 ? near[0] : nil
    }

    static func parse(_ file: URL) -> Brief? {
        guard var text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var meta: [String: String] = [:]
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let data = value.data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: data) { value = s }
                meta[line[..<colon].trimmingCharacters(in: .whitespaces)] = value
            }
            text = String(text[end.upperBound...])
        }
        let sections = split(text)
        let cueText = sections.first { $0.name.lowercased().hasPrefix("cue cards") }?.body ?? ""
        let context = sections.filter { !$0.name.lowercased().hasPrefix("cue cards") && $0.name != "Sources" }
            .map { $0.name.isEmpty ? $0.body : "## \($0.name)\n\($0.body)" }.joined(separator: "\n\n")
            .replacingOccurrences(of: #"(?m)^# .+\n*"#, with: "", options: .regularExpression)
        let asks = (sections.first { $0.name == "Ask" }?.body ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") || $0.first?.isNumber == true }
            .map { $0.replacingOccurrences(of: #"^(- |\d+\.\s*)"#, with: "", options: .regularExpression) }
        let when = meta["when"].flatMap { s -> Date? in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            return f.date(from: s)
        }
        let mode = Playbook.Mode.allCases.first { $0.label == meta["mode"] } ?? .general
        return Brief(file: file, title: meta["title"] ?? file.deletingPathExtension().lastPathComponent, when: when, mode: mode,
                     people: (meta["people"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                     goal: meta["goal"] ?? "", context: context.trimmingCharacters(in: .whitespacesAndNewlines),
                     asks: asks, cues: cues(cueText))
    }

    private static func split(_ text: String) -> [(name: String, body: String)] {
        var out: [(String, String)] = [("", "")]
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { out.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), "")) }
            else { out[out.count - 1].1 += line + "\n" }
        }
        return out.map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.0.isEmpty || !$0.1.isEmpty }
    }

    private static func cues(_ text: String) -> [Cue] {
        var out: [Cue] = []
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("### ") {
                out.append(Cue(situation: String(l.dropFirst(4)).replacingOccurrences(of: #"^(When|If)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])))
            } else if !out.isEmpty, let r = l.range(of: #"^[-*]?\s*\**(Say|Ask)\**:\s*"#, options: .regularExpression) {
                let value = String(l[r.upperBound...])
                if l[..<r.upperBound].lowercased().contains("say") { out[out.count - 1].say = value }
                else { out[out.count - 1].ask = value }
            }
        }
        return out.filter { $0.say != nil || $0.ask != nil }
    }
}
