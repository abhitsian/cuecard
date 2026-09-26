import Foundation
import SwiftUI

enum Speaker: String, Codable {
    case you = "You", them = "Them"
}

/// One finished sentence from the transcript.
struct Line: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    let at: Date
    /// A display name when one is known (the demo script names its speakers); otherwise You / Them.
    var name: String? = nil
}

/// One Jev verdict on a turn: what it scored at 0.5 or above, and how long Jev took.
struct Judgement: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let scores: [String: Double]
    let ms: Int
    let at: Date
}

/// Everything Cuecard shows is a card. Suggestions (say, ask, answer) live on the Live tab; captures (action,
/// decision, question, next step, risk, fact, signal) build the Notes board.
enum CardKind: String, CaseIterable, Codable {
    case say, ask, answer, flag
    case action, decision, question, nextStep, risk, fact, signal

    var label: String {
        switch self {
        case .say: return "Say"
        case .ask: return "Ask"
        case .answer: return "Answer"
        case .flag: return "Flag"
        case .action: return "Action item"
        case .decision: return "Decision"
        case .question: return "Open question"
        case .nextStep: return "Next step"
        case .risk: return "Risk"
        case .fact: return "Key fact"
        case .signal: return "Signal"
        }
    }

    var symbol: String {
        switch self {
        case .say: return "text.bubble.fill"
        case .ask: return "questionmark.bubble.fill"
        case .answer: return "sparkle"
        case .flag: return "exclamationmark.triangle.fill"
        case .action: return "checkmark.circle"
        case .decision: return "checkmark.seal.fill"
        case .question: return "questionmark.circle"
        case .nextStep: return "arrow.turn.down.right"
        case .risk: return "exclamationmark.octagon"
        case .fact: return "number"
        case .signal: return "waveform.path.ecg"
        }
    }

    var color: Color {
        switch self {
        case .say: return Color(red: 0.97, green: 0.73, blue: 0.32)
        case .ask: return Color(red: 0.45, green: 0.72, blue: 1.0)
        case .answer: return Color(red: 0.36, green: 0.84, blue: 0.78)
        case .flag, .risk: return Color(red: 1.0, green: 0.50, blue: 0.43)
        case .action: return Color(red: 0.40, green: 0.85, blue: 0.56)
        case .decision: return Color(red: 0.72, green: 0.58, blue: 1.0)
        case .question: return Color(red: 0.45, green: 0.72, blue: 1.0)
        case .nextStep: return Color(red: 0.55, green: 0.80, blue: 0.95)
        case .fact: return Color(white: 0.78)
        case .signal: return Color(red: 1.0, green: 0.62, blue: 0.80)
        }
    }

    /// Suggestions are things to say or do now; everything else is a capture for the notes.
    var isSuggestion: Bool { [.say, .ask, .answer, .flag].contains(self) }

    /// The prefix Claude uses for this kind, in its line format.
    var tag: String {
        switch self {
        case .nextStep: return "NEXT"
        case .question: return "OPEN"
        default: return rawValue.uppercased()
        }
    }

    static func from(tag: String) -> CardKind? {
        let t = tag.uppercased()
        if t == "TODO" { return .action }
        if t == "DECIDED" { return .decision }
        if t == "NOTE" { return .fact }
        return allCases.first { $0.tag == t }
    }
}

struct Card: Identifiable, Equatable {
    let id = UUID()
    var kind: CardKind
    var text: String
    var at = Date()
    /// Owner for action items (a name, "You" or "Them").
    var owner: String?
    /// Due for action items, as said ("Friday", "EOD").
    var due: String?
    /// The words from the meeting this came from.
    var quote: String?
    /// Why it appeared: "From your prep", "Jev · asked you", a signal name.
    var source: String?
    var pinned = false
    var done = false
    var dismissed = false
    /// Open questions: answered later in the meeting.
    var resolved: String?
    /// Waiting for Claude to tidy the wording.
    var refining = false
    /// Jev's confidence when Jev put it here (a capture's category score, or how well a prepared question fits).
    var score: Double?
}

