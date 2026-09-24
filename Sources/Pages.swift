import AppKit

/// A web page for each meeting, and a library of them, next to the notes: ~/Documents/Cuecard/pages/<note>.html
/// and ~/Documents/Cuecard/index.html. Pages are built from the Markdown notes, so every meeting has one.
enum Pages {
    static var folder: URL { Prefs.meetingsFolder.appendingPathComponent("pages", isDirectory: true) }
    static var library: URL { Prefs.meetingsFolder.appendingPathComponent("index.html") }

    static func page(for note: URL) -> URL {
        folder.appendingPathComponent(note.deletingPathExtension().lastPathComponent + ".html")
    }

    /// Writes one meeting's page from its note.
    static func write(note: URL) {
        guard let markdown = try? String(contentsOf: note, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload: [String: String] = ["markdown": markdown, "note": "../" + (note.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? note.lastPathComponent)]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let html = fill("meeting", placeholder: "__MEETING_JSON__", json: json) else { return }
        try? html.write(to: page(for: note), atomically: true, encoding: .utf8)
    }

    /// Writes pages that are missing or older than their note, then the library.
    @discardableResult
    static func rebuild() -> URL {
        let notes = ((try? FileManager.default.contentsOfDirectory(at: Prefs.meetingsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        var entries: [[String: Any]] = []
        for note in notes {
            let target = page(for: note)
            if modified(target) < modified(note) { write(note: note) }
            if let entry = entry(for: note) { entries.append(entry) }
        }
        if let json = try? JSONSerialization.data(withJSONObject: entries),
           let html = fill("library", placeholder: "__LIBRARY_JSON__", json: json) {
            try? html.write(to: library, atomically: true, encoding: .utf8)
        }
        return library
    }

    /// What the library shows for one note: title, when, mode, people, the first summary line and counts.
    private static func entry(for note: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: note, encoding: .utf8) else { return nil }
        let name = note.deletingPathExtension().lastPathComponent
        guard let stamp = name.firstMatch(of: #/^(\d{4})-(\d\d)-(\d\d) (\d\d)(\d\d)/#) else { return nil }
        var parts = DateComponents()
        parts.year = Int(stamp.1); parts.month = Int(stamp.2); parts.day = Int(stamp.3); parts.hour = Int(stamp.4); parts.minute = Int(stamp.5)
        guard let created = Calendar.current.date(from: parts) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? name
        let meta = lines.first { $0.firstMatch(of: #/ · \d+(:\d\d)+ · /#) != nil }?.components(separatedBy: " · ") ?? []
        let with = meta.first { $0.hasPrefix("with ") }.map { String($0.dropFirst(5)) } ?? ""
        func section(_ heading: String) -> [String] {
            guard let start = lines.firstIndex(where: { $0.lowercased() == "## \(heading)" }) else { return [] }
            return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") && $0 != "---" })
        }
        let summary = section("summary").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let gist = summary.first.map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }?
            .replacingOccurrences(of: "**", with: "")
        let bullets = { (heading: String) in section(heading).filter { $0.hasPrefix("- ") }.count }
        let href = "pages/" + ((name + ".html").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
        var entry: [String: Any] = [
            "href": href, "title": title, "created": ISO8601DateFormatter().string(from: created),
            "length": meta.count > 1 ? meta[1] : "", "mode": meta.count > 2 ? meta[2] : "",
            "people": with.isEmpty ? 0 : with.components(separatedBy: ",").count, "with": with,
            "actions": bullets("action items"), "decisions": bullets("decisions"), "recap": !summary.isEmpty,
        ]
        if let gist { entry["gist"] = gist }
        return entry
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func fill(_ template: String, placeholder: String, json: Data) -> String? {
        guard let url = Bundle.main.url(forResource: template, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return html.replacingOccurrences(of: placeholder, with: text.replacingOccurrences(of: "</", with: "<\\/"))
    }
}
