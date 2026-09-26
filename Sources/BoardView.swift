import SwiftUI
import AppKit

/// The meeting board: a wide view beside the panel. The transcript runs on the left with Jev's verdict under each
/// turn; what Jev files lands in a 2x2 (Decisions, Tasks, Questions, Risks) with its words swirling across from
/// the line they came from; Cues shows what to ask or say next and which engine produced it (Jev picking from
/// your prep, or Claude writing). Laid out at 1920x1080 and scaled to the window, so the demo renders it as is.
enum Quadrant: String, CaseIterable {
    case decisions = "Decisions", tasks = "Tasks", questions = "Questions", risks = "Risks"

    var color: Color {
        switch self {
        case .decisions: return Color(red: 0.72, green: 0.61, blue: 0.95)
        case .tasks: return Color(red: 0.42, green: 0.84, blue: 0.55)
        case .questions: return Color(red: 0.50, green: 0.71, blue: 0.96)
        case .risks: return Color(red: 0.95, green: 0.53, blue: 0.48)
        }
    }
    var symbol: String {
        switch self {
        case .decisions: return "checkmark.seal.fill"
        case .tasks: return "checklist"
        case .questions: return "questionmark.circle.fill"
        case .risks: return "exclamationmark.triangle.fill"
        }
    }
    var empty: String {
        switch self {
        case .decisions: return "What gets agreed lands here"
        case .tasks: return "Who does what, by when"
        case .questions: return "Open questions, ticked off when answered"
        case .risks: return "Blockers and worries"
        }
    }
    /// Jev's categories that file into this box (follow-ups count as tasks).
    var categories: [String] {
        switch self {
        case .decisions: return ["decision"]
        case .tasks: return ["action_item", "next_step"]
        case .questions: return ["open_question"]
        case .risks: return ["risk"]
        }
    }
}

extension CardKind {
    var quadrant: Quadrant? {
        switch self {
        case .decision: return .decisions
        case .action, .nextStep: return .tasks
        case .question: return .questions
        case .risk: return .risks
        default: return nil
        }
    }
}

extension Card {
    /// Suggestions Jev chose from the prepared bank, versus words Claude wrote.
    var pickedByJev: Bool { source?.hasPrefix("From your prep") == true || source == "Asked earlier" }
    /// Claude rewrote a captured sentence into a clean note.
    var tidied: Bool { kind.quadrant != nil && quote != nil && quote != text && !refining }
}

enum BoardStyle {
    static let bg = Color(red: 0.067, green: 0.071, blue: 0.082)
    static let surface = Color(red: 0.105, green: 0.11, blue: 0.125)
    static let ink = Color(red: 0.925, green: 0.914, blue: 0.894)
    static let dim = Color(red: 0.655, green: 0.64, blue: 0.61)
    static let jev = Color(red: 0.97, green: 0.73, blue: 0.32)
    static let claude = Color(red: 0.93, green: 0.86, blue: 0.74)
    static let you = Color(red: 0.40, green: 0.84, blue: 0.78)
    static let them = Color(red: 0.93, green: 0.86, blue: 0.74)
}

private struct BoardAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct BoardView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 1920, geo.size.height / 1080)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Group {
                    if let meeting = session.meeting {
                        BoardContent(meeting: meeting, now: context.date)
                    } else {
                        VStack(spacing: 14) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                            Text("Start listening (⌃⌥A) and the board fills as people talk.")
                                .font(.system(size: 30, weight: .medium)).foregroundStyle(BoardStyle.dim)
                        }
                        .frame(width: 1920, height: 1080)
                    }
                }
                .frame(width: 1920, height: 1080)
                .background(BoardStyle.bg)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .background(BoardStyle.bg)
    }
}

