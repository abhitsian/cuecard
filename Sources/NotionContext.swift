import Foundation

/// Pulls context for a meeting from the user's own sources: the MCP servers they chose from their Claude Code setup
/// and an optional notes folder (see ContextSources), through `claude -p` with read-only tools. Returns a short brief, or nil when Notion isn't connected
/// or nothing relevant turned up.
enum NotionContext {
    static let marker = "[From your sources]"

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

    /// What the lookup found: a short name for the meeting taken from what was said, and the Notion brief.
    struct Result {
        var topic: String?
        var brief: String?
    }

    /// Looks up Notion for a meeting from what is being said (never the calendar: its titles are often wrong).
    /// `transcript` is the recent conversation; `title`, `goal` and `notes` are only what the user typed in prep.
    static func fetch(transcript: String, title: String = "", goal: String = "", notes: String = "", mode: Playbook.Mode,
                      asOf: Date = Date()) async -> Result {
        guard let claude = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return Result() }
        let typed = [title.isEmpty || title == "Meeting" ? "" : "Title the user typed: \(title)",
                     goal.isEmpty ? "" : "Their goal: \(goal)",
                     notes.isEmpty ? "" : "Their prep notes:\n\(notes.prefix(2000))"].filter { !$0.isEmpty }.joined(separator: "\n")
        let prefs = Prefs.shared
        let tools = await ContextSources.allowedTools()
        let folder = prefs.contextFolder.isEmpty || !FileManager.default.fileExists(atPath: prefs.contextFolder) ? nil : prefs.contextFolder
        let sources = [prefs.contextSources.isEmpty ? nil : "their connected sources (\(prefs.contextSources.joined(separator: ", ")))",
                       folder.map { "their notes folder (\($0)), with Grep, Glob and Read" }].compactMap { $0 }
        let prompt = """
        The user is in a meeting (\(mode.label)) and wants the context they already have, so they can ask better \
        questions. Work out what the meeting is about from what is being said below: the topic, the project, the \
        people named. Then search \(sources.isEmpty ? "nothing (no sources are connected)" : sources.joined(separator: " and ")) \
        for what relates to it and read the few most relevant items. Do not create, send or change anything.
        The meeting started \(asOf.formatted(date: .complete, time: .shortened)). Use only what was known before \
        then: ignore notes, recaps or pages about this meeting itself.

        \(typed)
        <transcript>
        \(transcript.isEmpty ? "(nothing said yet)" : String(transcript.suffix(9000)))
        </transcript>

        Reply in plain Markdown. First line exactly: "Topic: " and a 3 to 8 word name for what this meeting is \
        about, from the transcript (or the typed title). Then, under 250 words, only these sections, leaving out \
        any with nothing real in it:
        ## Open items
        Tasks or asks still open that touch this meeting, with who owns them.
        ## Last time
        What was decided or left open the last time this group or topic met, with the date.
        ## Background
        Facts, numbers or constraints worth having in mind.
        Name the source (page, file or item) each bullet comes from in parentheses. If nothing relates, put NONE on \
        its own line after the Topic line.
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        // Only the read tools of the chosen servers, plus read-only file tools for the notes folder. Everything else,
        // including every other server and any tool that writes, is unavailable to this run.
        var allowed = tools
        if folder != nil { allowed += ["Read", "Grep", "Glob"] }
        var args = ["-p", "--model", "sonnet"]
        if !allowed.isEmpty { args += ["--allowedTools"] + allowed }
        args += ["--disallowedTools", "Write", "Edit", "Bash", "NotebookEdit", "WebFetch"] + writeTools.map { "mcp__claude_ai_Notion__\($0)" }
        if let folder { args += ["--add-dir", folder] }
        process.arguments = args
        process.currentDirectoryURL = folder.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let started = Date()
        return await withCheckedContinuation { (done: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    input.fileHandleForWriting.closeFile()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Log.write("notion: \(process.terminationStatus) \(text.count) chars in \(Int(Date().timeIntervalSince(started)))s")
                    guard process.terminationStatus == 0 else { return done.resume(returning: Result()) }
                    let topic = text.components(separatedBy: "\n").first { $0.hasPrefix("Topic:") }
                        .map { $0.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"*."))) }
                    done.resume(returning: Result(topic: topic?.isEmpty == false ? topic : nil,
                                                  brief: brief(from: text).map { "\(marker)\n\($0)" }))
                } catch {
                    Log.write("notion: \(error)")
                    done.resume(returning: Result())
                }
            }
        }
    }
}
