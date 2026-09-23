import Foundation

/// Calls Claude through the `claude` command, so it runs on the user's Claude Code login and Cuecard never
/// handles credentials. Settings and hooks are skipped (`--setting-sources local`, no tools, no MCP), and one
/// process per prompt style is started ahead of time, which brings the first words in under a second.
final class Claude {
    static let shared = Claude()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A started `claude -p` waiting on stdin for its one prompt.
    private final class Warm {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let errors: Pipe
        let born = Date()
        init(process: Process, input: FileHandle, output: FileHandle, errors: Pipe) {
            self.process = process; self.input = input; self.output = output; self.errors = errors
        }
    }

    private let lock = NSLock()
    private var pool: [String: Warm] = [:]
    private var keepWarm: Set<String> = []

    static var binary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Keep a process ready for this model and system prompt until `coolDown()`.
    func warm(model: String, system: String) {
        let key = Claude.key(model, system)
        lock.lock()
        keepWarm.insert(key)
        let have = pool[key] != nil
        lock.unlock()
        if !have { spawnWarm(model: model, system: system) }
    }

    /// Stops every waiting process (meeting over).
    func coolDown() {
        lock.lock()
        let waiting = Array(pool.values)
        pool = [:]
        keepWarm = []
        lock.unlock()
        waiting.forEach { $0.process.terminate() }
    }

    /// Streams a reply and hands over each complete line as soon as its newline arrives. Returns the whole reply.
    @discardableResult
    func lines(model: String, system: String, prompt: String, onLine: @escaping (String) -> Void) async throws -> String {
        var buffer = ""
        let whole = try await stream(model: model, system: system, prompt: prompt) { fragment in
            buffer += fragment
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespaces)
                buffer = String(buffer[buffer.index(after: newline)...])
                if !line.isEmpty { onLine(line) }
            }
        }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { onLine(rest) }
        return whole
    }

    /// Streams a reply; `onText` gets each fragment (off the main thread).
    @discardableResult
    func stream(model: String, system: String, prompt: String, onText: ((String) -> Void)? = nil) async throws -> String {
        do {
            return try await attempt(model: model, system: system, prompt: prompt, fresh: false, onText: onText)
        } catch let failure as Failure where failure.message.localizedCaseInsensitiveContains("logged in") || failure.message.contains("/login") {
            // A process started before Claude Code refreshed its login holds the old token. A new one reads the new token.
            Log.write("claude: stale login in a waiting process, retrying fresh")
            lock.withLock { pool = pool.filter { !$0.key.hasPrefix(model + "|") } }
            return try await attempt(model: model, system: system, prompt: prompt, fresh: true, onText: onText)
        }
    }

    private func attempt(model: String, system: String, prompt: String, fresh: Bool, onText: ((String) -> Void)?) async throws -> String {
        let key = Claude.key(model, system)
        var (ready, rewarm) = lock.withLock { (fresh ? nil : pool.removeValue(forKey: key), keepWarm.contains(key)) }
        // Waiting processes are recycled after five minutes, well inside a login token's lifetime.
        if let r = ready, !r.process.isRunning || Date().timeIntervalSince(r.born) > 300 {
            r.process.terminate()
            ready = nil
        }
        let worker = try ready ?? spawn(model: model, system: system)
        if rewarm { DispatchQueue.global(qos: .utility).async { self.spawnWarm(model: model, system: system) } }

        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try worker.input.write(contentsOf: data)

        let started = Date()
        let age = Date().timeIntervalSince(worker.born)
        var firstAt: Double?
        var whole = ""
        var failure: String?
        defer {
            try? worker.input.close()
            if worker.process.isRunning { worker.process.terminate() }
        }
        for try await line in worker.output.bytes.lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = event["type"] as? String
            if type == "stream_event", let inner = event["event"] as? [String: Any],
               inner["type"] as? String == "content_block_delta",
               let delta = inner["delta"] as? [String: Any], let text = delta["text"] as? String {
                if firstAt == nil { firstAt = Date().timeIntervalSince(started) }
                whole += text
                onText?(text)
            } else if type == "result" {
                if event["is_error"] as? Bool == true { failure = event["result"] as? String ?? "Claude returned an error" }
                if whole.isEmpty, let result = event["result"] as? String, failure == nil {
                    whole = result
                    onText?(result)
                }
                break
            }
        }
        if let failure {
            Log.write("claude \(model): \(failure.prefix(200))")
            throw Failure(message: failure)
        }
        if whole.isEmpty {
            let errors = String(decoding: worker.errors.fileHandleForReading.availableData.prefix(400), as: UTF8.self)
            Log.write("claude \(model): empty reply \(errors)")
            throw Failure(message: errors.isEmpty ? "Claude didn't answer" : errors)
        }
        Log.write("claude \(model.split(separator: "-").dropFirst().first ?? ""): first \(String(format: "%.1f", firstAt ?? -1))s total \(String(format: "%.1f", Date().timeIntervalSince(started)))s \(whole.count) chars, process \(ready == nil ? "cold" : String(format: "warm %.0fs", age))")
        return whole
    }

    // MARK: Processes

    private static func key(_ model: String, _ system: String) -> String { "\(model)|\(system.hashValue)" }

    private func spawnWarm(model: String, system: String) {
        guard let worker = try? spawn(model: model, system: system) else { return }
        let key = Claude.key(model, system)
        lock.lock()
        if keepWarm.contains(key), pool[key] == nil {
            pool[key] = worker
            lock.unlock()
        } else {
            lock.unlock()
            worker.process.terminate()
        }
    }

    private func spawn(model: String, system: String) throws -> Warm {
        guard let binary = Claude.binary else { throw Failure(message: "Claude Code isn't installed (no `claude` command found).") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-p", "--model", model,
            "--system-prompt", system,
            "--setting-sources", "local",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
        ]
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cuecard-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        return Warm(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, errors: errors)
    }
}
