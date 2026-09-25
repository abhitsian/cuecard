import SwiftUI
import AppKit

struct PanelView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        VStack(spacing: 0) {
            if let meeting = session.meeting {
                MeetingScreen(meeting: meeting)
            } else {
                Header(meeting: nil)
                Divider().overlay(Theme.hairline)
                PrepScreen()
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, minHeight: session.mini ? 0 : 420, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Header

struct Header: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    let meeting: Meeting?

    var body: some View {
        HStack(spacing: 10) {
            if let m = meeting {
                PulsingDot(color: dotColor(m), pulsing: m.phase == .listening)
                    .id(m.phase == .listening)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 5) {
                            Text(m.elapsed).monospacedDigit()
                            Text("·")
                            Text(phaseLabel(m))
                            if m.thinking { ThinkingDots() }
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 6)
                if m.live || session.mini {
                    IconButton(symbol: session.mini ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                               help: session.mini ? "Show everything" : "Compact") { session.mini.toggle() }
                }
                if m.live {
                    HStack(spacing: 8) {
                        LevelMeter(level: m.youLevel, color: Theme.youColor, label: "you")
                        if m.hearsThem { LevelMeter(level: m.themLevel, color: Theme.themColor, label: "them") }
                    }
                    IconButton(symbol: m.phase == .paused ? "play.fill" : "pause.fill", help: m.phase == .paused ? "Resume" : "Pause") { session.pause() }
                    IconButton(symbol: "stop.fill", help: "Stop and write up (⌃⌥A)", tint: Color(red: 1, green: 0.5, blue: 0.45)) { session.stop() }
                } else {
                    if m.phase == .done, let file = m.file {
                        Button("Page") { NSWorkspace.shared.open(Pages.page(for: file)) }.buttonStyle(SmallButtonStyle())
                            .help("Open this meeting's page")
                    }
                    // Available while the recap is still being written: it finishes in the background.
                    Button("New") { session.reset() }.buttonStyle(SmallButtonStyle())
                }
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                Text("Cuecard").font(.system(size: 13, weight: .semibold))
                Text(prefs.useJev && prefs.jevKey != nil ? "Jev + \(prefs.model.short)" : prefs.model.short)
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
            }
            IconButton(symbol: "xmark", help: "Hide (⌃⌥S)", size: 10) { NSApp.sendAction(#selector(AppDelegate.hidePanel), to: nil, from: nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func dotColor(_ m: Meeting) -> Color {
        switch m.phase {
        case .listening: return Color(red: 1, green: 0.36, blue: 0.33)
        case .paused: return Theme.accent
        case .wrapping: return Theme.accent
        case .done: return Color(red: 0.4, green: 0.85, blue: 0.56)
        }
    }

    private func phaseLabel(_ m: Meeting) -> String {
        switch m.phase {
        case .listening: return session.status ?? m.mode.label
        case .paused: return "Paused"
        case .wrapping: return "Writing up…"
        case .done: return "Saved"
        }
    }
}

struct ThinkingDots: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in Circle().fill(Theme.accent.opacity(phase == i ? 1 : 0.3)).frame(width: 3.5, height: 3.5) }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

struct SmallButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Theme.accent : Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: Meeting

struct MeetingScreen: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            Header(meeting: meeting)
            if let notice = meeting.notice {
                Banner(text: notice, symbol: "exclamationmark.triangle.fill", color: Theme.accent) { meeting.notice = nil }
            }
            if meeting.themSilent {
                Banner(text: "Not hearing the other side yet. Allow Cuecard under System Audio Recording.", symbol: "speaker.slash.fill",
                       color: Color(red: 1, green: 0.6, blue: 0.5), action: ("Open", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                })) { meeting.themSilent = false }
            }
            if session.mini {
                MiniView(meeting: meeting)
            } else {
                Tabs(meeting: meeting)
                Divider().overlay(Theme.hairline)
                Group {
                    switch session.tab {
                    case .live: LiveTab(meeting: meeting)
                    case .map: MapTab(meeting: meeting)
                    case .notes: NotesTab(meeting: meeting)
                    case .questions: QuestionsTab(meeting: meeting)
                    case .transcript: TranscriptTab(meeting: meeting)
                    case .recap: RecapTab(meeting: meeting)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if meeting.phase != .wrapping { AskBar(meeting: meeting) }
            }
        }
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let color: Color
    var action: (String, () -> Void)? = nil
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.0, action: action.1).buttonStyle(SmallButtonStyle()) }
            IconButton(symbol: "xmark", size: 9, action: close)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(color.opacity(0.08))
    }
}

