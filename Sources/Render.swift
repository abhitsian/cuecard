import SwiftUI
import AppKit

/// `Cuecard --render out.png [prep|live|notes|questions|recap|mini]`: draws the panel with sample data, for design checks.
enum Render {
    @MainActor
    static func run(_ path: String, state: String) {
        isRendering = true
        let session = Session.shared
        if state != "prep" {
            let m = Meeting(title: "1:1 with Maya", mode: .oneOnOne, goal: "Check how he's really doing", context: "",
                            started: Date().addingTimeInterval(-754))
            let now = Date()
            m.lines = [
                Line(speaker: .them, text: "I'll send those by Friday. I just need Leo to give me the dashboard access first.", at: now.addingTimeInterval(-40)),
                Line(speaker: .them, text: "Honestly I'm not sure if billing is the right thing for me to own anymore, but anyway.", at: now.addingTimeInterval(-20)),
            ]
            m.partial[.them] = "Sam, can you tell me what the plan is for the migration"
            m.youLevel = 0.1; m.themLevel = 0.5
            m.cards = [
                Card(kind: .signal, text: "Yeah it's fine, I guess. Busy.", at: now.addingTimeInterval(-300), quote: "Yeah it's fine, I guess.", source: "Hesitation"),
                Card(kind: .ask, text: "When you say \"fine, I guess\", what's making it feel like just fine?", at: now.addingTimeInterval(-290), source: "Hesitation"),
                Card(kind: .risk, text: "Billing spec blocked by repeated design review delays", at: now.addingTimeInterval(-200), source: "Jev"),
                Card(kind: .ask, text: "Doing design work at night sounds like a lot. How sustainable has that been?", at: now.addingTimeInterval(-190), source: "Overload", done: true),
                Card(kind: .action, text: "Send signup funnel metrics", at: now.addingTimeInterval(-40), owner: "Maya", due: "Friday", source: "Jev"),
                Card(kind: .question, text: "Is billing still the right scope for Maya?", at: now.addingTimeInterval(-20), source: "Jev"),
                Card(kind: .decision, text: "Ship the new onboarding in October", at: now.addingTimeInterval(-15), source: "Jev"),
                Card(kind: .ask, text: "What would need to change for billing to feel like yours again?", at: now.addingTimeInterval(-12), source: "From your prep · Growth"),
                Card(kind: .say, text: "The migration plan isn't final. I'll share it by Tuesday.\nHold off on the API rollout until we've scoped it together.", at: now.addingTimeInterval(-3), source: "You were asked"),
            ]
            m.bank = [
                BankQuestion(topic: "Wellbeing", text: "How are you really doing this week?", asked: true),
                BankQuestion(topic: "Wellbeing", text: "Does your plate feel manageable right now?", asked: true),
                BankQuestion(topic: "Growth", text: "What would need to change for billing to feel like yours again?", surfacedAt: now),
                BankQuestion(topic: "Growth", text: "What skill do you want more of before year end?"),
                BankQuestion(topic: "Q4 goal", text: "What outcome should we commit to for onboarding this quarter?"),
            ]
            m.thinking = state == "live"
            let library = Frame.all()
            m.frames = ["story", "product-case"].compactMap { id in library.first { $0.id == id } }
            func set(_ id: String, _ status: NodeState.Status, _ failing: [String] = [], _ text: String = "") {
                var n = NodeState(); n.status = status; n.failing = failing; n.evidence = text.isEmpty ? [] : [text]; m.map[id] = n
            }
            set("story.stakes", .strong, [], "Only 11 of roughly 5,000 customers used it.")
            set("story.role", .weak, ["i"], "We aligned as a group and decided to cut it.")
            set("story.tradeoff", .weak, ["cost"])
            set("story.mechanism", .strong)
            set("product-case.clarify", .strong)
            set("product-case.segment", .weak, ["trade"], "I'd focus on engineers because they're the biggest group.")
            set("product-case.problems", .weak, ["costly"])
            set("product-case.solutions", .weak, ["range", "moonshot"])
            set("product-case.design", .weak, ["concrete", "failure", "trust"])
            if state == "map" { session.tab = .map }
            if state == "recap" {
                m.phase = .done
                m.ended = now
                m.recap = "## Summary\n- Maya is stretched: doing billing design work at night while design review keeps slipping.\n- Agreed to ship the new onboarding in October.\n\n## Signals worth following up\n- Hesitation about owning billing: \"I'm not sure if billing is the right thing for me to own anymore.\"\n- Overload: design work at night.\n\n## Commitments (mine / theirs)\n- Maya: send widget metrics by **Friday** (needs Leo's dashboard access).\n- Me: share the migration plan by Tuesday.\n\n## Follow-up note\nThanks for being straight about billing. Let's give it proper time next week."
                session.tab = .recap
            } else {
                session.tab = state == "notes" ? .notes : (state == "questions" ? .questions : (state == "map" ? .map : .live))
            }
            session.mini = state == "mini"
            session.meeting = m
        } else {
            session.prep.title = "1:1 with Maya"
            session.prep.mode = .oneOnOne
            session.prep.attendees = ["Maya", "Sam"]
            session.prep.mode = .interviewing
            session.prep.frames = ["story", "product-case", "taste"]
            session.prep.title = "Senior PM interview"
        }
        let height: CGFloat = state == "mini" ? 118 : 680
        let view = ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.115, blue: 0.13))
            PanelView().environmentObject(session).environmentObject(Prefs.shared)
        }
        .frame(width: 384, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }
}
