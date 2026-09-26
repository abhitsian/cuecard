import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--simulate"), arguments.count > i + 1 {
    let mode = arguments.count > i + 2 && !arguments[i + 2].hasPrefix("--") ? arguments[i + 2] : nil
    Simulate.run(script: arguments[i + 1], mode: mode)
} else if let i = arguments.firstIndex(of: "--demo-render"), arguments.count > i + 2 {
    _ = NSApplication.shared
    let fps = arguments.count > i + 3 ? Double(arguments[i + 3]) ?? 10 : 10
    MainActor.assumeIsolated { Demo.run(script: arguments[i + 1], out: arguments[i + 2], fps: fps) }
} else if arguments.contains("--sources") {
    // Lists the MCP servers in the Claude Code setup and the read-only tools Cuecard would allow for the chosen ones.
    Task {
        for server in await ContextSources.discover() {
            print("\(Prefs.shared.contextSources.contains(server.name) ? "[x]" : "[ ]") \(server.name)\(server.connected ? "" : " (not connected)")")
        }
        for name in Prefs.shared.contextSources {
            let tools = await ContextSources.readTools(for: ContextSources.Server(name: name, connected: true))
            print("\n\(name): \(tools.count) read tools\n  " + tools.joined(separator: "\n  "))
        }
        exit(0)
    }
    RunLoop.main.run()
} else if arguments.contains("--notion") {
    Simulate.notion(arguments)
} else if let i = arguments.firstIndex(of: "--transcribe") {
    Simulate.transcribe(Array(arguments.dropFirst(i + 1)))
} else if let i = arguments.firstIndex(of: "--probe-tap") {
    Simulate.probeTap(seconds: Double(arguments.dropFirst(i + 1).first ?? "5") ?? 5)
} else if let i = arguments.firstIndex(of: "--render"), arguments.count > i + 1 {
    _ = NSApplication.shared
    let state = arguments.count > i + 2 ? arguments[i + 2] : "live"
    MainActor.assumeIsolated { Render.run(arguments[i + 1], state: state) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
