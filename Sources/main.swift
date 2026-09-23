import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--simulate"), arguments.count > i + 1 {
    let mode = arguments.count > i + 2 && !arguments[i + 2].hasPrefix("--") ? arguments[i + 2] : nil
    Simulate.run(script: arguments[i + 1], mode: mode)
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