/// One question prepared before the meeting (or written live and kept for later).
struct BankQuestion: Identifiable, Equatable {
    let id = UUID()
    var topic: String
    var text: String
    var asked = false
    var surfacedAt: Date?
    var live = false
}

/// A running meeting: transcript, cards, question bank. Mutated on the main thread only.
final class Meeting: ObservableObject {
    enum Phase { case listening, paused, wrapping, done }

    @Published var title: String
    /// The user typed the title in prep; otherwise it comes from what is said and may be replaced.
    var userTitled = false
    /// Notion lookups done during this meeting (they run a few minutes in, and again later).
    var notionLookups = 0
    var notionBusy = false
    /// What the last lookup found the meeting to be about, and when it ran. Jev checks every turn for a move to a
    /// different topic, which triggers a fresh lookup.
    var lookupTopic: String?
    var lastLookup: Date?
    var topicShifted = false
    @Published var mode: Playbook.Mode
    @Published var goal: String
    @Published var context: String
    @Published var attendees: [String]
    @Published var phase: Phase = .listening
    @Published var lines: [Line] = []
    @Published var partial: [Speaker: String] = [:]
    /// Who is speaking the partial line, when known (the demo names its speakers).
    @Published var partialNames: [Speaker: String] = [:]
    @Published var cards: [Card] = []
    /// Every Jev verdict, for the board: which turn, what it scored, how long it took.
    @Published var judgements: [Judgement] = []
    @Published var bank: [BankQuestion] = []
    /// The answer structures being graded, and where the answer stands on each step ("frame.node" → state).
    @Published var frames: [Frame] = []
    @Published var map: [String: NodeState] = [:]
    @Published var bankState: String?
    @Published var thinking = false
    @Published var notice: String?
    @Published var recap: String?
    @Published var youLevel: Float = 0
    @Published var themLevel: Float = 0
    @Published var hearsThem = false
    @Published var themSilent = false
    var started: Date
    var ended: Date?
    var file: URL?

    init(title: String, mode: Playbook.Mode, goal: String, context: String, attendees: [String] = [], started: Date = Date()) {
        self.title = title
        self.mode = mode
        self.goal = goal
        self.context = context
        self.attendees = attendees
        self.started = started
    }

    var live: Bool { phase == .listening || phase == .paused }

    func add(_ line: Line) {
        lines.append(line)
        partial[line.speaker] = nil
    }

    /// Adds a card unless something nearly identical is already there. Returns the card's id if added.
    @discardableResult
    func add(_ card: Card) -> UUID? {
        let words = Meeting.words(card.text)
        let clash = cards.suffix(40).contains {
            ($0.kind == card.kind || ($0.kind.isSuggestion && card.kind.isSuggestion)) && Meeting.overlap(words, Meeting.words($0.text)) > 0.7
        }
        if clash { return nil }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { cards.append(card) }
        return card.id
    }

    func update(_ id: UUID, _ change: (inout Card) -> Void) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[i])
    }

    func state(_ frame: Frame, _ node: Frame.Node) -> NodeState { map["\(frame.id).\(node.key)"] ?? NodeState() }

    /// One line per step, for prompts and the write-up.
    var mapSummary: String {
        frames.map { frame in
            "\(frame.name):\n" + frame.nodes.map { node in
                let s = state(frame, node)
                let status = ["not covered", "weak", "strong"][s.status.rawValue]
                let misses = s.failing.compactMap { key in node.tests.first { $0.key == key }?.weak }
                return "- \(node.label): \(status)" + (misses.isEmpty ? "" : " (\(misses.joined(separator: "; ")))")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    var openQuestions: [Card] { cards.filter { $0.kind == .question && $0.resolved == nil && !$0.dismissed } }

    /// The transcript as "[mm:ss] Speaker: text" lines.
    func transcript(from: Int = 0, limit: Int = .max) -> String {
        let slice = lines.dropFirst(from).suffix(limit)
        return slice.map { "[\(clock($0.at))] \($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    func clock(_ date: Date) -> String {
        let s = Int(max(0, date.timeIntervalSince(started)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var elapsed: String { clock(ended ?? Date()) }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}
