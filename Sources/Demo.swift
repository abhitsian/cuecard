import SwiftUI
import AppKit

/// `Cuecard --demo-render <script> <outdir> [fps] -name Sam -about "…"`: plays a scripted meeting through the real
/// pipeline (Jev judges every turn, Claude writes the suggestions) at speaking pace, and saves the live panel as PNG
/// frames plus events.json: every line, every Jev verdict with its latency, every card as it lands. For making a
/// demo video that shows the actual app. Pass -name/-about so your own settings aren't used (launch arguments
/// override them for this run only and are never saved).
///
/// Script lines: `Them(Priya): …` or `You(Sam): …`; `# title:` and `# context:` as in --simulate.
enum Demo {
    struct Event: Encodable {
        var t: Double
        var type: String
        var speaker: String? = nil
        var name: String? = nil
        var text: String? = nil
        var kind: String? = nil
        var owner: String? = nil
        var due: String? = nil
        var source: String? = nil
        var scores: [String: Double]? = nil
        var ms: Int? = nil
    }

    @MainActor
    static func run(script path: String, out: String, fps: Double) {
        isRendering = true
        // Taller than the default panel so the Captured section (where Jev's labels land) stays in view.
        let height = CGFloat(Double(ProcessInfo.processInfo.environment["DEMO_HEIGHT"] ?? "") ?? 960)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); exit(1) }
        var title = "Meeting", context = ""
        var lines: [(Speaker, String, String)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# title:") { title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("# context:") { context += String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) + "\n"; continue }
            guard let m = line.firstMatch(of: #/^(You|Them)(?:\((.+?)\))?:\s*(.+)$/#) else { continue }
            lines.append((m.1 == "You" ? .you : .them, m.2.map(String.init) ?? String(m.1), String(m.3)))
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = Session.shared
        let meeting = Meeting(title: title, mode: .general, goal: "", context: context)
        meeting.userTitled = true
        meeting.hearsThem = true
        session.meeting = meeting
        session.tab = .live
        let brain = Brain(meeting: meeting)
        var events: [Event] = []
        var started = Date()
        let clock = { Date().timeIntervalSince(started) }
        brain.onJudged = { speaker, text, scores, seconds in
            events.append(Event(t: clock(), type: "judged", speaker: speaker.rawValue, text: text, scores: scores, ms: Int(seconds * 1000)))
            print(String(format: "%6.1fs jev %4dms %@", clock(), Int(seconds * 1000), scores.keys.sorted().joined(separator: ",")))
        }
        brain.start()

        var seenCards: [UUID: String] = [:]
        var frame = 0
        var recording = false
        // The board is drawn after the run from snapshots taken at 30 fps: drawing it live is slower than real
        // time. Everything on it is worked out from the meeting's state and the clock, so this is exact.
        let board = ProcessInfo.processInfo.environment["DEMO_VIEW"] == "board"
        struct Snapshot { let at: Date; let lines: [Line]; let partial: [Speaker: String]; let names: [Speaker: String]
                          let cards: [Card]; let judgements: [Judgement]; let you: Float; let them: Float }
        var snapshots: [Snapshot] = []
        if board {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard recording else { return }
                    snapshots.append(Snapshot(at: Date(), lines: meeting.lines, partial: meeting.partial, names: meeting.partialNames,
                                              cards: meeting.cards, judgements: meeting.judgements, you: meeting.youLevel, them: meeting.themLevel))
                }
            }
        }
        func snapshot() {
            for card in meeting.cards {
                let state = "\(card.text)|\(card.resolved != nil)|\(card.done)"
                if seenCards[card.id] != state {
                    events.append(Event(t: clock(), type: seenCards[card.id] == nil ? "card" : "card-update", text: card.text,
                                        kind: card.kind.label, owner: card.owner, due: card.due, source: card.source))
                    print(String(format: "%6.1fs card %@ %@", clock(), card.kind.label, card.text))
                    seenCards[card.id] = state
                }
            }
            guard recording, !board else { return }
            let view = Group {
                if board {
                    BoardView().environmentObject(session).environmentObject(Prefs.shared).frame(width: 1920, height: 1080)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.115, blue: 0.13))
                        PanelView().environmentObject(session).environmentObject(Prefs.shared)
                    }
                    .frame(width: 384, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            let renderer = ImageRenderer(content: view)
            renderer.scale = board ? 1 : 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent(String(format: "frame-%05d.png", frame)))
                frame += 1
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in MainActor.assumeIsolated { snapshot() } }

        var index = 0
        func speak() {
            guard index < lines.count else {
                meeting.youLevel = 0; meeting.themLevel = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                    snapshot()
                    recording = false
                    if board {
                        let replay = Meeting(title: meeting.title, mode: meeting.mode, goal: "", context: "", started: meeting.started)
                        replay.hearsThem = true
                        for (n, s) in snapshots.enumerated() {
                            replay.lines = s.lines; replay.partial = s.partial; replay.partialNames = s.names
                            replay.cards = s.cards; replay.judgements = s.judgements; replay.youLevel = s.you; replay.themLevel = s.them
                            replay.ended = s.at  // the header clock reads the snapshot's moment
                            let view = BoardContent(meeting: replay, now: s.at).background(BoardStyle.bg).frame(width: 1920, height: 1080)
                            let renderer = ImageRenderer(content: view)
                            renderer.scale = 1
                            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                               let png = rep.representation(using: .png, properties: [:]) {
                                try? png.write(to: folder.appendingPathComponent(String(format: "frame-%05d.png", n)))
                                frame = n + 1
                            }
                        }
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try? encoder.encode(events).write(to: folder.appendingPathComponent("events.json"))
                    print("wrote \(frame) frames and \(events.count) events to \(out)")
                    Claude.shared.coolDown()
                    exit(0)
                }
                return
            }
            let (speaker, name, text) = lines[index]
            index += 1
            let words = text.split(separator: " ").map(String.init)
            let duration = min(6, max(2.2, Double(words.count) / 2.6))
            events.append(Event(t: clock(), type: "line", speaker: speaker.rawValue, name: name, text: text))
            // Words appear as they would from live speech recognition, with the speaker's level moving.
            for i in 1...words.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(words.count)) {
                    meeting.partial[speaker] = words.prefix(i).joined(separator: " ")
                    meeting.partialNames[speaker] = name
                    let level: Float = 0.35 + 0.3 * Float((i * 7919) % 10) / 10
                    if speaker == .you { meeting.youLevel = level; meeting.themLevel = 0.04 } else { meeting.themLevel = level; meeting.youLevel = 0.04 }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) {
                meeting.partial[speaker] = nil
                let line = Line(speaker: speaker, text: text, at: Date(), name: name)
                meeting.add(line)
                brain.heard(line)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { speak() }
            }
        }
        // Let the question bank get written first, as prep would, then start the clock and the meeting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            started = Date()
            meeting.started = started
            recording = true
            speak()
        }
        RunLoop.main.run()
    }
}
