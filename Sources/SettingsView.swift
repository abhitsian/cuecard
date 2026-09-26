import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @State private var key = ""
    @State private var login = Prefs.shared.launchAtLogin
    @State private var servers: [ContextSources.Server] = []
    @State private var finding = false

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $prefs.name)
                TextField("About you (role, team, what you own)", text: $prefs.about, axis: .vertical).lineLimit(2...4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Words to recognise").font(.callout)
                    TextEditor(text: $prefs.vocabulary).font(.system(size: 12)).frame(height: 70)
                    Text("Names, products and jargon, separated by commas. The recogniser favours these.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Suggestions") {
                Picker("Model", selection: $prefs.model) {
                    ForEach(SuggestModel.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Suggest automatically", isOn: $prefs.autoSuggest)
                Toggle("Show the panel when you're asked something", isOn: $prefs.popOnAsk)
                Toggle("Use Jev to sort and time suggestions", isOn: $prefs.useJev)
                HStack {
                    SecureField(prefs.jevKey == nil ? "TypeSafe API key" : "TypeSafe key set (paste to replace)", text: $key)
                    Button("Save") { prefs.saveJevKey(key); key = "" }.disabled(key.isEmpty)
                }
                Text(prefs.jevKey == nil ? "Without a key, Cuecard falls back to keyword rules for sorting." : "Jev judges every turn in about half a second; Claude writes only when something new is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context sources") {
                Text("During a meeting Cuecard works out the topic from what is said and searches these for context: open items, what was decided last time, background. It only reads: every tool that writes, sends or changes anything is left out.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(finding ? "Looking…" : (servers.isEmpty ? "Find my sources" : "Refresh")) {
                        finding = true
                        Task { let found = await ContextSources.discover(); await MainActor.run { servers = found; finding = false } }
                    }
                    .disabled(finding)
                    Text("From your Claude Code setup: Notion, Google Drive, Confluence, Linear, GitHub, any MCP server")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(servers.isEmpty ? prefs.contextSources.map { ContextSources.Server(name: $0, connected: true) } : servers) { server in
                    Toggle(isOn: Binding(
                        get: { prefs.contextSources.contains(server.name) },
                        set: { on in
                            if on { prefs.contextSources.append(server.name); prefs.sourceTools[server.name] = nil }
                            else { prefs.contextSources.removeAll { $0 == server.name } }
                        })) {
                        HStack {
                            Text(server.name)
                            if !server.connected { Text("not connected").font(.caption).foregroundStyle(.orange) }
                            if let tools = prefs.sourceTools[server.name] {
                                Text("\(tools.count) read tools").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Text("Notes folder")
                    Spacer()
                    Text(prefs.contextFolder.isEmpty ? "None" : (prefs.contextFolder as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.prompt = "Use this folder"
                        NSApp.activate(ignoringOtherApps: true)
                        if panel.runModal() == .OK, let url = panel.url { prefs.contextFolder = url.path }
                    }
                    if !prefs.contextFolder.isEmpty { Button("Clear") { prefs.contextFolder = "" } }
                }
                Text("A folder of Markdown or text notes (an Obsidian vault, meeting notes). Cuecard searches and reads it; it never writes there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Listening") {
                Toggle("Hear the other side (the Mac's audio)", isOn: $prefs.systemAudio)
                Toggle("Offer to listen when a call starts", isOn: $prefs.detectMeetings)
                Toggle("Hide the panel from screen sharing", isOn: $prefs.hideFromSharing)
                Toggle("Open at login", isOn: $login).onChange(of: login) { prefs.launchAtLogin = login }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
    }
}
