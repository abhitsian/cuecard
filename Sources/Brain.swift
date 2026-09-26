import Foundation

/// Listens to the transcript and decides what to show. On every finished turn, Jev sorts what was said into
/// the core categories and the mode's signals, and picks the prepared question that fits the moment. Code
/// applies the policy. Claude writes only what's new: answers when the user is asked something, fresh
/// questions when nothing prepared fits, tidy wording for captured items, the running memory and the recap.
final class Brain {
    /// Model for tidying captures and the running memory. Haiku through `claude -p` holds the reply open for
    /// 6-30 s after the text arrives; Sonnet 5 finishes the same job in 1-3 s.
    static let utilityModel = SuggestModel.sonnet.rawValue

    let meeting: Meeting
    private let prefs = Prefs.shared
    private let claude = Claude.shared
    private var jev: Jev.Client?
    /// A SAY card arrived (the user was asked something).
    var onUrgent: (() -> Void)?

    private var turn: (speaker: Speaker, lines: [Line])?
    private var turnTimer: Timer?
    private var ticker: Timer?

    enum Reason {
        case asked(String), nudge, vague(String), signal(String, String), periodic, userQuestion(String)
        /// A step of an answer frame is weak or missing: frame, step, what failed, the probe hint, what was said.
        case gap(frame: String, step: String, weak: String, probe: String, said: String)
    }
    private var pending: [Reason] = []
    private var generating = false
    private var lastGenerated = Date.distantPast
    private var lastAskShown = Date.distantPast
    private var turnsSinceAsk = 0
    private var pauseUntil = Date.distantPast

    private var memory = ""
    private var memoryThrough = 0
    private var memoryBusy = false
    private var refineQueue: [UUID] = []
    private var refineBusy = false

    init(meeting: Meeting) {
        self.meeting = meeting
        if prefs.useJev, let key = prefs.jevKey { jev = Jev.Client(apiKey: key, timeout: 6) }
    }

    var usesJev: Bool { jev != nil }

