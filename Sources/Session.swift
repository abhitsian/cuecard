import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PDFKit

/// The app's state: the prep for the next meeting, the running meeting, and the audio behind it.
final class Session: ObservableObject {
    static let shared = Session()

    enum Tab: String, CaseIterable { case live = "Live", map = "Map", notes = "Notes", questions = "Questions", transcript = "Transcript", recap = "Recap" }

    /// What the user sets up before a meeting.
    struct Prep {
        var mode: Playbook.Mode = Prefs.shared.lastMode
        var title = ""
        var goal = ""
        var context = Prefs.shared.savedContext(for: Prefs.shared.lastMode)
        var attendees: [String] = []
        var bank: [BankQuestion] = []
        var preparing = false
        /// Looking in the user's sources, and what came of the last look.
        var fetchingNotion = false
        var notionNote: String?
        /// Answer structures to grade live (frame ids).
        var frames: [String] = Frame.defaults(for: Prefs.shared.lastMode)
    }

    /// Every frame on disk, loaded once and refreshed when prep opens.
    @Published var library: [Frame] = Frame.all()

    @Published var prep = Prep()
    @Published var meeting: Meeting?
    @Published var tab: Tab = .live
    @Published var mini = false
    @Published var status: String?
    /// An app that started using the microphone while Cuecard wasn't listening.
    @Published var detected: String?
    @Published var recent: [URL] = Archive.recent()

    private(set) var brain: Brain?
    private var mic: MicSource?
    private var tap: SystemAudioTap?
    private var you: Transcriber?
    private var them: Transcriber?
    private var clock: Timer?
    private var lastSave = Date()
    private var startedWithApp: String?
    /// Meetings whose recap is still being written. It happens in the background, so the next meeting can start.
    @Published private(set) var writingUp = 0
    private var micFreeSince: Date?
    /// The stall check: buffer and result counts at the last look, and when each side was last restarted.
    private var lastCheck = Date()
    private var lastHealthLog = Date()
    private var seen: [Speaker: (buffers: Int, results: Int, speech: Int)] = [:]
    private var lastRestart: [Speaker: Date] = [:]

    /// Asks the app to show the panel (a SAY card arrived, or the user started).
    var onShowPanel: (() -> Void)?
    var onChange: (() -> Void)?

    // MARK: Prep

    func setMode(_ mode: Playbook.Mode) {
        guard prep.mode != mode else { return }
        Prefs.shared.saveContext(prep.context, for: prep.mode)
        prep.mode = mode
        prep.context = Prefs.shared.savedContext(for: mode)
        prep.bank = []
        prep.frames = Frame.defaults(for: mode)
    }

    private var fullContext: String {
        prep.context
    }

    /// Writes the question bank now, so the user can look it over before the meeting.
    func prepareQuestions() {
        guard !prep.preparing else { return }
        prep.bank = []
        prep.preparing = true
        let p = prep
        Task {
            let topics = p.frames.compactMap { id in self.library.first { $0.id == id } }.flatMap { $0.nodes.map(\.label) }
            await Brain.writeBank(mode: p.mode, title: p.title.isEmpty ? "Meeting" : p.title, goal: p.goal, context: fullContext,
                                  attendees: p.attendees, topics: topics) { [weak self] q in self?.prep.bank.append(q) }
            await MainActor.run { self.prep.preparing = false }
        }
    }

    /// Adds what the user's sources know to the context box, from what the user typed (title, goal, notes). There is no
    /// transcript yet, so this needs something typed; during the meeting the lookup runs on what is said.
    func pullFromNotion() {
        guard !prep.fetchingNotion else { return }
        guard !(prep.title.isEmpty && prep.goal.isEmpty && prep.context.isEmpty) else {
            prep.notionNote = "Type a title, goal or notes first. During the meeting Cuecard looks up your sources from what is said."
            return
        }
        prep.fetchingNotion = true
        prep.notionNote = nil
        let p = prep
        Task { @MainActor in
            let found = await NotionContext.fetch(transcript: "", title: p.title, goal: p.goal, notes: p.context, mode: p.mode)
            self.prep.fetchingNotion = false
            guard let brief = found.brief else { self.prep.notionNote = "Nothing relevant found in your sources."; return }
            self.prep.context = self.prep.context.replacingOccurrences(of: NotionContext.marker, with: "[Sources, earlier]")
            self.prep.context += (self.prep.context.isEmpty ? "" : "\n\n") + brief
            self.prep.notionNote = "Added from your sources. Prepare writes questions from it."
        }
    }

