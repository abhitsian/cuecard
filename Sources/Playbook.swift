import Foundation

/// What Cuecard listens for. Every meeting uses the core categories; the meeting's mode adds its own signals,
/// seeds the question bank, and shapes the suggestions and the recap.
enum Playbook {
    enum Mode: String, CaseIterable, Identifiable {
        case general, interviewing, interviewed, oneOnOne, review, decision, customer, recording
        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "Meeting"
            case .interviewing: return "Interviewing"
            case .interviewed: return "Being interviewed"
            case .oneOnOne: return "1:1"
            case .review: return "Product review"
            case .decision: return "Decision"
            case .customer: return "Customer call"
            case .recording: return "Watching a recording"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "person.3"
            case .interviewing: return "person.crop.circle.badge.questionmark"
            case .interviewed: return "person.crop.circle.badge.checkmark"
            case .oneOnOne: return "person.2"
            case .review: return "doc.text.magnifyingglass"
            case .decision: return "checkmark.seal"
            case .customer: return "building.2"
            case .recording: return "play.rectangle"
            }
        }

        /// One line under the mode picker.
        var blurb: String {
            switch self {
            case .general: return "Captures actions, decisions and open questions, and suggests what to ask."
            case .interviewing: return "Probes vague answers, tracks which areas you've covered, and notes evidence."
            case .interviewed: return "Helps you answer: structure, the story to use, and what they care about."
            case .oneOnOne: return "Watches for missed signals: hesitation, overload, unspoken asks."
            case .review: return "Grades the proposal as it's presented and suggests the question that finds the weak spot kindly."
            case .decision: return "Pins down the decision, owners and dates, and flags fast agreement and lukewarm yeses."
            case .customer: return "Captures pains, workarounds, objections and quotable lines."
            case .recording: return "You're only listening: suggests questions to ask later, what to clarify or look up, and claims to check."
            }
        }

        /// Placeholder for the context box: what's worth pasting before this kind of meeting.
        var contextHint: String {
            switch self {
            case .general: return "Agenda, background, what was said last time…"
            case .interviewing: return "Paste the JD, the candidate's resume, and the competencies you're assessing…"
            case .interviewed: return "Paste the JD, company notes, and the stories you want to use…"
            case .oneOnOne: return "Who it's with, notes from last time, what's on their plate, what you want to raise…"
            case .review: return "The doc or spec being reviewed, what you need from the review, known concerns…"
            case .decision: return "The proposal, the options, who needs to agree, known concerns…"
            case .customer: return "Who they are, what they use today, deal stage, what you want to learn…"
            case .recording: return "What the recording is, who is presenting, what you already know, what you need from it…"
            }
        }

        var goalHint: String {
            switch self {
            case .general: return "What do you want out of this meeting?"
            case .interviewing: return "e.g. Assess product sense and stakeholder handling"
            case .interviewed: return "e.g. Land the product strategy round"
            case .oneOnOne: return "e.g. Check how they're really doing, agree on the Q4 goal"
            case .review: return "e.g. Decide if the spec is ready to build"
            case .decision: return "e.g. Get a yes on the October ship date"
            case .customer: return "e.g. Understand why onboarding stalls"
            case .recording: return "e.g. Work out what the regions launch means for my team"
            }
        }

        /// Core categories captured to the notes in this mode. In an interview the other side's stories aren't
        /// the meeting's decisions or open questions.
        var captures: Set<Category> {
            switch self {
            case .interviewing, .interviewed: return [.action, .nextStep, .fact]
            // Nobody in a recording can ask the user anything.
            case .recording: return Set(Category.allCases).subtracting([.askedYou])
            default: return Set(Category.allCases)
            }
        }

        /// Mode-specific signals Jev listens for, on top of the core categories.
        var signals: [Signal] {
            let tells: [Signal] = [
                Signal("dodged", "Didn't answer", "Does `latest.text` avoid answering the question it was asked: answering an easier or different question, staying general, or turning to what would or should happen instead of what did?"),
                Signal("no_specifics", "No specifics", "Does `latest.text` make claims without any specific name, number, date, artifact or direct quote?"),
            ]
            return modeSignals + ([.interviewing, .oneOnOne, .decision, .customer].contains(self) ? tells : [])
        }

        private var modeSignals: [Signal] {
            switch self {
            case .general:
                return [Signal("disagreement", "Disagreement", "Does `latest.text` push back on, contradict or disagree with something said earlier?")]
            case .interviewing:
                return [
                    Signal("evidence", "Strong evidence", "Does `latest.text` give a specific example with the speaker's own actions, reasoning and a concrete outcome?", positive: true),
                    Signal("unquantified", "No numbers", "Does `latest.text` claim impact or success without any number, metric or measurable result?"),
                    Signal("we_not_i", "\"We\" not \"I\"", "Does `latest.text` describe what a team did without saying what the speaker personally did or decided?"),
                    Signal("surface", "Surface answer", "Does `latest.text` answer at a generic, textbook level without a real example or trade-off?"),
                    Signal("red_flag", "Red flag", "Does `latest.text` blame others, contradict something said earlier, or dodge the question?"),
                ]
            case .interviewed:
                return [
                    Signal("probe", "They're probing", "Does `latest.text` dig deeper into something the user said earlier, showing interest or doubt?"),
                    Signal("values", "What they value", "Does `latest.text` reveal what the interviewer or company cares about (a priority, a value, a problem they have)?", positive: true),
                    Signal("concern", "Possible concern", "Does `latest.text` hint at doubt about the user's fit, experience or answer?"),
                ]
            case .oneOnOne:
                return [
                    Signal("hedging", "Hesitation", "Does the speaker of `latest.text` sound hesitant, reluctant or hedging (\"I guess\", \"it's fine\", \"sort of\", trailing off)?"),
                    Signal("frustration", "Frustration", "Does `latest.text` express frustration, annoyance or feeling blocked, even mildly?"),
                    Signal("overload", "Overload", "Does `latest.text` suggest too much work, stretched capacity, long hours or burnout?"),
                    Signal("unspoken_ask", "Unspoken ask", "Does `latest.text` hint at a need or request without asking for it directly?"),
                    Signal("growth", "Growth", "Does `latest.text` touch on career, growth, promotion, recognition or wanting different scope?", positive: true),
                    Signal("disengaged", "Low energy", "Does `latest.text` sound disengaged, flat or unusually brief for a question that deserved more?"),
                ]
            case .review:
                return [
                    Signal("level_mismatch", "Talking past each other", "Does `latest.text` argue a detail while the discussion is about a bigger question (impact vs execution vs how it looks), or vice versa?"),
                    Signal("scope_creep", "Scope creep", "Does `latest.text` add new scope, requirements or asks beyond the original proposal?"),
                    Signal("dependency", "Dependency", "Does `latest.text` depend on another team, system or approval outside the room?"),
                ]
            case .decision:
                return [
                    Signal("lukewarm", "Lukewarm yes", "Does `latest.text` agree in a hedged or reluctant way (\"yeah, maybe\", \"should be fine\", \"I guess we can\")?"),
                    Signal("coercive", "Pushing for alignment", "Does `latest.text` pressure the group to agree (\"are we all aligned?\", \"so we agree\") rather than inviting concerns?"),
                    Signal("disagreement", "Disagreement", "Does `latest.text` push back on, contradict or disagree with something said earlier?"),
                    Signal("unowned", "No owner", "Does `latest.text` describe work that needs doing without anyone taking it?"),
                    Signal("scope_creep", "Scope creep", "Does `latest.text` add new scope, requirements or asks beyond the original proposal?"),
                    Signal("dependency", "Dependency", "Does `latest.text` depend on another team, system or approval outside the room?"),
                ]
            case .customer:
                return [
                    Signal("pain", "Pain", "Does `latest.text` describe a problem, cost or frustration the customer has today?"),
                    Signal("workaround", "Workaround", "Does `latest.text` describe how they cope today: a manual process, spreadsheet, or other tool?"),
                    Signal("objection", "Objection", "Does `latest.text` raise an objection, doubt about the product, or a reason not to buy?"),
                    Signal("buying", "Buying signal", "Does `latest.text` show intent: timeline, budget, next steps, or asking about pricing or rollout?", positive: true),
                    Signal("quote", "Quote", "Is `latest.text` a vivid, quotable line from the customer that captures their situation?", positive: true),
                ]
            case .recording:
                return [
                    Signal("unclear", "Unclear", "Does `latest.text` use a term, acronym, product name or idea without explaining it, or skip a step a listener would need?"),
                    Signal("check", "Claim to check", "Does `latest.text` make a claim, number or date the listener should verify or get the source for before relying on it?"),
                    Signal("ask_later", "Ask the presenter", "Does `latest.text` leave something open that the presenter or their team could answer: how it works, when, who owns it, what's not covered?"),
                    Signal("relevant", "Relevant to you", "Does `latest.text` touch the user's own work, team or goal as described in `meeting.context` or `meeting.goal`?", positive: true),
                ]
            }
        }

        /// How to write the question bank before the meeting.
        var bankBrief: String {
            switch self {
            case .general:
                return "Questions the user could ask to reach their goal: clarify scope, owners, dates, risks and success criteria."
            case .interviewing:
                return "An interview plan. Group questions by competency (use the competencies in the context, or infer 4-6 from the JD). For each competency: an opening behavioural question and two probes (for specifics, for the candidate's own role, for numbers, for trade-offs). Tie questions to claims in the resume when there is one."
            case .interviewed:
                return "Questions the user should ask the interviewers (about the team, the problem, how success is measured, what worries them), plus likely questions they will be asked, written as 'They may ask: …' so the user can prepare."
            case .oneOnOne:
                return "Questions for a 1:1 that surface what isn't said: how they're really doing, workload, blockers, what they need from the user, growth, and follow-ups from last time. Open-ended, warm, one idea each."
            case .review:
                return "Questions for reviewing a proposal kindly and rigorously: what they're trying to say, the customer problem and value, the expected outcome and how it's measured, what makes it hard, how it fails, what's traded off."
            case .decision:
                return "Questions that drive to a decision: what exactly is being decided, options and trade-offs, who owns what by when, risks, what would change our mind, what we need from other teams."
            case .customer:
                return "Discovery questions: their current process, the last time the problem happened, cost of the problem, workarounds, who else is involved, what they tried, what success looks like, timeline and decision process."
            case .recording:
                return "Questions to keep in mind while watching a recording, so the user gets what they need from it: what it changes for their work, how it works, when it lands, who owns it, what it doesn't cover, and what to ask the presenter afterwards."
            }
        }

        /// How suggestions should behave during the meeting.
        var liveGuidance: String {
            switch self {
            case .general:
                return "Help the user steer: sharp questions, clarity on owners and dates, answers when they are asked."
            case .interviewing:
                return "The user is interviewing a candidate ('Them'). Suggest probes that get to specifics: what did YOU do, numbers, trade-offs, what went wrong. Never suggest leading questions. Note strong evidence and concerns per competency."
            case .interviewed:
                return "The user is the candidate. When asked something, SAY gives the answer shape: the headline first, then the one story or example from the context that fits best (situation, what they did, result with a number), in the user's own voice. Keep it speakable. Suggest ASK questions for the interviewer at natural pauses."
            case .oneOnOne:
                return "Read between the lines. When a signal appears (hesitation, frustration, overload, unspoken ask), suggest a gentle, open follow-up question that invites them to say more. Never diagnose; ask."
            case .review:
                return "The user is reviewing someone's proposal. Find the weakest part of the thinking and suggest the question that exposes it without putting the presenter on the defensive: ask about the customer, the outcome, the crux, the failure mode. Never argue the solution."
            case .decision:
                return "Drive to closure: name the decision, the owner and the date. Flag disagreement that was glossed over and asks that grew scope."
            case .customer:
                return "Stay curious and specific: ask about the last time it happened, how much it costs, who else feels it. Never pitch; learn."
            case .recording:
                return "The user is watching a recording and cannot speak to anyone in it. Never write SAY cards. ASK cards are questions the user should take away: to ask the presenter or their team afterwards, to clarify something that was skipped, or to look up. Write each as the question itself, one idea, specific to what was just said, and when it matters to the user's own work say why in a few words. When a term goes unexplained, gloss it in one line if you know it."
            }
        }

        /// Headings for the write-up after the meeting.
        var recapSections: String {
            switch self {
            case .review:
                return "## Summary\n## Where the proposal is strong\n## Where it's weak (by step)\n## Open questions for the presenter\n## Decisions and next steps\n## Follow-up note"
            case .general, .decision:
                return "## Summary\n## Decisions\n## Action items\n## Open questions\n## Risks\n## Follow-up note"
            case .interviewing:
                return "## Summary\n## Scorecard (one line per competency: rating Strong / Mixed / Weak / Not covered, with the evidence)\n## Strengths\n## Concerns\n## Not covered, ask next round\n## Recommendation"
            case .interviewed:
                return "## Summary\n## Questions they asked, and how I answered\n## What they care about\n## Where I could have been stronger\n## Thank-you note"
            case .oneOnOne:
                return "## Summary\n## Signals worth following up\n## Commitments (mine / theirs)\n## Topics for next 1:1\n## Follow-up note"
            case .customer:
                return "## Summary\n## Pains (with quotes)\n## Current workaround\n## Objections\n## Buying signals and next steps\n## Follow-up note"
            case .recording:
                return "## Summary\n## Key points\n## Questions to ask (and who to ask)\n## To clarify or look up\n## Claims to check\n## What it means for my work\n## Follow-ups"
            }
        }
    }

    /// A mode-specific thing to listen for, judged by Jev on every turn.
    struct Signal {
        let key: String
        let label: String
        let question: String
        /// Good news (evidence, a buying signal) rather than something to follow up.
        let positive: Bool
        init(_ key: String, _ label: String, _ question: String, positive: Bool = false) {
            self.key = key; self.label = label; self.question = question; self.positive = positive
        }
    }

    /// The core categories, judged on every turn of every meeting.
    enum Category: String, CaseIterable {
        case askedYou = "asked_you"
        case action = "action_item"
        case decision
        case openQuestion = "open_question"
        case nextStep = "next_step"
        case risk
        case fact = "key_fact"

        var question: String {
            switch self {
            case .askedYou: return "Does `latest.text` ask the user (speaker 'You', named in `meeting.user`) a question, or ask them for something, that they are expected to respond to now? A question to the whole room that the user would reasonably answer counts."
            case .action: return "Does `latest.text` contain a concrete commitment: someone will do a specific task (\"I'll send\", \"can you take\", \"we need X to do Y\")?"
            case .decision: return "Does `latest.text` state something decided or agreed: a choice made, not a proposal still being discussed?"
            case .openQuestion: return "Does `latest.text` raise a substantive question or unknown about the work that has not been answered yet (not small talk, not rhetorical)?"
            case .nextStep: return "Does `latest.text` set what happens next: a follow-up meeting, a review, a handoff, or the order things will happen in?"
            case .risk: return "Does `latest.text` raise a risk, blocker, dependency or concern about the work?"
            case .fact: return "Does `latest.text` state a specific number, date, metric, name or fact that is worth writing down?"
            }
        }
    }

    /// Extra gates judged with the categories.
    static let vagueQuestion = "Is `latest.text` vague where it matters: an unclear owner, a missing number or date, undefined scope, or a claim without evidence?"
    static let fillerQuestion = "Is `latest.text` small talk, greetings, filler or meeting logistics (screen sharing, audio, scheduling chatter) with nothing worth noting?"
}