struct Tabs: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                Button { session.tab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if let n = count(tab), n > 0 {
                            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                        }
                    }
                    .font(.system(size: 12, weight: session.tab == tab ? .semibold : .medium))
                    .foregroundStyle(session.tab == tab ? .white : Theme.faint)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(session.tab == tab ? Color.white.opacity(0.1) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private var tabs: [Session.Tab] {
        let map: [Session.Tab] = meeting.frames.isEmpty ? [] : [.map]
        return meeting.phase == .listening || meeting.phase == .paused
            ? [.live] + map + [.notes, .questions, .transcript]
            : [.recap] + map + [.notes, .questions, .transcript]
    }

    private func count(_ tab: Session.Tab) -> Int? {
        switch tab {
        case .notes: return meeting.cards.filter { !$0.kind.isSuggestion && !$0.dismissed }.count
        case .questions: return meeting.bank.filter { !$0.live }.count
        case .map: return meeting.frames.flatMap { f in f.nodes.map { meeting.state(f, $0).status } }.filter { $0 == .weak }.count
        default: return nil
        }
    }
}

// MARK: Live

struct LiveTab: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting
    @State private var showEarlier = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let hero = meeting.cards.last { ($0.kind == .say || $0.kind == .answer) && !$0.dismissed && now.timeIntervalSince($0.at) < 90 }
            let asks = meeting.cards.filter { $0.kind.isSuggestion && !$0.dismissed && $0.id != hero?.id }.reversed()
            // A question is live until it's asked, dismissed, or three minutes old.
            let live = asks.filter { !$0.done && now.timeIntervalSince($0.at) < 180 }.prefix(3)
            let earlier = asks.filter { card in !live.contains { $0.id == card.id } }
            let signals = meeting.cards.filter { $0.kind == .signal && !$0.dismissed }.reversed()
            let captured = meeting.cards.filter { !$0.kind.isSuggestion && $0.kind != .signal && !$0.dismissed }.reversed()

            Scroll {
                VStack(alignment: .leading, spacing: 14) {
                    Captions(meeting: meeting)

                    LiveSection(title: "Ask now", count: live.count + (hero == nil ? 0 : 1), color: CardKind.ask.color) {
                        if let hero { HeroCard(card: hero, meeting: meeting) }
                        ForEach(Array(live)) { CardRow(card: $0, meeting: meeting) }
                        if hero == nil && live.isEmpty {
                            Placeholder(text: meeting.bankState ?? "Questions appear when an answer is thin or you're asked something. ⌃⌥N asks now.")
                        }
                        if !earlier.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.2)) { showEarlier.toggle() } } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showEarlier ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                                    Text("Earlier (\(earlier.count))")
                                }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                            }
                            .buttonStyle(.plain)
                            if showEarlier {
                                ForEach(Array(earlier.prefix(12))) { card in
                                    CaptureRow(card: card, meeting: meeting).opacity(0.75)
                                }
                            }
                        }
                    }

                    LiveSection(title: "Watch", count: signals.count, color: CardKind.signal.color) {
                        ForEach(Array(signals.prefix(3))) { WatchRow(card: $0, meeting: meeting) }
                        if signals.isEmpty { Placeholder(text: "Signals show up here: hesitation, dodged answers, missing specifics.") }
                    }

                    LiveSection(title: "Captured", count: captured.count, color: CardKind.action.color,
                            more: captured.count > 5 ? ("All in Notes", { session.tab = .notes }) : nil) {
                        ForEach(Array(captured.prefix(5))) { CaptureRow(card: $0, meeting: meeting) }
                        if captured.isEmpty { Placeholder(text: "Action items, decisions, risks and open questions land here.") }
                    }
                }
                .padding(12)
            }
        }
    }
}

/// A fixed section of the Live tab: a small coloured header with a count, then its rows.
struct LiveSection<Content: View>: View {
    let title: String
    let count: Int
    let color: Color
    var more: (String, () -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 10)
                Text(title.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.7).foregroundStyle(Theme.dim)
                if count > 0 { Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint).monospacedDigit() }
                Spacer()
                if let more {
                    Button(more.0, action: more.1).buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(color)
                }
            }
            content
        }
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4).padding(.vertical, 2)
    }
}

