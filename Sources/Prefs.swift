import Foundation
import ServiceManagement

/// The Claude model that writes suggestions, the question bank and the recap.
enum SuggestModel: String, CaseIterable, Identifiable {
    case haiku = "claude-haiku-4-5-20251001"
    case sonnet = "claude-sonnet-5"
    case opus = "claude-opus-5-5"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .haiku: return "Haiku 4.5 · fastest"
        case .sonnet: return "Sonnet 5 · sharp"
        case .opus: return "Opus 5.5 · deepest"
        }
    }
    var short: String {
        switch self {
        case .haiku: return "Haiku 4.5"
        case .sonnet: return "Sonnet 5"
        case .opus: return "Opus 5.5"
        }
    }
}

/// Everything the user can set, kept in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let store = UserDefaults.standard

    @Published var name: String { didSet { store.set(name, forKey: "name") } }
    @Published var about: String { didSet { store.set(about, forKey: "about") } }
    @Published var vocabulary: String { didSet { store.set(vocabulary, forKey: "vocabulary") } }
    @Published var model: SuggestModel { didSet { store.set(model.rawValue, forKey: "model") } }
    @Published var systemAudio: Bool { didSet { store.set(systemAudio, forKey: "systemAudio") } }
    @Published var autoSuggest: Bool { didSet { store.set(autoSuggest, forKey: "autoSuggest") } }
    @Published var detectMeetings: Bool { didSet { store.set(detectMeetings, forKey: "detectMeetings") } }
    @Published var hideFromSharing: Bool { didSet { store.set(hideFromSharing, forKey: "hideFromSharing") } }
    @Published var useCalendar: Bool { didSet { store.set(useCalendar, forKey: "useCalendar") } }
    /// Pull context from Notion (through the Claude Code Notion connector) when a meeting starts.
    @Published var notionContext: Bool { didSet { store.set(notionContext, forKey: "notionContext") } }
    @Published var useJev: Bool { didSet { store.set(useJev, forKey: "useJev") } }
    @Published var popOnAsk: Bool { didSet { store.set(popOnAsk, forKey: "popOnAsk") } }

    private init() {
        name = store.string(forKey: "name") ?? NSFullUserName().components(separatedBy: " ").first ?? ""
        about = store.string(forKey: "about") ?? ""
        vocabulary = store.string(forKey: "vocabulary") ?? ""
        model = SuggestModel(rawValue: store.string(forKey: "model") ?? "") ?? .sonnet
        systemAudio = store.object(forKey: "systemAudio") as? Bool ?? true
        autoSuggest = store.object(forKey: "autoSuggest") as? Bool ?? true
        detectMeetings = store.object(forKey: "detectMeetings") as? Bool ?? true
        hideFromSharing = store.object(forKey: "hideFromSharing") as? Bool ?? true
        useCalendar = store.object(forKey: "useCalendar") as? Bool ?? true
        notionContext = store.object(forKey: "notionContext") as? Bool ?? true
        useJev = store.object(forKey: "useJev") as? Bool ?? true
        popOnAsk = store.object(forKey: "popOnAsk") as? Bool ?? true
    }

    /// Names, products and jargon to help recognition, one per comma or line.
    var vocabularyList: [String] {
        vocabulary.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Context the user last gave for a kind of meeting, so a standing rubric or 1:1 agenda carries over.
    func savedContext(for mode: Playbook.Mode) -> String { store.string(forKey: "context.\(mode.rawValue)") ?? "" }
    func saveContext(_ text: String, for mode: Playbook.Mode) { store.set(text, forKey: "context.\(mode.rawValue)") }
    var lastMode: Playbook.Mode {
        get { Playbook.Mode(rawValue: store.string(forKey: "lastMode") ?? "") ?? .general }
        set { store.set(newValue.rawValue, forKey: "lastMode") }
    }

    // MARK: Folders and keys

    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cuecard")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let meetingsFolder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Cuecard")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// TypeSafe key: Cuecard's own file, else the one Seek already has. Kept in a 600 file, not the Keychain,
    /// because a self-signed app's Keychain access re-prompts after every rebuild.
    var jevKey: String? {
        let own = Prefs.support.appendingPathComponent("typesafe-key")
        let seek = Prefs.support.deletingLastPathComponent().appendingPathComponent("Seek/typesafe-key")
        for url in [own, seek] {
            if let key = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        return ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]
    }

    func saveJevKey(_ key: String) {
        let url = Prefs.support.appendingPathComponent("typesafe-key")
        try? key.trimmingCharacters(in: .whitespacesAndNewlines).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        objectWillChange.send()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { Log.write("login item: \(error)") }
            objectWillChange.send()
        }
    }
}
