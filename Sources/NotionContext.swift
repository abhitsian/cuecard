import Foundation

/// Pulls context for a meeting out of the user's Notion through the Notion connector in their Claude Code login
/// (`claude -p` with only Notion's read tools allowed). Returns a short brief, or nil when Notion isn't connected
/// or nothing relevant turned up.
enum NotionContext {
    static let marker = "[From Notion]"

    /// Notion tools that change anything. Blocked, so this can only read.
    private static let writeTools = [
        "notion-create-pages", "notion-update-page", "notion-move-pages", "notion-duplicate-page", "notion-create-database",
        "notion-update-data-source", "notion-create-view", "notion-update-view", "notion-create-comment", "notion-delete",
        "notion-create-folder", "notion-update-folder", "notion-create-attachment", "notion-create-file-upload",
        "notion-spawn-session", "notion-send-message-to-session", "notion-stop-session", "notion-upload-skill",
        "notion-convert-page-to-skill",
    ]

    /// The usable part of a reply: from the first section heading on. Nothing when the reply says NONE anywhere
    /// on a line of its own, or has no sections (an explanation of why nothing was found is not context).
    static func brief(from reply: String) -> String? {
        let lines = reply.components(separatedBy: "\n")
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "NONE" }) { return nil }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) else { return nil }
        let body = lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count > 40 ? body : nil
    }

    static func fetch(title: String, attendees: [String], goal: String, mode: Playbook.Mode, asOf: Date = Date()) async -> String? {
        guard let claude = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let prompt = """
        The user is about to be in a meeting and wants the context they already have in Notion, so they can ask \
        better questions. Search their Notion (task tracker, meeting notes, project and workstream pages) for what \
        relates to this meeting. Read the few most relevant pages. Do not create or change anything.

        The meeting starts \(asOf.formatted(date: .complete, time: .shortened)). Use only what was known before then: \
        ignore any notes, recaps or pages about this meeting itself.

        Meeting: \(title)
        Type: \(mode.label)
        \(attendees.isEmpty ? "" : "With: \(attendees.joined(separator: ", "))")
        \(goal.isEmpty ? "" : "Their goal: \(goal)")

        Reply in plain Markdown, under 250 words, only these sections, leaving out any with nothing real in it:
        ## Open items
        Tasks or asks still open that touch this meeting, with who owns them.
        ## Last time
        What was decided or left open the last time this group or topic met, with the date.
        ## Background
        Facts, numbers or constraints worth having in mind.
        Name the Notion page each bullet comes from in parentheses. If nothing relevant exists, reply NONE.
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--model", "sonnet", "--allowedTools", "mcp__claude_ai_Notion",
                             "--disallowedTools"] + writeTools.map { "mcp__claude_ai_Notion__\($0)" }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let started = Date()
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    input.fileHandleForWriting.closeFile()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Log.write("notion: \(process.terminationStatus) \(text.count) chars in \(Int(Date().timeIntervalSince(started)))s")
                    done.resume(returning: process.terminationStatus == 0 ? brief(from: text).map { "\(marker)\n\($0)" } : nil)
                } catch {
                    Log.write("notion: \(error)")
                    done.resume(returning: nil)
                }
            }
        }
    }
}