/// A signal: its name, then the words that triggered it.
struct WatchRow: View {
    let card: Card
    @ObservedObject var meeting: Meeting
    @State private var hover = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(card.source ?? "Signal")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(CardKind.signal.color)
                .frame(width: 92, alignment: .leading).lineLimit(2)
            Text("“\(card.text)”").font(.system(size: 11.5)).italic().foregroundStyle(Theme.dim).lineLimit(2)
            Spacer(minLength: 0)
            if hover {
                IconButton(symbol: "xmark", size: 8) { meeting.update(card.id) { $0.dismissed = true } }
            } else {
                Text(meeting.clock(card.at)).font(.system(size: 10)).foregroundStyle(Theme.faint).monospacedDigit()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.card : .clear))
        .onHover { hover = $0 }
    }
}

struct Captions: View {
    @ObservedObject var meeting: Meeting
    var body: some View {
        let recent = meeting.lines.suffix(2)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(recent)) { line in caption(line.speaker, line.text, live: false) }
            ForEach([Speaker.them, Speaker.you], id: \.self) { speaker in
                if let text = meeting.partial[speaker], !text.isEmpty { caption(speaker, text, live: true) }
            }
            if recent.isEmpty && meeting.partial.isEmpty {
                Text(meeting.phase == .listening ? "Listening…" : " ").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
    }

    private func caption(_ speaker: Speaker, _ text: String, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(speaker == .you ? "You" : "Them")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(speaker == .you ? Theme.youColor : Theme.themColor)
                .frame(width: 32, alignment: .leading)
            Text(text).font(.system(size: 11.5)).foregroundStyle(live ? Theme.faint : Theme.dim).lineLimit(2)
                .italic(live)
        }
    }
}

struct EmptyLive: View {
    @ObservedObject var meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggestions appear as the conversation moves.").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.dim)
            Text("Asked something, and an answer shows up here. Action items, decisions and open questions collect under Notes. ⌃⌥N asks for help at any moment.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            if let state = meeting.bankState {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(state) }.font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 4)
    }
}

struct HeroCard: View {
    let card: Card
    @ObservedObject var meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.symbol).font(.system(size: 11))
                Text(card.kind == .say ? "SAY" : "ANSWER").font(.system(size: 10, weight: .heavy)).tracking(0.8)
                if let source = card.source { Text(source).font(.system(size: 10.5, weight: .medium)).foregroundStyle(card.kind.color.opacity(0.8)) }
                Spacer()
                CopyButton(text: card.text)
                IconButton(symbol: "xmark", size: 9) { meeting.update(card.id) { $0.dismissed = true } }
            }
            .foregroundStyle(card.kind.color)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(card.text.components(separatedBy: "\n").enumerated()), id: \.offset) { i, part in
                    Text(part)
                        .font(.system(size: i == 0 ? 15 : 13.5, weight: i == 0 ? .semibold : .regular))
                        .foregroundStyle(i == 0 ? .white : Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [card.kind.color.opacity(0.2), card.kind.color.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(card.kind.color.opacity(0.45), lineWidth: 1))
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
    }
}

struct CardRow: View {
    let card: Card
    @ObservedObject var meeting: Meeting
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: card.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(card.kind.color)
                .frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.kind == .signal ? (card.source ?? "Signal").uppercased() : card.kind.label.uppercased())
                        .font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(card.kind.color)
                    if card.kind != .signal, let source = card.source { Text(source).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1) }
                    Spacer(minLength: 4)
                    if hover {
                        CopyButton(text: card.text)
                        IconButton(symbol: "xmark", size: 9) { meeting.update(card.id) { $0.dismissed = true } }
                    } else {
                        TimelineView(.periodic(from: .now, by: 5)) { ctx in
                            Text(age(card.at, now: ctx.date)).font(.system(size: 10)).foregroundStyle(Theme.faint)
                        }
                    }
                }
                .frame(height: 16)
                Text(card.kind == .signal ? "“\(card.text)”" : card.text)
                    .font(.system(size: card.kind == .signal ? 12 : 13))
                    .italic(card.kind == .signal)
                    .foregroundStyle(card.done ? Theme.faint : (card.kind == .signal ? Theme.dim : .white))
                    .strikethrough(card.done && card.kind == .ask, color: Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(card.kind.color.opacity(card.done ? 0.2 : 0.7)).frame(width: 2.5).padding(.vertical, 8)
        }
        .onHover { hover = $0 }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A capture (action item, decision…) as one quiet line in the live feed.
