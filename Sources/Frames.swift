import Foundation

/// A structure a good answer should have (a product case, a behavioural story, a problem-to-solution
/// argument). Each step carries yes/no tests from the Criteria Bank that Jev runs against what was said.
/// Frames are JSON files: the ones shipped in the app, overridden or extended by any file of the same id in
/// ~/Library/Application Support/Cuecard/Frames, so the user can edit tests and probes.
struct Frame: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let modes: [String]
    let nodes: [Node]

    struct Node: Codable, Equatable {
        let key: String
        let label: String
        let about: String
        let tests: [Test]
    }

    struct Test: Codable, Equatable {
        let key: String
        /// Asked of Jev; yes means the answer is strong on this point.
        let question: String
        /// Shown when the test fails.
        let weak: String
        /// What the follow-up should go after, for Claude.
        let probe: String
    }

    static var userFolder: URL {
        let url = Prefs.support.appendingPathComponent("Frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Shipped frames, then the user's files layered on top by id.
    static func all() -> [Frame] {
        var byID: [String: Frame] = [:]
        var order: [String] = []
        let folders = [Bundle.main.resourceURL?.appendingPathComponent("Frames"),
                       URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../Frames"),
                       userFolder].compactMap { $0 }
        for folder in folders {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let data = try? Data(contentsOf: file) else { continue }
                do {
                    let frame = try JSONDecoder().decode(Frame.self, from: data)
                    if byID[frame.id] == nil { order.append(frame.id) }
                    byID[frame.id] = frame
                } catch {
                    Log.write("frame \(file.lastPathComponent): \(error)")
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Frames that suit a kind of meeting, in file order.
    static func defaults(for mode: Playbook.Mode) -> [String] {
        switch mode {
        case .interviewing: return ["story", "product-case"]
        case .review: return ["review"]
        case .decision: return ["decision"]
        case .general, .customer: return ["opportunity-tree"]
        case .oneOnOne: return []
        case .interviewed: return []
        }
    }
}

/// Where an answer stands on one step of a frame.
struct NodeState: Equatable {
    enum Status: Int { case missing = 0, weak = 1, strong = 2 }
    var status: Status = .missing
    /// Everything said for this step so far.
    var evidence: [String] = []
    /// Test key → probability of yes, from the last judgement.
    var scores: [String: Double] = [:]
    var failing: [String] = []
    var updated = Date()
    /// When a follow-up was last suggested for this step, and which failed tests have had one.
    var probedAt: Date?
    var probed: Set<String> = []

    var text: String { evidence.joined(separator: " ") }
}
