import SwiftUI

/// The answer being graded against its structure, step by step: strong, weak (with what failed) or not yet
/// covered. Every step can be probed, which asks Claude for the follow-up that goes after its gap.
struct MapTab: View {
    @EnvironmentObject var session: Session
    @ObservedObject var meeting: Meeting

    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(meeting.frames) { frame in
                    FrameCard(frame: frame, meeting: meeting)
                }
                if meeting.frames.isEmpty {
                    Text("No answer structures chosen for this meeting. Pick them in prep (What are you testing?).")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.vertical, 16)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FrameCard: View {
    @EnvironmentObject var session: Session
    let frame: Frame
    @ObservedObject var meeting: Meeting

    var body: some View {
        let states = frame.nodes.map { meeting.state(frame, $0) }
        let covered = states.filter { $0.status != .missing }.count
        let strong = states.filter { $0.status == .strong }.count
        let lastCovered = states.lastIndex { $0.status != .missing } ?? -1
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(frame.name).font(.system(size: 12.5, weight: .bold))
                Spacer()
                Text("\(strong) strong · \(covered - strong) weak · \(frame.nodes.count - covered) open")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint).monospacedDigit()
            }
            HStack(spacing: 2) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                    Capsule().fill(color(s.status)).frame(height: 4)
                }
            }
            .padding(.bottom, 4)
            ForEach(Array(frame.nodes.enumerated()), id: \.offset) { i, node in
                StepRow(frame: frame, node: node, state: states[i], skipped: states[i].status == .missing && i < lastCovered, meeting: meeting)
            }
        }
    }

    private func color(_ status: NodeState.Status) -> Color {
        switch status {
        case .strong: return CardKind.action.color
        case .weak: return Theme.accent
        case .missing: return Color.white.opacity(0.12)
        }
    }
}

struct StepRow: View {
    @EnvironmentObject var session: Session
    let frame: Frame
    let node: Frame.Node
    let state: NodeState
    let skipped: Bool
    @ObservedObject var meeting: Meeting
    @State private var hover = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(tint).frame(width: 14)
                Text(node.label).font(.system(size: 12.5, weight: state.status == .missing ? .regular : .semibold))
                    .foregroundStyle(state.status == .missing ? Theme.dim : .white)
                if skipped { Pill(text: "skipped", color: Theme.faint) }
                Spacer(minLength: 4)
                if hover || state.status == .weak || skipped {
                    Button { session.brain?.probe(frame: frame, node: node); session.tab = .live } label: {
                        Label("Ask", systemImage: "questionmark.bubble").font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CardKind.ask.color)
                    .help("Suggest a follow-up that goes after this step")
                }
            }
            ForEach(node.tests.filter { state.failing.contains($0.key) }, id: \.key) { test in
                Text(test.weak).font(.system(size: 11)).foregroundStyle(Theme.accent).padding(.leading, 22)
            }
            if open, !state.text.isEmpty {
                Text("“\(String(state.text.suffix(360)))”").font(.system(size: 11)).italic().foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            }
            if open, state.status == .missing {
                Text(node.about).font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open.toggle() }
    }

    private var symbol: String {
        switch state.status {
        case .strong: return "checkmark.circle.fill"
        case .weak: return "exclamationmark.circle.fill"
        case .missing: return skipped ? "circle.dashed" : "circle"
        }
    }

    private var tint: Color {
        switch state.status {
        case .strong: return CardKind.action.color
        case .weak: return Theme.accent
        case .missing: return Theme.faint
        }
    }
}

/// Prep: which answer structures to grade in this meeting.
struct FramePicker: View {
    @EnvironmentObject var session: Session
    var body: some View {
        let relevant = session.library.filter { $0.modes.contains(session.prep.mode.rawValue) || session.prep.frames.contains($0.id) }
        let others = session.library.filter { !relevant.contains($0) }
        VStack(alignment: .leading, spacing: 6) {
            FlowChips(frames: relevant)
            if !others.isEmpty {
                Menu {
                    ForEach(others) { frame in Button(frame.name) { session.prep.frames.append(frame.id) } }
                } label: {
                    Label("More", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.dim)
            }
            if let first = session.library.first(where: { session.prep.frames.contains($0.id) }) {
                Text(session.prep.frames.count == 1 ? first.summary : "Cuecard maps each answer onto these and flags the weak step, so you know what to follow up on.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FlowChips: View {
    @EnvironmentObject var session: Session
    let frames: [Frame]
    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(frames) { frame in
                let on = session.prep.frames.contains(frame.id)
                Button {
                    if on { session.prep.frames.removeAll { $0 == frame.id } } else { session.prep.frames.append(frame.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                        Text(frame.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.dim)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.accent.opacity(0.13) : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Theme.accent.opacity(0.5) : Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