struct CaptureRow: View {
    let card: Card
    @ObservedObject var meeting: Meeting
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: card.kind.symbol).font(.system(size: 10)).foregroundStyle(card.kind.color)
            Text(card.kind.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(card.kind.color.opacity(0.9))
            Text(summary).font(.system(size: 11.5)).foregroundStyle(card.refining ? Theme.faint : Theme.dim).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .transition(.opacity)
    }
    private var summary: String {
        var s = card.text
        if let owner = card.owner { s = "\(owner): " + s }
        if let due = card.due { s += " · \(due)" }
        return s
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy", size: 9.5) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        }
    }
}

// MARK: Mini

struct MiniView: View {
    @ObservedObject var meeting: Meeting
    var body: some View {
        let latest = meeting.cards.last { $0.kind.isSuggestion && !$0.dismissed }
        VStack(alignment: .leading, spacing: 6) {
            if let card = latest {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: card.kind.symbol).foregroundStyle(card.kind.color).font(.system(size: 12))
                    Text(card.text.components(separatedBy: "\n").first ?? card.text)
                        .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
            } else {
                Text("Listening. Nothing to suggest yet.").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

// MARK: Notes

struct NotesTab: View {
    @ObservedObject var meeting: Meeting
    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.0) { kind, title in
                    let items = meeting.cards.filter { $0.kind == kind && !$0.dismissed }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: kind.symbol).font(.system(size: 10.5)).foregroundStyle(kind.color)
                                Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                                Text("\(items.count)").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                            }
                            ForEach(items) { NoteRow(card: $0, meeting: meeting) }
                        }
                    }
                }
                if meeting.cards.allSatisfy({ $0.kind.isSuggestion || $0.dismissed }) {
                    Text("Action items, decisions, open questions, next steps, risks and signals collect here as they're said.")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.vertical, 16)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sections: [(CardKind, String)] {
        var list: [(CardKind, String)] = [(.action, "Action items"), (.decision, "Decisions"), (.question, "Open questions"),
                                          (.nextStep, "Next steps"), (.risk, "Risks"), (.signal, "Signals"), (.fact, "Key facts")]
        if [.oneOnOne, .interviewing, .interviewed, .customer].contains(meeting.mode) {
            list.removeAll { $0.0 == .signal }
            list.insert((.signal, "Signals"), at: 0)
        }
        return list
    }
}

struct NoteRow: View {
    let card: Card
    @ObservedObject var meeting: Meeting
    @State private var hover = false
    @State private var open = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if card.kind == .action {
                Button { meeting.update(card.id) { $0.done.toggle() } } label: {
                    Image(systemName: card.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13)).foregroundStyle(card.done ? CardKind.action.color : Theme.faint)
                }.buttonStyle(.plain)
            } else if card.kind == .question {
                Image(systemName: card.resolved != nil ? "checkmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 13)).foregroundStyle(card.resolved != nil ? CardKind.action.color : CardKind.question.color)
            } else {
                Circle().fill(card.kind.color.opacity(0.8)).frame(width: 5, height: 5).padding(.top, 6).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card.kind == .signal ? "“\(card.text)”" : card.text)
                    .font(.system(size: 12.5))
                    .italic(card.kind == .signal)
                    .foregroundStyle(card.done || card.resolved != nil ? Theme.faint : (card.refining ? Theme.dim : .white))
                    .strikethrough(card.done, color: Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    if let owner = card.owner { Pill(text: owner, color: owner == "You" ? Theme.youColor : Theme.themColor) }
                    if let due = card.due { Pill(text: due, color: Theme.accent) }
                    if card.kind == .signal, let label = card.source { Pill(text: label, color: CardKind.signal.color) }
                    Text(meeting.clock(card.at)).font(.system(size: 10)).foregroundStyle(Theme.faint).monospacedDigit()
                    if card.resolved != nil { Text("answered").font(.system(size: 10)).foregroundStyle(CardKind.action.color) }
                }
                if open, let quote = card.resolved ?? card.quote, quote != card.text {
                    Text("Heard: “\(quote)”").font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if hover { IconButton(symbol: "xmark", size: 9) { meeting.update(card.id) { $0.dismissed = true } } }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open.toggle() }
    }
}

