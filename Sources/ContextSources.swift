import Foundation

/// Where Cuecard looks for meeting context, beyond what the user types in prep: any MCP server in their Claude Code
/// setup (Notion, Google Drive, Confluence, Linear, GitHub…) and a local notes folder. The lookup runs through
/// `claude -p`, so a source is anything Claude Code can already reach. Only read tools are ever allowed: for each
/// server Cuecard lists its tools once and keeps the ones whose names don't write, send or change anything.
enum ContextSources {
    struct Server: Codable, Hashable, Identifiable {
        var id: String { name }
        let name: String       // as `claude mcp list` prints it, e.g. "claude.ai Notion", "pointer"
        let connected: Bool
        /// The prefix its tools carry, e.g. mcp__claude_ai_Notion.
        var prefix: String { "mcp__" + name.map { ".: ".contains($0) ? "_" : $0 }.map(String.init).joined() }
    }

    static var claude: String? {
        ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Tool-name words that mean the tool changes something. A tool containing any of them is never allowed.
    private static let writeWords = ["create", "update", "delete", "remove", "send", "post", "write", "edit", "move", "archive",
                                     "upload", "comment", "add", "set", "insert", "replace", "rename", "merge", "spawn", "stop",
                                     "share", "trash", "mark", "label", "apply", "forward", "reply", "split", "duplicate", "publish",
                                     "invite", "assign", "close", "open_", "run", "execute", "click", "type", "navigate", "pin", "book",
                                     "authenticate", "complete", "transfer", "pay", "order", "cancel", "respond", "draft",
                                     "convert", "download", "install", "import", "sync", "connect", "enable", "disable", "approve",
                                     "reject", "submit", "save", "restore", "undo", "clear", "reset", "grant", "revoke", "schedule"]

    static func isReadOnly(_ tool: String) -> Bool {
        let name = tool.lowercased().components(separatedBy: "__").last ?? tool.lowercased()
        return !writeWords.contains { name.contains($0) }
    }

    /// The MCP servers in the user's Claude Code setup (`claude mcp list`). Takes a few seconds: it health-checks each.
    static func discover() async -> [Server] {
        guard let claude else { return [] }
        let output = await run(claude, ["mcp", "list"], input: nil, timeout: 90)
        return output.components(separatedBy: "\n").compactMap { line -> Server? in
            guard let colon = line.range(of: ": "), line.contains(" - ") else { return nil }
            let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("Checking") else { return nil }
            return Server(name: name, connected: line.contains("✔") || line.localizedCaseInsensitiveContains("connected") && !line.contains("✘"))
        }
    }

    /// The read-only tools of one server, found by asking Claude Code to list them (it has the live tool list).
    static func readTools(for server: Server) async -> [String] {
        guard let claude else { return [] }
        let prompt = "List the exact names of every tool you have whose name starts with \(server.prefix)__, one per line, nothing else."
        let output = await run(claude, ["-p", "--model", "sonnet"], input: prompt, timeout: 120)
        let tools = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`-*"))) }
            .filter { $0.hasPrefix(server.prefix + "__") }
        return Array(Set(tools.filter(isReadOnly))).sorted()
    }

    /// Tools the lookup may use: the read tools of each chosen server (listed on first use and remembered).
    static func allowedTools() async -> [String] {
        let prefs = Prefs.shared
        var tools: [String] = []
        for name in prefs.contextSources {
            let server = Server(name: name, connected: true)
            var known = prefs.sourceTools[name] ?? []
            if known.isEmpty {
                known = await readTools(for: server)
                if !known.isEmpty { await MainActor.run { prefs.sourceTools[name] = known } }
                Log.write("sources: \(name) → \(known.count) read tools")
            }
            tools += known
        }
        return tools
    }

    static func run(_ path: String, _ args: [String], input: String?, timeout: TimeInterval) async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                let output = Pipe(), stdin = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                process.standardInput = stdin
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment
                do { try process.run() } catch { return done.resume(returning: "") }
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                stdin.fileHandleForWriting.closeFile()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
