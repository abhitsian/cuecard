import Foundation

/// Runs a command of the user's choosing once a write-up is saved, with the saved file or folder as its argument
/// (e.g. a script that files the meeting into a notes app). Set it with:
///   defaults write <bundle id> afterWriteUp "/path/to/script"
/// Nothing runs when it isn't set. The command runs detached; the app doesn't wait for it.
enum AfterWriteUp {
    static func run(_ path: String) {
        guard let command = UserDefaults.standard.string(forKey: "afterWriteUp"), !command.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        process.arguments = ["-lc", "\(command) \(quoted) >/dev/null 2>&1 &"]
        do {
            try process.run()
            Log.write("after write-up: started \(command)")
        } catch {
            Log.write("after write-up: \(error)")
        }
    }
}