// MARK: Questions

struct QuestionsTab: View {
    @ObservedObject var meeting: Meeting
    @State private var draft = ""

    var body: some View {
        let prepared = meeting.bank.filter { !$0.live }
        let asked = prepared.filter(\.asked).count
        Scroll {
            VStack(alignment: .leading, spacing: 12) {
                if !prepared.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Covered \(asked) of \(prepared.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dim)
                            Spacer()
                            Text("Jev ticks them off as you ask").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(CardKind.action.color).frame(width: g.size.width * CGFloat(asked) / CGFloat(max(1, prepared.count)))
                            }
                        }.frame(height: 4)
                    }
                }
                if let state = meeting.bankState {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(state) }.font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                ForEach(topics, id: \.self) { topic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.faint)
                        ForEach(meeting.bank.filter { $0.topic == topic }) { q in
                            QuestionRow(question: q) { toggled in
                                meeting.bank = meeting.bank.map { var x = $0; if x.id == toggled { x.asked.toggle() }; return x }
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    PlainField(placeholder: "Add a question", text: $draft).font(.system(size: 12))
                        .onSubmit {
                            let t = draft.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            meeting.bank.append(BankQuestion(topic: "Mine", text: t))
                            draft = ""
                        }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }
            .padding(12)
        }
    }

    private var topics: [String] {
        var seen: [String] = []
        for q in meeting.bank where !seen.contains(q.topic) { seen.append(q.topic) }
        return seen
    }
}