    /// During the meeting, once enough has been said (about 3 minutes in) and again around 12 minutes: work out
    /// what the meeting is about from the transcript, name it if the user didn't, and bring in Notion context.
    /// The brief replaces the previous one in the meeting's context (every suggestion reads it), and a few
    /// questions from it go into the bank.
    private func notionCheck(_ m: Meeting) {
        guard Prefs.shared.notionContext, !m.notionBusy, m.phase == .listening, m.notionLookups < 2 else { return }
        let elapsed = Date().timeIntervalSince(m.started)
        let words = m.lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let due = m.notionLookups == 0 ? (elapsed > 150 && words > 120) : elapsed > 720
        guard due else { return }
        m.notionBusy = true
        m.notionLookups += 1
        let round = m.notionLookups
        let transcript = m.transcript(limit: 80)
        Log.write("notion: lookup \(round) at \(m.elapsed), \(words) words said")
        Task { @MainActor in
            let found = await NotionContext.fetch(transcript: transcript, title: m.userTitled ? m.title : "", goal: m.goal,
                                                  mode: m.mode, asOf: m.started)
            m.notionBusy = false
            if let topic = found.topic, !m.userTitled {
                Log.write("title: \(topic)")
                m.title = topic
            }
            guard let brief = found.brief, m.live else { return }
            if let old = m.context.range(of: NotionContext.marker) { m.context = String(m.context[..<old.lowerBound]) }
            m.context = m.context.trimmingCharacters(in: .whitespacesAndNewlines)
            m.context += (m.context.isEmpty ? "" : "\n\n") + brief
            m.notice = "Pulled context from your sources. Questions from it are under Questions."
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if m.notice?.hasPrefix("Pulled context from your sources") == true { m.notice = nil } }
            var added = 0
            await Brain.writeBank(mode: m.mode, title: m.title, goal: m.goal, context: brief, attendees: m.attendees) { q in
                guard added < (round == 1 ? 5 : 3), !m.bank.contains(where: { $0.text == q.text }) else { return }
                var q = q
                q.topic = "Your sources · " + q.topic
                m.bank.append(q)
                added += 1
            }
        }
    }

    /// Adds a document (PDF, Word, text) to the context box.
    func addFile() {
        for (name, text) in Session.pickFiles() {
            prep.context += (prep.context.isEmpty ? "" : "\n\n") + "[\(name)]\n\(text)"
        }
    }

    /// Files the user picks (PDF, Word, text, Markdown, HTML), as (file name, text up to 20k characters).
    static func pickFiles() -> [(String, String)] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .plainText, .rtf, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "docx") ?? .data, .html]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { url in
            var text: String?
            if url.pathExtension.lowercased() == "pdf" {
                text = PDFDocument(url: url)?.string
            } else if let plain = try? String(contentsOf: url, encoding: .utf8), url.pathExtension != "docx" {
                text = plain
            } else {
                text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
            }
            guard let text, !text.isEmpty else { return nil }
            return (url.lastPathComponent, String(text.prefix(20000)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Context the user adds during the meeting (a pasted note, numbers, a doc): it joins what every suggestion
    /// reads, and a few questions are written from it into the bank.
    func addContext(_ text: String, label: String = "Added during the meeting") {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = meeting, !body.isEmpty else { return }
        m.context += (m.context.isEmpty ? "" : "\n\n") + "[\(label)]\n\(String(body.prefix(20000)))"
        m.notice = "Added to this meeting's context. Suggestions use it from now on."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if m.notice?.hasPrefix("Added to this meeting's context") == true { m.notice = nil } }
        Log.write("context: added \(body.count) chars (\(label))")
        Task { @MainActor in
            var added = 0
            await Brain.writeBank(mode: m.mode, title: m.title, goal: m.goal, context: body, attendees: m.attendees) { q in
                guard added < 3, !m.bank.contains(where: { $0.text == q.text }) else { return }
                var q = q
                q.topic = "Your context · " + q.topic
                m.bank.append(q)
                added += 1
            }
        }
    }

    func addContextFile() {
        for (name, text) in Session.pickFiles() { addContext(text, label: name) }
    }

    // MARK: Listening

    func toggle() { meeting?.live == true ? stop() : start() }

    func start() {
        guard meeting?.live != true else { return }
        // The last meeting may still be writing up; it finishes on its own. Start from a clean prep.
        if meeting != nil { reset() }
        let prefs = Prefs.shared
        prefs.lastMode = prep.mode
        prefs.saveContext(prep.context, for: prep.mode)
        let title = prep.title.isEmpty ? (detected.map { "\($0) call" } ?? "Meeting") : prep.title
        let m = Meeting(title: title, mode: prep.mode, goal: prep.goal, context: fullContext, attendees: prep.attendees)
        m.userTitled = !prep.title.isEmpty
        m.bank = prep.bank
        m.frames = prep.frames.compactMap { id in library.first { $0.id == id } }
        m.hearsThem = prefs.systemAudio
        meeting = m
        tab = .live
        mini = false
        startedWithApp = detected
        detected = nil
        let brain = Brain(meeting: m)
        brain.onUrgent = { [weak self] in
            if Prefs.shared.popOnAsk { self?.onShowPanel?() }
            NSSound(named: "Tink")?.play()
        }
        self.brain = brain
        onShowPanel?()
        onChange?()
        Log.write("session: start mode=\(m.mode.rawValue) jev=\(brain.usesJev) model=\(prefs.model.short)")

        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                m.notice = "Cuecard needs the microphone. Allow it in System Settings › Privacy › Microphone."
                return
            }
            let locale = await Transcriber.locale()
            guard await Transcriber.prepare(locale, status: { s in DispatchQueue.main.async { self.status = s } }) else {
                m.notice = "Couldn't get the speech model for \(locale.identifier)."
                self.status = nil
                return
            }
            self.status = nil
            guard self.meeting === m, m.live else { return }
            let you = Transcriber(speaker: .you), them = Transcriber(speaker: .them)
            you.onEvent = { [weak self] in self?.handle($0, from: .you) }
            them.onEvent = { [weak self] in self?.handle($0, from: .them) }
            do {
                try await you.start(locale: locale, vocabulary: self.vocabulary)
                if prefs.systemAudio { try await them.start(locale: locale, vocabulary: self.vocabulary) }
            } catch {
                m.notice = "Speech recognition didn't start: \(error.localizedDescription)"
                return
            }
            self.you = you
            self.them = them
            let mic = MicSource()
            mic.onBuffer = { you.append($0) }
            do { try mic.start() } catch { m.notice = error.localizedDescription }
            self.mic = mic
            if prefs.systemAudio {
                let tap = SystemAudioTap()
                tap.onBuffer = { them.append($0) }
                do { try tap.start(); self.tap = tap } catch {
                    Log.write("tap: \(error.localizedDescription)")
                    m.notice = "Can't hear the other side: \(error.localizedDescription)"
                    m.hearsThem = false
                }
            }
            brain.start()
        }
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private var vocabulary: [String] {
        var words = Prefs.shared.vocabularyList
        if !Prefs.shared.name.isEmpty { words.append(Prefs.shared.name) }
        words += (meeting?.attendees ?? []).flatMap { $0.components(separatedBy: " ") }.filter { $0.count > 2 }
        return Array(Set(words)).sorted()
    }

    private func handle(_ event: Transcriber.Event, from speaker: Speaker) {
        guard let m = meeting, m.live else { return }
        switch event {
        case .partial(let text):
            m.partial[speaker] = text.isEmpty ? nil : text
        case .final(let text):
            // Without headphones the mic hears the other side too. Keep their copy, drop the echo.
            let words = Meeting.words(text)
            let window = m.lines.suffix(8).filter { Date().timeIntervalSince($0.at) < 6 }
            if speaker == .you, window.contains(where: { $0.speaker == .them && Meeting.overlap(Meeting.words($0.text), words) > 0.6 }) {
                m.partial[.you] = nil
                return
            }
            if speaker == .them, let echo = window.last(where: { $0.speaker == .you && Meeting.overlap(Meeting.words($0.text), words) > 0.6 }) {
                m.lines.removeAll { $0.id == echo.id }
            }
            let line = Line(speaker: speaker, text: text, at: Date())
            m.add(line)
            if m.phase == .listening { brain?.heard(line) }
        }
    }

    private func tick() {
        guard let m = meeting else { return }
        if m.live {
            m.youLevel = you?.level ?? 0
            m.themLevel = them?.level ?? 0
            you?.decay()
            them?.decay()
            let running = Date().timeIntervalSince(m.started)
            let silent = m.hearsThem && running > 25 && !(them?.heardAnything ?? true) && (you?.heardAnything ?? false)
            if m.themSilent != silent { m.themSilent = silent }
            if Date().timeIntervalSince(lastSave) > 30 { lastSave = Date(); Archive.write(m) }
            checkHealth(m)
            notionCheck(m)
            autoStopCheck(m)
        }
        onChange?()
    }

    /// Every 20 s: a side with no new audio gets its audio source restarted; a side that is hearing sound but has
    /// returned no text for 45 s gets its recognizer restarted (both recognizers share the system speech
    /// service, which can stall). A health line goes to the log every minute.
    private func checkHealth(_ m: Meeting) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= 20 else { return }
        lastCheck = now
        var report: [String] = []
        for (speaker, t) in [(Speaker.you, you), (Speaker.them, them)] {
            guard let t else { continue }
            let before = seen[speaker] ?? (0, 0, 0)
            let newBuffers = t.buffers - before.buffers, newResults = t.results - before.results
            let talking = newBuffers > 0 && Double(t.speechBuffers - before.speech) / Double(newBuffers) >= 0.25
            seen[speaker] = (t.buffers, t.results, t.speechBuffers)
            report.append("\(speaker.rawValue) buffers+\(newBuffers) results+\(newResults) loud \(Int(now.timeIntervalSince(t.lastLoud)))s ago text \(Int(now.timeIntervalSince(t.lastResult)))s ago")
            guard m.phase == .listening, speaker == .you || m.hearsThem,
                  now.timeIntervalSince(lastRestart[speaker] ?? .distantPast) > 60 else { continue }
            if newBuffers == 0, before.buffers > 0 {
                Log.write("health \(speaker.rawValue): no audio for 20s, restarting the source")
                lastRestart[speaker] = now
                if speaker == .you { mic?.restart() } else if let tap { tap.stop(); try? tap.start() }
                m.notice = "Lost \(speaker == .you ? "your microphone" : "the other side's audio") for a moment; reconnected."
            } else if talking, now.timeIntervalSince(t.lastResult) > 45 {
                Log.write("health \(speaker.rawValue): sound but no text for \(Int(now.timeIntervalSince(t.lastResult)))s, restarting speech")
                lastRestart[speaker] = now
                Task { await t.restart() }
                m.notice = "Speech for \(speaker == .you ? "you" : "the other side") stalled; restarted it."
            }
        }
        if now.timeIntervalSince(lastHealthLog) >= 60 {
            lastHealthLog = now
            Log.write("health: " + report.joined(separator: " | "))
        }
    }

    /// When the call app that was on the mic lets go of it for a minute and nobody is talking, wrap up.
    private func autoStopCheck(_ m: Meeting) {
        guard startedWithApp != nil, m.phase == .listening else { return }
        if MeetingDetectorState.shared.current == nil {
            if micFreeSince == nil { micFreeSince = Date() }
            let quiet = m.lines.last.map { Date().timeIntervalSince($0.at) > 45 } ?? true
            if let since = micFreeSince, Date().timeIntervalSince(since) > 60, quiet {
                Log.write("session: call ended, wrapping up")
                stop()
            }
        } else {
            micFreeSince = nil
        }
    }

    func pause() {
        guard let m = meeting else { return }
        if m.phase == .listening { m.phase = .paused } else if m.phase == .paused { m.phase = .listening }
        you?.paused = m.phase == .paused
        them?.paused = m.phase == .paused
        onChange?()
    }

    func stop() {
        guard let m = meeting, m.live else { return }
        m.phase = .wrapping
        m.ended = Date()
        m.partial = [:]
        mic?.stop()
        tap?.stop()
        brain?.stop()
        mic = nil
        tap = nil
        startedWithApp = nil
        micFreeSince = nil
        onChange?()
        let you = self.you, them = self.them, brain = self.brain
        self.you = nil
        self.them = nil
        clock?.invalidate()
        clock = nil
        writingUp += 1
        // Everything below uses this meeting's own objects, so a new meeting can start while it runs.
        Task { @MainActor in
            await you?.finish()
            await them?.finish()
            Archive.write(m)
            if self.meeting === m {
                self.tab = .recap
                self.mini = false
            }
            await brain?.writeRecap()
            m.phase = .done
            Archive.write(m)
            if let file = m.file {
                DispatchQueue.global(qos: .utility).async { Pages.write(note: file); Pages.rebuild() }
                AfterWriteUp.run(file.path)
            }
            self.writingUp -= 1
            if self.meeting?.live != true, self.writingUp == 0 { Claude.shared.coolDown() }
            self.recent = Archive.recent()
            if self.meeting !== m {
                let note = "Saved the recap for \(m.title)"
                self.status = note
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.status == note { self.status = nil } }
            }
            self.onChange?()
            Log.write("session: saved \(m.file?.lastPathComponent ?? "-")")
        }
    }

    /// Back to the prep screen for the next meeting.
    func reset() {
        if meeting?.live == true { return }
        meeting = nil
        brain = nil
        mini = false
        prep = Prep()
        library = Frame.all()
        tab = .live
        onChange?()
    }

    func nudge() {
        guard let m = meeting, m.live else { return }
        brain?.nudge()
        tab = .live
        onShowPanel?()
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, meeting != nil else { return }
        brain?.ask(q)
        tab = .live
    }
}

/// Shared view of the meeting detector, so the session can tell when the call app lets go of the mic.
final class MeetingDetectorState {
    static let shared = MeetingDetector()
}