    func start() {
        claude.warm(model: prefs.model.rawValue, system: Prompts.live)
        claude.warm(model: Brain.utilityModel, system: Prompts.refine)
        ticker = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.tick() }
        prepareBank()
    }

    func stop() {
        turnTimer?.invalidate()
        ticker?.invalidate()
        flushTurn()
    }

    // MARK: Transcript in

    func heard(_ line: Line) {
        if line.speaker == .them, line.text.contains("?"), mentionsUser(line.text) {
            enqueue(.asked(line.text)) // don't wait for the turn to end
        }
        if let open = turn, open.speaker != line.speaker { flushTurn() }
        if turn == nil { turn = (line.speaker, []) }
        turn?.lines.append(line)
        turnTimer?.invalidate()
        let long = (turn?.lines.first.map { Date().timeIntervalSince($0.at) } ?? 0) > 30
        if long { flushTurn(); return }
        turnTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in self?.flushTurn() }
    }

    /// Every Jev verdict on a turn, with how long Jev took: the demo renderer shows these.
    var onJudged: ((Speaker, String, [String: Double], TimeInterval) -> Void)?

    /// The user asked for help now (⌃⌥N or the button).
    func nudge() { enqueue(.nudge, jump: true) }

    /// The user typed a private question.
    func ask(_ question: String) { enqueue(.userQuestion(question), jump: true) }

    private func flushTurn() {
        turnTimer?.invalidate()
        guard let open = turn, !open.lines.isEmpty else { turn = nil; return }
        turn = nil
        guard prefs.autoSuggest, meeting.phase == .listening else { return }
        let before = Array(meeting.lines.prefix(while: { $0.id != open.lines.first?.id }).suffix(8))
        if let jev {
            Task { await judge(open.speaker, open.lines, before: before, jev: jev) }
        } else {
            heuristics(open.speaker, open.lines)
        }
    }

    private func mentionsUser(_ text: String) -> Bool {
        let name = prefs.name.lowercased()
        guard name.count > 2 else { return false }
        let lower = text.lowercased()
        if lower.contains(name) { return true }
        // Recognizers often drop an 'h' or double a letter: compare on consonant skeletons.
        let skeleton = { (s: String) in String(s.filter { !"aeiouh".contains($0) }) }
        let target = skeleton(name)
        return lower.split(whereSeparator: { !$0.isLetter }).contains { skeleton(String($0)) == target && $0.count >= name.count - 2 }
    }

    // MARK: Jev

    private func judge(_ speaker: Speaker, _ lines: [Line], before: [Line], jev: Jev.Client) async {
        let text = lines.map(\.text).joined(separator: " ")
        let sentences = lines.map(\.text)
        let (open, bankItems, attendees, lookupTopic) = await MainActor.run {
            (meeting.openQuestions.prefix(12).map { ($0.id, $0.text) },
             meeting.bank.filter { !$0.asked }.prefix(40).map { ($0.id, $0.text) },
             meeting.attendees, meeting.lookupTopic)
        }
        let mode = meeting.mode
        var state: [String: Any] = [
            "meeting": ["type": "\(mode.label). \(mode.blurb)", "user": prefs.name, "attendees": attendees,
                        "topic": lookupTopic ?? ""],
            "recent": before.map { "\($0.speaker.rawValue): \($0.text)" },
            "latest": ["speaker": speaker.rawValue, "text": text, "sentences": sentences],
        ]
        var questions: [String: Jev.Question] = [:]
        for category in Playbook.Category.allCases where !(category == .askedYou && speaker == .you) {
            questions[category.rawValue] = .noul(category.question)
        }
        questions["vague"] = .noul(Playbook.vagueQuestion)
        questions["filler"] = .noul(Playbook.fillerQuestion)
        // Once context has been looked up for a topic, notice when the conversation leaves it.
        if lookupTopic != nil {
            questions["topic_shift"] = .noul("Does `latest.text` move the conversation to a different subject from `meeting.topic`: a new project, problem, customer or decision, not a continuation or detail of the same subject?")
        }
        if speaker == .them {
            for signal in mode.signals { questions["sig_" + signal.key] = .noul(signal.question) }
        }
        var owners: [(key: String, meaning: String?)] = [("you", "The user (speaker You) will do it"), ("them", "Someone else in the meeting will do it"), ("unclear", "No clear owner")]
        for name in attendees.prefix(6) { owners.append((name, "\(name) will do it")) }
        questions["owner"] = .choice("If `latest.text` contains a commitment to do a task, who takes it? Speaker '\(speaker.rawValue)' said it.", options: owners)
        if sentences.count > 1 {
            let options = sentences.enumerated().map { (key: "s\($0.offset)", meaning: Optional($0.element)) }
            questions["s_action"] = .choice("Which sentence in `latest.sentences` states the commitment or task most directly?", options: options)
            questions["s_decision"] = .choice("Which sentence in `latest.sentences` states the decision most directly?", options: options)
            questions["s_question"] = .choice("Which sentence in `latest.sentences` asks the open question?", options: options)
            questions["s_signal"] = .choice("Which sentence in `latest.sentences` shows most about how the speaker feels or thinks?", options: options)
        }
        if !open.isEmpty {
            state["open_questions"] = Dictionary(uniqueKeysWithValues: open.enumerated().map { ("q\($0.offset)", $0.element.1) })
            var options = open.enumerated().map { (key: "q\($0.offset)", meaning: Optional($0.element.1)) }
            options.append((key: "none", meaning: "It doesn't answer any of them"))
            questions["resolves"] = .choice("Which question in `open_questions` does `latest.text` answer?", options: options)
        }

        let finalState = state, finalQuestions = questions
        let asked = Date()
        async let categories = try? jev.ask(state: finalState, questions: finalQuestions)
        async let bankPick = pickFromBank(speaker: speaker, state: finalState, items: bankItems, jev: jev)
        async let framed: Void = judgeFrames(speaker: speaker, text: text, before: before, jev: jev)
        let (answers, pick, _) = await (categories, bankPick, framed)
        let judgedIn = Date().timeIntervalSince(asked)
        await MainActor.run {
            if let answers {
                let scores = answers.answers.compactMapValues(\.noul).filter { $0.value >= 0.5 }
                self.meeting.judgements.append(Judgement(speaker: speaker, text: text, scores: scores, ms: Int(judgedIn * 1000), at: Date()))
                if (scores["topic_shift"] ?? 0) >= 0.8, text.split(separator: " ").count >= 8 {
                    Log.write("topic: shift \(String(format: "%.2f", scores["topic_shift"] ?? 0)) from \"\(lookupTopic ?? "")\" | \(text.prefix(80))")
                    self.meeting.topicShifted = true
                }
                self.onJudged?(speaker, text, scores, judgedIn)
            }
            if let answers { self.apply(answers.answers, speaker: speaker, text: text, sentences: sentences, open: open.map(\.0)) }
            else { self.heuristics(speaker, lines) }
            if let pick { self.applyBank(pick, speaker: speaker, items: bankItems.map(\.0)) }
        }
    }

    private func pickFromBank(speaker: Speaker, state: [String: Any], items: [(UUID, String)], jev: Jev.Client) async -> [String: Jev.Answer]? {
        guard !items.isEmpty else { return nil }
        var state = state
        state["questions"] = Dictionary(uniqueKeysWithValues: items.enumerated().map { ("b\($0.offset)", $0.element.1) })
        var options = items.enumerated().map { (key: "b\($0.offset)", meaning: Optional($0.element.1)) }
        options.append((key: "none", meaning: "None of them fits this moment"))
        let question: Jev.Question = speaker == .them
            ? .choice("The other side just finished speaking (`latest.text`). Which question in `questions` is the best thing for the user to ask next, as a natural follow-up to what was just said? Choose none if none follows naturally from it.", options: options)
            : .choice("Which question in `questions` did the user just ask in `latest.text`, in any wording? Choose none if they didn't ask one of them.", options: options)
        return try? await jev.ask(state: state, questions: [speaker == .them ? "best_next" : "just_asked": question]).answers
    }

    private func apply(_ a: [String: Jev.Answer], speaker: Speaker, text: String, sentences: [String], open: [UUID]) {
        func p(_ key: String) -> Double { a[key]?.noul ?? 0 }
        func sentence(_ key: String) -> String {
            guard let choice = a[key]?.choice, let i = Int(choice.dropFirst()), sentences.indices.contains(i) else { return text }
            return sentences[i]
        }
        let scores = a.compactMapValues(\.noul).filter { $0.value >= 0.5 }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.sorted()
        Log.write("jev \(speaker.rawValue): \(scores.joined(separator: " ")) | \(text.prefix(80))")

        if let choice = a["resolves"]?.choice, choice != "none", (a["resolves"]?.probabilities?[choice] ?? 0) >= 0.6,
           let i = Int(choice.dropFirst()), open.indices.contains(i) {
            meeting.update(open[i]) { $0.resolved = text }
        }
        if p("filler") >= 0.75, p("asked_you") < 0.6 { return }

        if speaker == .them, p("asked_you") >= 0.7, meeting.mode.captures.contains(.askedYou) { enqueue(.asked(text)) }

        // At most two captures per turn, from different families, strongest first. One sentence that is an
        // action item, a next step and a fact is filed once, as the action item.
        var owner: String?
        switch a["owner"]?.choice {
        case "you": owner = "You"
        case "them": owner = "Them"
        case "unclear", nil: owner = nil
        case let name?: owner = name
        }
        let candidates: [(family: String, p: Double, make: () -> Card)] = [
            ("commit", p("action_item"), { Card(kind: .action, text: sentence("s_action"), owner: owner, due: Brain.due(in: sentence("s_action")), quote: sentence("s_action"), source: "Jev") }),
            ("commit", p("next_step") - 0.05, { Card(kind: .nextStep, text: text, due: Brain.due(in: text), quote: text, source: "Jev") }),
            ("decision", p("decision"), { Card(kind: .decision, text: sentence("s_decision"), quote: sentence("s_decision"), source: "Jev") }),
            // An open question counts whoever raised it, including one put to the user: it stays open until a
            // later turn answers it (Jev's `resolves`), which is what makes it worth tracking.
            ("question", p("open_question"), { Card(kind: .question, text: sentence("s_question"), quote: sentence("s_question"), source: "Jev") }),
            ("risk", p("risk") - 0.02, { Card(kind: .risk, text: text, quote: text, source: "Jev") }),
            ("fact", text.hasSuffix("?") ? 0 : p("key_fact") - 0.12, { Card(kind: .fact, text: text, quote: text, source: "Jev") }),
        ]
        var families: Set<String> = []
        var taken = 0
        let allowed = meeting.mode.captures
        for c in candidates.sorted(by: { $0.p > $1.p }) where c.p >= (taken == 0 ? 0.7 : 0.85) && !families.contains(c.family) && taken < 2 {
            let kind = c.make().kind
            let category: Playbook.Category = [.action: .action, .nextStep: .nextStep, .decision: .decision, .question: .openQuestion, .risk: .risk][kind] ?? .fact
            guard allowed.contains(category) else { continue }
            var card = c.make()
            card.score = c.p
            capture(card)
            families.insert(c.family)
            taken += 1
        }

        // One signal card per turn: the strongest, labelled with every signal that clearly fired.
        let fired = meeting.mode.signals.map { ($0, p("sig_" + $0.key)) }.filter { $0.1 >= 0.75 }.sorted { $0.1 > $1.1 }
        var signalled = false
        if let (top, _) = fired.first {
            let words = sentence("s_signal")
            let label = ([top.label] + fired.dropFirst().filter { $0.1 >= 0.85 }.map(\.0.label)).prefix(2).joined(separator: " · ")
            meeting.add(Card(kind: .signal, text: words, quote: words, source: label))
            // With answer frames in play, the frame gaps drive follow-ups; generic tells only mark the map.
            let generic: Set<String> = ["no_specifics", "unquantified", "surface", "we_not_i"]
            if let concern = fired.first(where: { !$0.0.positive && (meeting.frames.isEmpty || !generic.contains($0.0.key)) }) {
                signalled = true
                enqueue(.signal(concern.0.label, words))
            }
        }
        if speaker == .them, p("vague") >= 0.8, !signalled, p("asked_you") < 0.7, meeting.frames.isEmpty { enqueue(.vague(text)) }
        if speaker == .them { turnsSinceAsk += 1 }
    }

    private func applyBank(_ a: [String: Jev.Answer], speaker: Speaker, items: [UUID]) {
        if let best = a["best_next"], let choice = best.choice, choice != "none", let i = Int(choice.dropFirst()), items.indices.contains(i) {
            let probability = best.probabilities?[choice] ?? 0
            Log.write("jev bank: best \(choice) p=\(String(format: "%.2f", probability))")
            guard probability >= 0.4, Date().timeIntervalSince(lastAskShown) > 20,
                  let question = meeting.bank.first(where: { $0.id == items[i] }),
                  question.surfacedAt.map({ Date().timeIntervalSince($0) > 240 }) ?? true else { return }
            meeting.bank = meeting.bank.map { var q = $0; if q.id == question.id { q.surfacedAt = Date() }; return q }
            let source = question.live ? "Asked earlier" : "From your prep · \(question.topic)"
            if meeting.add(Card(kind: .ask, text: question.text, source: source, score: probability)) != nil {
                lastAskShown = Date()
                turnsSinceAsk = 0
            }
        }
        if let asked = a["just_asked"], let choice = asked.choice, choice != "none",
           (asked.probabilities?[choice] ?? 0) >= 0.55, let i = Int(choice.dropFirst()), items.indices.contains(i) {
            let id = items[i]
            meeting.bank = meeting.bank.map { var q = $0; if q.id == id { q.asked = true }; return q }
            if let text = meeting.bank.first(where: { $0.id == id })?.text,
               let card = meeting.cards.last(where: { $0.kind == .ask && $0.text == text }) {
                meeting.update(card.id) { $0.done = true }
            }
            Log.write("jev bank: user asked \(choice)")
        }
    }

    // MARK: Answer frames

    private var lastGapAt = Date.distantPast

    /// Maps what the other side just said onto the frames' steps, then runs those steps' tests against
    /// everything said for them so far. A step that turns weak gets a follow-up.
    private func judgeFrames(speaker: Speaker, text: String, before: [Line], jev: Jev.Client) async {
        let frames = await MainActor.run { meeting.frames }
        guard speaker == .them, !frames.isEmpty, text.split(separator: " ").count >= 6 else { return }
        let steps: [(frame: Frame, node: Frame.Node)] = frames.flatMap { frame in frame.nodes.map { (frame, $0) } }
        var options = steps.enumerated().map { (key: "n\($0.offset)", meaning: Optional("\($0.element.frame.name), \($0.element.node.label): \($0.element.node.about)")) }
        options.append((key: "none", meaning: "None of these: small talk, logistics, a question back, or another topic"))
        let state: [String: Any] = [
            "meeting": ["type": meeting.mode.label, "user": prefs.name],
            "recent": before.map { "\($0.speaker.rawValue): \($0.text)" },
            "latest": ["speaker": speaker.rawValue, "text": text],
        ]
        guard let routed = try? await jev.ask(state: state, questions: [
            "step": .choice("The other side (speaker Them) is answering. Which part of a structured answer does `latest.text` mainly address?", options: options)
        ]).answers["step"] else { return }
        let picked = (routed.probabilities ?? [:]).filter { $0.key != "none" && $0.value >= 0.2 }
            .sorted { $0.value > $1.value }.prefix(3).compactMap { Int($0.key.dropFirst()) }.filter { steps.indices.contains($0) }
        guard !picked.isEmpty else { return }

        // Judge each chosen step on everything said for it so far, this turn included.
        let evidence = await MainActor.run { picked.map { meeting.state(steps[$0].frame, steps[$0].node).evidence + [text] } }
        var stepState: [String: Any] = [:]
        var questions: [String: Jev.Question] = [:]
        for (slot, index) in picked.enumerated() {
            let step = steps[index]
            stepState["s\(slot)"] = ["step": step.node.label, "about": step.node.about, "text": evidence[slot].suffix(6).joined(separator: " ")]
            for test in step.node.tests {
                questions["s\(slot)|\(test.key)"] = .noul("Consider only `steps.s\(slot).text`, what the speaker has said so far about \(step.node.label.lowercased()). \(test.question)")
            }
        }
        guard let judged = try? await jev.ask(state: ["steps": stepState, "meeting": ["type": meeting.mode.label]], questions: questions).answers else { return }

        await MainActor.run {
            for (slot, index) in picked.enumerated() {
                let step = steps[index]
                let id = "\(step.frame.id).\(step.node.key)"
                var node = meeting.map[id] ?? NodeState()
                node.evidence = evidence[slot]
                for test in step.node.tests { node.scores[test.key] = judged["s\(slot)|\(test.key)"]?.noul }
                node.failing = step.node.tests.filter { (node.scores[$0.key] ?? 1) < 0.45 }.map(\.key)
                node.status = node.failing.isEmpty ? .strong : .weak
                node.updated = Date()
                meeting.map[id] = node
                Log.write("frame \(id): \(node.status) " + node.scores.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: " "))

            }
            followUpGap()
        }
    }

    /// Suggests a follow-up for the most recently touched step that has a failed test nobody has followed up on.
    /// Called after each judgement and on the ticker, so a gap found while Claude was busy isn't lost.
    private func followUpGap() {
        guard prefs.autoSuggest, meeting.phase == .listening, Date().timeIntervalSince(lastGapAt) > 15,
              !pending.contains(where: { if case .gap = $0 { return true }; return false }) else { return }
        var best: (frame: Frame, node: Frame.Node, test: Frame.Test, updated: Date)?
        for frame in meeting.frames {
            for node in frame.nodes {
                let state = meeting.state(frame, node)
                guard state.status == .weak, Date().timeIntervalSince(state.updated) < 150,
                      state.probedAt.map({ Date().timeIntervalSince($0) > 45 }) ?? true,
                      let test = node.tests.first(where: { state.failing.contains($0.key) && !state.probed.contains($0.key) }) else { continue }
                if best == nil || state.updated > best!.updated { best = (frame, node, test, state.updated) }
            }
        }
        guard let best else { return }
        let id = "\(best.frame.id).\(best.node.key)"
        lastGapAt = Date()
        meeting.map[id]?.probedAt = Date()
        meeting.map[id]?.probed.insert(best.test.key)
        enqueue(.gap(frame: best.frame.name, step: best.node.label, weak: best.test.weak, probe: best.test.probe,
                     said: meeting.state(best.frame, best.node).text))
    }

    /// The user asked to probe a step from the Map (weak or not yet covered).
    func probe(frame: Frame, node: Frame.Node) {
        let state = meeting.state(frame, node)
        let failing = node.tests.first { state.failing.contains($0.key) }
        let weak = failing?.weak ?? (state.status == .missing ? "Not covered yet" : "Could go deeper")
        let probe = failing?.probe ?? node.tests.first?.probe ?? "Ask an open question about \(node.label.lowercased())."
        meeting.map["\(frame.id).\(node.key)", default: NodeState()].probedAt = Date()
        if let failing { meeting.map["\(frame.id).\(node.key)"]?.probed.insert(failing.key) }
        enqueue(.gap(frame: frame.name, step: node.label, weak: weak, probe: probe, said: state.text), jump: true)
    }

    // MARK: Without Jev

    private func heuristics(_ speaker: Speaker, _ lines: [Line]) {
        for line in lines {
            let t = line.text.lowercased()
            if Brain.matches(t, #"\b(i'll|i will|we'll|we will|can you|could you|let me|action item|i can take|follow up on|send (you|over|out|it))\b"#) {
                capture(Card(kind: .action, text: line.text, owner: t.hasPrefix("i ") || t.hasPrefix("i'll") ? speaker.rawValue : nil,
                             due: Brain.due(in: line.text), quote: line.text))
            }
            if Brain.matches(t, #"\b(let's go with|we('ve| have)? decided|decision is|we agreed|agreed|we'll go with|approved|signed off)\b"#) {
                capture(Card(kind: .decision, text: line.text, quote: line.text))
            }
            if Brain.matches(t, #"\b(next step|next steps|let's (meet|sync|regroup)|circle back|reconvene|follow-up meeting)\b"#) {
                capture(Card(kind: .nextStep, text: line.text, due: Brain.due(in: line.text), quote: line.text))
            }
            if Brain.matches(t, #"\b(risk|blocker|blocked|concern|worried|depends on|dependency|might slip|delay)\b"#) {
                capture(Card(kind: .risk, text: line.text, quote: line.text))
            }
            if speaker == .them, line.text.hasSuffix("?") {
                if mentionsUser(line.text) || Brain.matches(t, #"\b(you|your)\b"#) { enqueue(.asked(line.text)) }
                else { capture(Card(kind: .question, text: line.text, quote: line.text)) }
            }
        }
        if speaker == .them { turnsSinceAsk += 1 }
    }

    // MARK: Captures

    private func capture(_ card: Card) {
        var card = card
        card.refining = true
        guard let id = meeting.add(card) else { return }
        refineQueue.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refine() }
    }

    /// Haiku rewrites captured words into crisp notes, in place. The words heard stay as the quote.
    private func refine() {
        guard !refineBusy, !refineQueue.isEmpty else { return }
        refineBusy = true
        let ids = Array(refineQueue.prefix(8))
        refineQueue.removeFirst(ids.count)
        let rows = ids.enumerated().compactMap { i, id -> String? in
            guard let card = meeting.cards.first(where: { $0.id == id }) else { return nil }
            return "\(i + 1)|\(card.kind.label)|\(card.owner ?? "-")|\(card.quote ?? card.text)"
        }
        Log.write("refine: \(rows.count) items")
        Task {
            do {
                try await claude.lines(model: Brain.utilityModel, system: Prompts.refine, prompt: rows.joined(separator: "\n")) { line in
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, let n = Int(parts[0]), ids.indices.contains(n - 1), !parts[1].isEmpty else { return }
                    DispatchQueue.main.async { self.meeting.update(ids[n - 1]) { $0.text = Brain.plain(parts[1]); $0.refining = false } }
                }
            } catch {
                Log.write("refine: \(error.localizedDescription)")
            }
            await MainActor.run {
                for id in ids { self.meeting.update(id) { $0.refining = false } }
                self.refineBusy = false
                if !self.refineQueue.isEmpty { self.refine() }
            }
        }
    }

    // MARK: Claude suggestions

    private var recentAsked: [(at: Date, words: Set<String>)] = []

    private func enqueue(_ reason: Reason, jump: Bool = false) {
        guard meeting.phase == .listening || jump else { return }
        if case .asked(let q) = reason {
            let words = Meeting.words(q)
            recentAsked.removeAll { Date().timeIntervalSince($0.at) > 30 }
            if recentAsked.contains(where: { Meeting.overlap($0.words, words) > 0.5 }) { return }
            recentAsked.append((Date(), words))
        }
        if case .asked(let q) = reason, pending.contains(where: { if case .asked(let p) = $0 { return Meeting.overlap(Meeting.words(p), Meeting.words(q)) > 0.6 }; return false }) { return }
        if jump || isUrgent(reason) { pending.insert(reason, at: 0) } else { pending.append(reason) }
        if pending.count > 4 { pending = Array(pending.prefix(4)) }
        fire()
    }

    private func isUrgent(_ reason: Reason) -> Bool {
        switch reason {
        case .asked, .nudge, .userQuestion: return true
        default: return false
        }
    }

    private func fire() {
        guard !generating, let next = pending.first else { return }
        let urgent = isUrgent(next)
        let wait = max(urgent ? 0 : 9 - Date().timeIntervalSince(lastGenerated), pauseUntil.timeIntervalSinceNow)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.fire() }
            return
        }
        pending.removeFirst()
        generating = true
        meeting.thinking = true
        let prompt = buildPrompt(for: next)
        let model = prefs.model.rawValue
        var sayCard: UUID?
        Task {
            do {
                try await claude.lines(model: model, system: Prompts.live, prompt: prompt) { line in
                    DispatchQueue.main.async { sayCard = self.show(line, reason: next, sayCard: sayCard) }
                }
            } catch {
                Log.write("suggest: \(error.localizedDescription)")
                await MainActor.run {
                    self.meeting.notice = error.localizedDescription
                    self.pauseUntil = Date().addingTimeInterval(20)
                }
            }
            await MainActor.run {
                if self.pauseUntil < Date() { self.meeting.notice = nil }
                self.generating = false
                self.meeting.thinking = false
                self.lastGenerated = Date()
                self.fire()
            }
        }
    }

    /// Turns one line of Claude's reply into a card. Consecutive SAY lines build one card.
    private func show(_ raw: String, reason: Reason, sayCard: UUID?) -> UUID? {
        var line = raw
        while let first = line.first, "-*• ".contains(first) { line.removeFirst() }
        guard let colon = line.firstIndex(of: ":") else { return sayCard }
        let tag = line[..<colon].trimmingCharacters(in: .whitespaces)
        let body = Brain.plain(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty, let kind = CardKind.from(tag: tag) else { return sayCard }
        let source: String? = {
            switch reason {
            case .asked: return "You were asked"
            case .nudge: return "Help me now"
            case .vague: return "That was vague"
            case .signal(let label, _): return label
            case .periodic: return "New question"
            case .userQuestion: return "You asked Cuecard"
            case .gap(_, let step, let weak, _, _): return "\(step) · \(weak)"
            }
        }()
        if kind == .say, let sayCard, meeting.cards.contains(where: { $0.id == sayCard }) {
            meeting.update(sayCard) { $0.text += "\n" + body }
            return sayCard
        }
        var text = body
        var move: String?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.distance(from: text.startIndex, to: close) < 24 {
            move = String(text[text.index(after: text.startIndex)..<close])
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        var card = Card(kind: kind, text: text, source: [source, move].compactMap { $0 }.joined(separator: " · "))
        if kind == .action {
            let parts = body.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                card.owner = parts[0]
                card.text = parts[1]
                card.due = parts.count > 2 && !parts[2].isEmpty && parts[2] != "-" ? parts[2] : nil
            }
        }
        guard let id = meeting.add(card) else { return sayCard }
        if kind == .ask {
            lastAskShown = Date()
            turnsSinceAsk = 0
            meeting.bank.append(BankQuestion(topic: "Live", text: text, surfacedAt: Date(), live: true))
        }
        if kind == .say || kind == .answer { onUrgent?() }
        return kind == .say ? id : sayCard
    }

    private func buildPrompt(for reason: Reason) -> String {
        let m = meeting
        let name = prefs.name.isEmpty ? "the user" : prefs.name
        var parts: [String] = []
        var head = "Type: \(m.mode.label). \(m.mode.liveGuidance)\nTitle: \(m.title)\n"
        if !m.attendees.isEmpty { head += "Attendees: \(m.attendees.joined(separator: ", "))\n" }
        head += "The user is \(name)." + (prefs.about.isEmpty ? "" : " \(prefs.about)") + "\n"
        if !m.goal.isEmpty { head += "Their goal: \(m.goal)\n" }
        head += "Elapsed: \(m.elapsed)"
        parts.append("<meeting>\n\(head)\n</meeting>")
        if !m.context.isEmpty { parts.append("<context>\n\(m.context.prefix(8000))\n</context>") }
        if !memory.isEmpty { parts.append("<earlier_in_meeting>\n\(memory)\n</earlier_in_meeting>") }
        parts.append("<transcript>\n\(m.transcript(from: memoryThrough, limit: 45))\n</transcript>")
        let open = m.openQuestions.suffix(6).map { "- \($0.text)" }
        let actions = m.cards.filter { $0.kind == .action && !$0.dismissed }.suffix(6).map { "- \($0.owner ?? "?"): \($0.text)" }
        if !open.isEmpty || !actions.isEmpty {
            parts.append("<captured>\nOpen questions:\n\(open.joined(separator: "\n"))\nAction items:\n\(actions.joined(separator: "\n"))\n</captured>")
        }
        if !m.frames.isEmpty { parts.append("<answer_map>\n\(m.mapSummary)\n</answer_map>") }
        let shown = m.cards.filter(\.kind.isSuggestion).suffix(12).map { "- \($0.kind.tag): \($0.text.replacingOccurrences(of: "\n", with: " "))" }
        if !shown.isEmpty { parts.append("<already_suggested>\n\(shown.joined(separator: "\n"))\n</already_suggested>") }
        let prepared = m.bank.filter { !$0.asked && !$0.live }.prefix(14).map { "- \($0.text)" }
        if !prepared.isEmpty { parts.append("<prepared_questions>\n\(prepared.joined(separator: "\n"))\n</prepared_questions>") }

        let task: String
        switch reason {
        case .asked(let question):
            task = m.mode == .interviewed
                ? "The interviewer just asked \(name): \"\(question)\". Give SAY lines: the headline answer first, then the best-fitting story or example from the context (what \(name) did, the result with a number). Speakable, first person."
                : "\(name) was just asked: \"\(question)\". Start with SAY: the answer \(name) can give, drawn from the transcript and context. If it depends on facts you don't have, SAY how to answer honestly (what to commit to and by when), then at most one ASK to clarify."
        case .nudge:
            task = "\(name) pressed Help me now. Give the single most useful SAY or ASK for this exact moment, then at most one backup."
        case .vague(let text):
            task = "This was vague: \"\(text)\". Give one ASK that pins down the missing owner, number, date or scope, phrased so it doesn't sound confrontational."
        case .signal(let label, let text):
            task = "Possible signal (\(label.lowercased())) in: \"\(text)\". Give one gentle, open ASK that invites them to say more about it. Never name the signal or diagnose."
        case .periodic:
            task = "Suggest the 1 or 2 best ASK questions for where the conversation is right now, tied to the goal, not already suggested or prepared. Add a FLAG only for a real contradiction or something important nobody has addressed. Reply NONE if the conversation doesn't need it."
        case .gap(let frame, let step, let weak, let probe, let said):
            task = """
            The answer is weak on \(frame) › \(step): \(weak.lowercased()). \(said.isEmpty ? "They haven't covered it yet." : "What they've said on it: \"\(said.suffix(600))\"")
            Give one ASK that gets at this gap. Direction: \(probe) Use one of the moves, never name the gap, never hint at the answer you want.
            """
        case .userQuestion(let question):
            task = "\(name) privately asks you: \"\(question)\". Answer in 1 to 4 ANSWER lines, grounded in the transcript and context. If the transcript doesn't contain the answer, say so."
        }
        parts.append("<task>\n\(task)\n</task>")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Background work

    private var flaggedLateDesign = false

    private func tick() {
        guard meeting.phase == .listening else { return }
        compactMemory()
        followUpGap()
        // From the Combined Framework: by minute 20 of a product case the answer should be in design depth.
        if !flaggedLateDesign, let frame = meeting.frames.first(where: { $0.id == "product-case" }),
           let first = frame.nodes.compactMap({ meeting.map["\(frame.id).\($0.key)"]?.evidence.isEmpty == false ? meeting.map["\(frame.id).\($0.key)"]?.updated : nil }).min(),
           let design = frame.nodes.first(where: { $0.key == "design" }),
           meeting.state(frame, design).status == .missing,
           Date().timeIntervalSince(first) > 18 * 60 {
            flaggedLateDesign = true
            meeting.add(Card(kind: .flag, text: "18 minutes in and no design depth yet: screens, states, what the user sees.", source: "Product case · timing"))
        }
        if prefs.autoSuggest, turnsSinceAsk >= 5, Date().timeIntervalSince(lastAskShown) > 80, Date().timeIntervalSince(lastGenerated) > 40,
           !pending.contains(where: { if case .periodic = $0 { return true }; return false }) {
            turnsSinceAsk = 0
            enqueue(.periodic)
        }
    }

    /// Keeps the last ~25 lines verbatim for prompts and folds older ones into a short memory.
    private func compactMemory() {
        let count = meeting.lines.count
        guard !memoryBusy, count - memoryThrough > 50 else { return }
        memoryBusy = true
        let upTo = count - 25
        let chunk = meeting.transcript(from: memoryThrough, limit: upTo - memoryThrough)
        let prompt = "<memory>\n\(memory.isEmpty ? "(empty)" : memory)\n</memory>\n<new_lines>\n\(chunk)\n</new_lines>"
        Task {
            let updated = try? await claude.stream(model: Brain.utilityModel, system: Prompts.memory, prompt: prompt)
            await MainActor.run {
                if let updated, !updated.isEmpty {
                    self.memory = updated.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.memoryThrough = upTo
                }
                self.memoryBusy = false
            }
        }
    }

    /// Writes the question bank if prep didn't already. Runs once at the start.
    func prepareBank() {
        guard meeting.bank.isEmpty else { return }
        let m = meeting
        m.bankState = "Preparing questions…"
        Task {
            await Brain.writeBank(mode: m.mode, title: m.title, goal: m.goal, context: m.context, attendees: m.attendees,
                                  topics: m.frames.flatMap { $0.nodes.map(\.label) }) { q in
                m.bank.append(q)
            }
            await MainActor.run { m.bankState = nil }
        }
    }

    /// Claude writes the question bank from the mode and the prep context. `onQuestion` runs on the main thread.
    static func writeBank(mode: Playbook.Mode, title: String, goal: String, context: String, attendees: [String], topics: [String] = [],
                          onQuestion: @escaping (BankQuestion) -> Void) async {
        let prefs = Prefs.shared
        let prompt = """
        Meeting type: \(mode.label)
        Title: \(title)
        \(attendees.isEmpty ? "" : "Attendees: \(attendees.joined(separator: ", "))\n")The user: \(prefs.name). \(prefs.about)
        Goal: \(goal.isEmpty ? "(not given)" : goal)
        What to prepare: \(mode.bankBrief)
        \(topics.isEmpty ? "" : "Use these as the topics, a few questions each, in this order: \(topics.joined(separator: ", ")).")
        <context>
        \(context.isEmpty ? "(none given)" : String(context.prefix(12000)))
        </context>
        """
        do {
            try await Claude.shared.lines(model: prefs.model.rawValue, system: Prompts.bank, prompt: prompt) { line in
                guard let q = Brain.parseBank(line) else { return }
                DispatchQueue.main.async { onQuestion(q) }
            }
        } catch {
            Log.write("bank: \(error.localizedDescription)")
        }
    }

    static func parseBank(_ line: String) -> BankQuestion? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.uppercased().hasPrefix("Q:") else { return nil }
        text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var topic = "General"
        if let bar = text.firstIndex(of: "|") {
            topic = text[..<bar].trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            text = text[text.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            topic = String(text[text.index(after: text.startIndex)..<close])
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard text.count > 8 else { return nil }
        return BankQuestion(topic: topic.isEmpty ? "General" : topic, text: text.prefix(1).uppercased() + text.dropFirst())
    }

    /// The write-up after the meeting, streamed into `meeting.recap`.
    func writeRecap() async {
        let m = meeting
        let (transcript, board) = await MainActor.run { () -> (String, String) in
            var t = m.transcript()
            if t.count > 150_000 { t = "(earlier part summarized)\n\(self.memory)\n…\n" + String(t.suffix(140_000)) }
            let board = m.cards.filter { !$0.kind.isSuggestion && !$0.dismissed }.map {
                "- \($0.kind.label)\($0.owner.map { " (\($0))" } ?? "")\($0.due.map { " due \($0)" } ?? ""): \($0.text)\($0.resolved != nil ? " [answered]" : "")"
            }.joined(separator: "\n")
            return (t, board)
        }
        guard !transcript.isEmpty else { return }
        let model = prefs.model == .haiku ? SuggestModel.sonnet.rawValue : prefs.model.rawValue
        let prompt = """
        Meeting: \(m.title) (\(m.mode.label)), \(m.elapsed) long.
        \(m.attendees.isEmpty ? "" : "Attendees: \(m.attendees.joined(separator: ", "))\n")The user: \(prefs.name). \(prefs.about)
        Goal: \(m.goal.isEmpty ? "(not given)" : m.goal)
        <context>
        \(m.context.prefix(6000))
        </context>
        <captured_live>
        \(board)
        </captured_live>
        <answer_map graded_live_by_step>
        \(m.frames.isEmpty ? "(none)" : m.mapSummary)
        </answer_map>
        <transcript>
        \(transcript)
        </transcript>
        First line exactly: "Title: " and a 3 to 8 word name for what this meeting was actually about, from the \
        transcript (not the current title, which may be a placeholder).
        Then write the notes with exactly these headings:
        \(m.mode.recapSections)
        """
        var text = ""
        do {
            try await claude.stream(model: model, system: Prompts.recap, prompt: prompt) { fragment in
                text += fragment
                let snapshot = Brain.plain(Brain.withoutTitle(text).body)
                DispatchQueue.main.async { m.recap = snapshot }
            }
            if let title = Brain.withoutTitle(text).title {
                await MainActor.run {
                    if !m.userTitled { m.title = title }
                    Log.write("recap title: \(title)\(m.userTitled ? " (kept the typed title)" : "")")
                }
            }
        } catch {
            Log.write("recap: \(error.localizedDescription)")
            await MainActor.run { m.notice = "Couldn't write the recap: \(error.localizedDescription)" }
        }
    }

    // MARK: Helpers

    /// Splits a leading "Title: …" line off a recap.
    static func withoutTitle(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.drop { $0 == "\n" || $0 == " " }
        guard trimmed.hasPrefix("Title:") else { return (nil, text) }
        guard let end = trimmed.firstIndex(of: "\n") else { return (nil, "") } // still streaming the title line
        let title = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<end]
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*.")))
        return (title.isEmpty ? nil : title, String(trimmed[trimmed.index(after: end)...]))
    }

    /// House style: no em dashes, whatever the model did.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: " – ", with: ", ")
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A due date as said: "Friday", "EOD", "next week", "Oct 12".
    static func due(in text: String) -> String? {
        let pattern = #"\b(today|tonight|tomorrow|eod|eow|end of (the )?(day|week|month|quarter|sprint)|this week|next week|next month|(monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(st|nd|rd|th)?)\b"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let found = String(text[range])
        return found.count <= 4 ? found.uppercased() : found.prefix(1).uppercased() + found.dropFirst()
    }
}