struct BoardContent: View {
    @ObservedObject var meeting: Meeting
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            HStack(alignment: .top, spacing: 30) {
                transcript.frame(width: 700)
                VStack(spacing: 22) {
                    grid
                    cues
                }
            }
        }
        .padding(.horizontal, 44).padding(.vertical, 34)
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .coordinateSpace(name: "board")
        .overlayPreferenceValue(BoardAnchors.self) { anchors in
            GeometryReader { proxy in swirl(anchors: anchors, proxy: proxy) }
        }
    }

    // MARK: Header

    private var header: some View {
        let ms = meeting.judgements.map(\.ms).sorted()
        let median = ms.isEmpty ? 0 : ms[ms.count / 2]
        let drafts = meeting.cards.filter { [.ask, .say, .answer].contains($0.kind) && !$0.pickedByJev }.count
        let tidied = meeting.cards.filter(\.tidied).count
        return HStack(spacing: 18) {
            Circle().fill(meeting.live ? Color(red: 1, green: 0.36, blue: 0.33) : BoardStyle.dim).frame(width: 14, height: 14)
            Text(meeting.title).font(.system(size: 34, weight: .bold)).foregroundStyle(BoardStyle.ink).lineLimit(1)
            Text(meeting.elapsed).font(.system(size: 26, weight: .medium).monospacedDigit()).foregroundStyle(BoardStyle.dim)
            Spacer()
            statPill(engine: "Jev", color: BoardStyle.jev, symbol: "bolt.fill",
                     text: "\(meeting.judgements.count) turns judged" + (median > 0 ? " · median \(median) ms" : ""))
            statPill(engine: "Claude", color: BoardStyle.claude, symbol: "sparkle",
                     text: "\(drafts) written · \(tidied) tidied")
        }
    }

    private func statPill(engine: String, color: Color, symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold))
            Text(engine).font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 20, weight: .medium).monospacedDigit()).foregroundStyle(BoardStyle.ink.opacity(0.85))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSCRIPT").font(.system(size: 17, weight: .bold)).tracking(1.5).foregroundStyle(BoardStyle.dim)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 16) {
                Spacer(minLength: 0)
                ForEach(meeting.lines.suffix(meeting.partial.values.contains { !$0.isEmpty } ? 4 : 5)) { line in lineRow(line) }
                ForEach(Array(meeting.partial.keys.sorted { $0.rawValue < $1.rawValue }), id: \.self) { speaker in
                    if let text = meeting.partial[speaker], !text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.partialNames[speaker] ?? speaker.rawValue)
                                .font(.system(size: 20, weight: .bold)).foregroundStyle(speaker == .you ? BoardStyle.you : BoardStyle.them)
                            Text(text + " ▍").font(.system(size: 26)).foregroundStyle(BoardStyle.ink.opacity(0.6))
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).stroke(BoardStyle.ink.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipped()
        }
        .frame(maxHeight: .infinity)
    }

    private func lineRow(_ line: Line) -> some View {
        let verdict = meeting.judgements.last { $0.text == line.text || ($0.text.contains(line.text) && $0.text.hasSuffix(line.text)) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(line.name ?? line.speaker.rawValue)
                .font(.system(size: 20, weight: .bold)).foregroundStyle(line.speaker == .you ? BoardStyle.you : BoardStyle.them)
            Text(line.text).font(.system(size: 26)).foregroundStyle(BoardStyle.ink).fixedSize(horizontal: false, vertical: true)
            if let verdict { verdictRow(verdict) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(BoardStyle.surface))
        .anchorPreference(key: BoardAnchors.self, value: .bounds) { ["line-\(line.id)": $0] }
    }

    /// Jev's call on the turn: how long it took, and the boxes it scored at 0.7 or above. Solid when the item was
    /// actually filed, outlined when Jev leaned that way but the item wasn't kept (Cuecard files at most two per turn).
    private func verdictRow(_ v: Judgement) -> some View {
        let appear = min(1, max(0, now.timeIntervalSince(v.at) / 0.25))
        let hits: [(String, Quadrant?, Double)] = [
            ("asked_you", nil, v.scores["asked_you"] ?? 0),
        ] + Quadrant.allCases.flatMap { q in q.categories.map { (key: $0, q: q, s: v.scores[$0] ?? 0) } }.map { ($0.key, $0.q, $0.s) }
        let strong = hits.filter { $0.2 >= 0.7 }.sorted { $0.2 > $1.2 }
        let filedKinds = Set(meeting.cards.filter { card in
            card.kind.quadrant != nil && abs(card.at.timeIntervalSince(v.at)) < 1.5
        }.compactMap { $0.kind.quadrant })
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 14, weight: .bold))
                Text("Jev \(v.ms) ms").font(.system(size: 17, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(BoardStyle.bg)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(BoardStyle.jev))
            if strong.isEmpty {
                Text("nothing to file").font(.system(size: 17, weight: .medium)).foregroundStyle(BoardStyle.dim)
            }
            ForEach(Array(strong.prefix(3).enumerated()), id: \.offset) { _, hit in
                let color = hit.1?.color ?? BoardStyle.jev
                let filed = hit.1.map { filedKinds.contains($0) } ?? true
                Text("\(hit.1?.rawValue ?? "Asked you → Claude") \(String(format: "%.2f", hit.2))")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(filed ? BoardStyle.bg : color)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(filed ? color : Color.clear))
                    .overlay(Capsule().stroke(color, lineWidth: 1.5))
            }
        }
        .opacity(appear)
    }

    // MARK: 2x2

    private var grid: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) { tile(.decisions); tile(.tasks) }
            HStack(spacing: 18) { tile(.questions); tile(.risks) }
        }
        .frame(height: 640)
    }

    private func tile(_ q: Quadrant) -> some View {
        let items = meeting.cards.filter { $0.kind.quadrant == q && !$0.dismissed }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: q.symbol).font(.system(size: 20, weight: .bold))
                Text(q.rawValue.uppercased()).font(.system(size: 19, weight: .heavy)).tracking(1.2)
                Spacer()
                Text("\(items.count)").font(.system(size: 22, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(q.color)
            if items.isEmpty {
                Text(q.empty).font(.system(size: 20)).foregroundStyle(BoardStyle.dim.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 10) {
                if items.count > 3 {
                    Text("+\(items.count - 3) earlier").font(.system(size: 16, weight: .medium)).foregroundStyle(BoardStyle.dim)
                }
                ForEach(items.suffix(3)) { card in item(card, q) }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 311, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(q.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(q.color.opacity(0.28), lineWidth: 1.5))
        .clipped()
        .anchorPreference(key: BoardAnchors.self, value: .bounds) { ["quad-\(q.rawValue)": $0] }
    }

    private func item(_ card: Card, _ q: Quadrant) -> some View {
        let age = now.timeIntervalSince(card.at)
        let landed = min(1, max(0, (age - 0.8) / 0.3))
        let fresh = max(0, 1 - max(0, age - 1.1) / 2.5)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if card.resolved != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(q.color)
                }
                Text(card.text).font(.system(size: 22, weight: .medium))
                    .foregroundStyle(card.resolved != nil ? BoardStyle.dim : BoardStyle.ink)
                    .strikethrough(card.resolved != nil, color: BoardStyle.dim)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                if let owner = card.owner { tag(owner, q.color) }
                if let due = card.due { tag(due, q.color) }
                if let score = card.score {
                    Text("Jev \(String(format: "%.2f", score))").font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(BoardStyle.jev)
                }
                if card.tidied {
                    Label("tidied by Claude", systemImage: "sparkle").font(.system(size: 15, weight: .medium)).foregroundStyle(BoardStyle.claude.opacity(0.8))
                }
                if let answer = card.resolved {
                    Text("answered: \(answer)").font(.system(size: 15)).foregroundStyle(BoardStyle.dim).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(q.color.opacity(0.06 + 0.18 * fresh)))
        .opacity(landed)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: Cues

    private var cues: some View {
        let recent = Array(meeting.cards.filter { ($0.kind == .ask || $0.kind == .say) && !$0.dismissed }.suffix(3).reversed())
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("CUES").font(.system(size: 17, weight: .bold)).tracking(1.5).foregroundStyle(BoardStyle.dim)
                Text("what to ask or say next, and who came up with it").font(.system(size: 18)).foregroundStyle(BoardStyle.dim.opacity(0.8))
            }
            HStack(alignment: .top, spacing: 16) {
                if recent.isEmpty {
                    Text("Jev picks from your prepared questions; Claude writes when you're asked or an answer is vague.")
                        .font(.system(size: 20)).foregroundStyle(BoardStyle.dim.opacity(0.7))
                }
                ForEach(recent) { card in cue(card) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cue(_ card: Card) -> some View {
        let jev = card.pickedByJev
        let color = jev ? BoardStyle.jev : BoardStyle.claude
        let age = now.timeIntervalSince(card.at)
        let fresh = max(0, 1 - age / 3)
        let detail: String = jev
            ? "picked from your prep" + (card.score.map { " · \(String(format: "%.2f", $0))" } ?? "")
            : (card.kind == .say ? "you were asked" : (card.source ?? "").components(separatedBy: " · ").first?.lowercased() ?? "")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: jev ? "bolt.fill" : "sparkle").font(.system(size: 15, weight: .bold))
                Text(jev ? "JEV PICKED" : "CLAUDE WROTE").font(.system(size: 15, weight: .heavy)).tracking(1)
                Text(detail).font(.system(size: 15, weight: .medium)).foregroundStyle(color.opacity(0.75)).lineLimit(1)
                Spacer(minLength: 0)
                Text(card.kind == .say ? "SAY" : "ASK").font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(BoardStyle.bg).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(color))
            }
            .foregroundStyle(color)
            Text(card.text.components(separatedBy: "\n").first ?? card.text)
                .font(.system(size: card.kind == .say ? 23 : 21, weight: card.kind == .say ? .semibold : .medium))
                .foregroundStyle(BoardStyle.ink).lineLimit(4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.08 + 0.12 * fresh)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.25 + 0.6 * fresh), lineWidth: 1.5))
        .opacity(min(1, age / 0.35))
    }

    // MARK: Swirl

    /// Words from each newly filed item fly from the transcript line they came from into their box, along a curve
    /// with a spin. Worked out from the item's age, so it animates live and renders the same frame by frame.
    @ViewBuilder
    private func swirl(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        let flying = meeting.cards.filter { card in
            card.kind.quadrant != nil && now.timeIntervalSince(card.at) < 1.3 && now.timeIntervalSince(card.at) >= 0
        }
        ZStack {
            ForEach(flying) { card in
                if let q = card.kind.quadrant, let target = anchors["quad-\(q.rawValue)"] {
                    let source = sourceLine(for: card).flatMap { anchors["line-\($0.id)"] }
                    let from = source.map { proxy[$0] } ?? CGRect(x: 60, y: 900, width: 600, height: 80)
                    let to = proxy[target]
                    let words = Array((card.quote ?? card.text).split(separator: " ").prefix(9).map(String.init))
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        particle(word, index: i, count: words.count, age: now.timeIntervalSince(card.at), from: from, to: to, color: q.color)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func sourceLine(for card: Card) -> Line? {
        let quote = card.quote ?? card.text
        return meeting.lines.last { $0.text.contains(quote) || quote.contains($0.text) } ?? meeting.lines.last
    }

    private func particle(_ word: String, index i: Int, count: Int, age: TimeInterval, from: CGRect, to: CGRect, color: Color) -> some View {
        let t = min(1, max(0, (age - Double(i) * 0.045) / 0.8))
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out cubic
        let start = CGPoint(x: from.minX + 30 + CGFloat((i * 97) % max(1, Int(from.width - 120))), y: from.midY)
        let end = CGPoint(x: to.minX + 60 + CGFloat(i % 3) * 40, y: to.minY + 70)
        // A control point pushed off the straight line, alternating sides, so the words curve and cross.
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, sqrt(dx * dx + dy * dy))
        let side: CGFloat = i % 2 == 0 ? 1 : -1
        let bulge = 180 + CGFloat(i % 4) * 40
        let control = CGPoint(x: mid.x - dy / length * bulge * side, y: mid.y + dx / length * bulge * side)
        let u = CGFloat(e)
        let a: CGFloat = (1 - u) * (1 - u), b: CGFloat = 2 * (1 - u) * u, c: CGFloat = u * u
        let x: CGFloat = a * start.x + b * control.x + c * end.x
        let y: CGFloat = a * start.y + b * control.y + c * end.y
        // A small spiral on top of the curve, fading as the word arrives.
        let phase: Double = Double(e) * Double.pi * 3 + Double(i)
        let wobble: CGFloat = CGFloat(sin(phase)) * 26 * (1 - u)
        var opacity: Double = 1
        if t <= 0 { opacity = 0 } else if t < 0.12 { opacity = t / 0.12 } else if t > 0.88 { opacity = (1 - t) / 0.12 }
        let spin: Double = (1 - Double(e)) * Double(side) * 35
        return Text(word)
            .font(.system(size: 26 - 8 * u, weight: .bold))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.6), radius: 10)
            .rotationEffect(.degrees(spin))
            .position(x: x + wobble, y: y + wobble * 0.6)
            .opacity(opacity)
    }
}

/// The board in its own resizable window.
final class BoardWindow {
    static let shared = BoardWindow()
    private var window: NSWindow?

    func show(session: Session) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 810), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Cuecard · Meeting board"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 960, height: 540)
            w.contentView = NSHostingView(rootView: BoardView().environmentObject(session).environmentObject(Prefs.shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