struct QuestionRow: View {
    let question: BankQuestion
    let toggle: (UUID) -> Void
    var body: some View {
        Button { toggle(question.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: question.asked ? "checkmark.circle.fill" : (question.surfacedAt != nil ? "circle.inset.filled" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(question.asked ? CardKind.action.color : (question.surfacedAt != nil ? CardKind.ask.color : Theme.faint))
                Text(question.text).font(.system(size: 12.5)).foregroundStyle(question.asked ? Theme.faint : .white)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Transcript

struct TranscriptTab: View {
    @ObservedObject var meeting: Meeting
    var body: some View {
        ScrollViewReader { proxy in
            Scroll {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(meeting.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(meeting.clock(line.at)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.faint).frame(width: 34, alignment: .trailing)
                            Text(line.speaker.rawValue).font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(line.speaker == .you ? Theme.youColor : Theme.themColor).frame(width: 34, alignment: .leading)
                            Text(line.text).font(.system(size: 12.5)).foregroundStyle(Theme.dim).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach([Speaker.them, .you], id: \.self) { s in
                        if let t = meeting.partial[s] {
                            Text("\(s.rawValue): \(t)").font(.system(size: 12)).italic().foregroundStyle(Theme.faint).padding(.leading, 42)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: meeting.lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: Recap

struct RecapTab: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting
    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 6) {
                if let recap = meeting.recap, !recap.isEmpty {
                    ForEach(Array(recap.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                        RecapLine(raw: raw)
                    }
                    if meeting.phase == .done {
                        HStack(spacing: 8) {
                            Button("Copy notes") { copy(recap) }.buttonStyle(SmallButtonStyle(prominent: true))
                            if let note = followUpNote(recap) { Button("Copy follow-up") { copy(note) }.buttonStyle(SmallButtonStyle()) }
                            if let file = meeting.file { Button("Open file") { NSWorkspace.shared.open(file) }.buttonStyle(SmallButtonStyle()) }
                        }
                        .padding(.top, 10)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(meeting.lines.isEmpty ? "Nothing was said, so there's nothing to write up." : "Writing up the meeting…")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 20)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func followUpNote(_ recap: String) -> String? {
        let lines = recap.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("#") && ($0.lowercased().contains("note")) }) else { return nil }
        let body = lines[(start + 1)...].prefix { !$0.hasPrefix("#") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

struct RecapLine: View {
    let raw: String
    var body: some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent).padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(Theme.faint)
                Text(markdown(String(line.dropFirst(2)))).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        } else if !line.isEmpty {
            Text(markdown(line)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: Ask

struct AskBar: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting
    @State private var text = ""
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Theme.accent)
            PlainField(placeholder: meeting.live ? "Ask Cuecard about this meeting…" : "Ask about this meeting…", text: $text)
                .font(.system(size: 12.5))
                .onSubmit { session.ask(text); text = "" }
            if meeting.live {
                Button { session.nudge() } label: {
                    HStack(spacing: 4) { Text("Help me now"); Text("⌃⌥N").foregroundStyle(.black.opacity(0.55)) }
                }
                .buttonStyle(SmallButtonStyle(prominent: true))
                .help("Asks for the single best thing to say or ask right now")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.black.opacity(0.2))
    }
}

// MARK: Prep

struct PrepScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    @State private var showAllQuestions = false

    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 14) {
                if let app = session.detected {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(Theme.accent)
                        Text("\(app) is using your mic.").font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Button("Listen along") { session.start() }.buttonStyle(SmallButtonStyle(prominent: true))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("What kind of meeting?", systemImage: "1.circle").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dim)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(Playbook.Mode.allCases) { mode in
                            ModeChip(mode: mode, selected: session.prep.mode == mode) { session.setMode(mode) }
                        }
                    }
                    Text(session.prep.mode.blurb).font(.system(size: 11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("What's it about?", systemImage: "2.circle").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dim)
                    Field(placeholder: "Title", text: $session.prep.title)
                    Field(placeholder: session.prep.mode.goalHint, text: $session.prep.goal)
                    ZStack(alignment: .topLeading) {
                        if session.prep.context.isEmpty {
                            Text(session.prep.mode.contextHint).font(.system(size: 12)).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
                        }
                        if !isRendering { TextEditor(text: $session.prep.context)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 4).padding(.vertical, 4) }
                    }
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    HStack {
                        Button { session.addFile() } label: { Label("Add a file", systemImage: "paperclip") }.buttonStyle(SmallButtonStyle())
                        Button { session.pullFromNotion() } label: {
                            Label(session.prep.fetchingNotion ? "Looking in Notion…" : "From Notion", systemImage: "book.closed")
                        }.buttonStyle(SmallButtonStyle()).disabled(session.prep.fetchingNotion)
                        Spacer()
                        if !session.prep.context.isEmpty {
                            Text("\(session.prep.context.split(separator: " ").count) words").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                        }
                    }
                    if let note = session.prep.notionNote {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(session.prep.mode == .interviewing ? "What are you testing?" : "What should the answers hold up to?", systemImage: "3.circle")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dim)
                    FramePicker()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Questions to draw on", systemImage: "4.circle").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.dim)
                        Spacer()
                        Button(session.prep.preparing ? "Writing…" : (session.prep.bank.isEmpty ? "Prepare" : "Redo")) { session.prepareQuestions() }
                            .buttonStyle(SmallButtonStyle()).disabled(session.prep.preparing)
                    }
                    if session.prep.bank.isEmpty && !session.prep.preparing {
                        Text("Optional. Claude writes a question bank from your context; in the meeting, Jev surfaces the one that fits the moment. Skipped, it's written when you start.")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                    let shown = showAllQuestions ? session.prep.bank : Array(session.prep.bank.prefix(5))
                    ForEach(shown) { q in
                        HStack(alignment: .top, spacing: 6) {
                            Text(q.topic).font(.system(size: 9.5, weight: .bold)).foregroundStyle(CardKind.ask.color).frame(width: 64, alignment: .leading).lineLimit(1)
                            Text(q.text).font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            IconButton(symbol: "xmark", size: 8) { session.prep.bank.removeAll { $0.id == q.id } }
                        }
                    }
                    if session.prep.bank.count > 5 {
                        Button(showAllQuestions ? "Show fewer" : "Show all \(session.prep.bank.count)") { showAllQuestions.toggle() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(CardKind.ask.color)
                    }
                }

                Button { session.start() } label: {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Start listening").font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Text("⌃⌥A").font(.system(size: 12, weight: .medium)).opacity(0.6)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                }
                .buttonStyle(.plain)

                if !session.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECENT").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.faint)
                        ForEach(session.recent.prefix(4), id: \.self) { url in
                            Button { NSWorkspace.shared.open(url) } label: {
                                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

struct ModeChip: View {
    let mode: Playbook.Mode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol).font(.system(size: 14))
                Text(mode.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.dim)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accent.opacity(0.14) : (hover ? Theme.cardHover : Theme.card)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent.opacity(0.55) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Field: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        PlainField(placeholder: placeholder, text: $text)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}
