import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @State private var key = ""
    @State private var login = Prefs.shared.launchAtLogin

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
            Section("Listening") {
                Toggle("Hear the other side (the Mac's audio)", isOn: $prefs.systemAudio)
                Toggle("Offer to listen when a call starts", isOn: $prefs.detectMeetings)
                Toggle("Hide the panel from screen sharing", isOn: $prefs.hideFromSharing)
                Toggle("Open at login", isOn: $login).onChange(of: login) { prefs.launchAtLogin = login }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }
}
