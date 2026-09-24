# Cuecard

A menu-bar meeting copilot for macOS 26. It listens with you and, while the meeting is happening, shows what to say, what to ask and what to write down.

## How it works

| Layer | What does it | Speed |
|---|---|---|
| Hearing | Mic (AVAudioEngine) and the Mac's audio (Core Audio process tap), each transcribed on-device by its own SpeechAnalyzer, so every sentence knows whether You or Them said it | final sentence ~0.3 s after it's spoken |
| Sorting | Jev (TypeSafe) judges each finished turn: the 7 core categories, the mode's signals, which open question it answers, who owns an action, which prepared question fits next | ~0.4 s |
| Writing | Claude through `claude -p` (your Claude Code login, one warm process per prompt): answers when you're asked, new questions when nothing prepared fits, tidy wording for captures, running memory, recap | first words ~0.8 s |

Code, not a model, decides what reaches the screen (thresholds, at most two captures per turn, one signal card per turn, no repeat within 4 min).

## The categorisation framework

Core categories, every meeting: **Asked you** (→ SAY card), **Action item** (owner, due), **Decision**, **Open question** (auto-marked answered), **Next step**, **Risk / blocker**, **Key fact**. Gates: **Vague** (→ a clarifying ASK) and **Filler** (ignored).

Signals by mode:

| Mode | Signals | Question bank |
|---|---|---|
| Meeting | Disagreement | scope, owners, dates, risks |
| Interviewing | Strong evidence, No numbers, "We" not "I", Surface answer, Red flag | competencies × opener + probes, tied to the resume |
| Being interviewed | They're probing, What they value, Possible concern | questions to ask them, likely questions to prepare |
| 1:1 | Hesitation, Frustration, Overload, Unspoken ask, Growth, Low energy | wellbeing, workload, blockers, growth, follow-ups |
| Review / decision | Disagreement, No owner, Scope creep, Dependency | what's decided, options, owners, what changes our mind |
| Customer call | Pain, Workaround, Objection, Buying signal, Quote | discovery |
| Watching a recording | Unclear, Claim to check, Ask the presenter, Relevant to you | questions to take away; no SAY cards, since nobody can ask you anything |

Follow-up questions come from two places: the **question bank** Claude writes from your prep (Jev picks the one that fits the moment and ticks it off when you ask it), and **live questions** Claude writes when a signal or a vague answer needs a new one.

## Use

- ⌃⌥A start / stop · ⌃⌥S show / hide the panel · ⌃⌥N help me now
- Before a meeting: pick the mode, add a goal and context (paste or attach a JD, resume, last 1:1 notes), optionally Prepare questions.
- When Teams, Zoom or Chrome takes the mic, the panel offers to listen. When the call lets go of the mic for a minute and nobody is talking, Cuecard wraps up.
- The panel is hidden from screen sharing by default.
- Notes save to `~/Documents/Cuecard/` as Markdown: recap, captures, question coverage, transcript.

Permissions: Microphone, System Audio Recording (for the other side), Calendar (optional).

## Meeting pages

Every meeting gets a page at `~/Documents/Cuecard/pages/<note>.html`, built from its Markdown note: the recap, what was captured live, and the transcript with a You/Them filter and search. `~/Documents/Cuecard/index.html` lists them by day with a mode filter and search. Open it from the menu (Open meetings library, ⌘L), or Page on the panel once a recap is done. Pages for older notes are written on launch.

## Notion context

With the Notion connector in your Claude Code login, Cuecard can read your Notion for the meeting you're in: open tasks, what was decided last time, background. **From Notion** on the prep screen puts it in the context box (so Prepare writes questions from it); if you skip that, it's fetched in the background when the meeting starts, added to the context every suggestion reads, and up to five questions from it land under Questions tagged "Notion". It only reads: every Notion write tool is blocked. Turn it off in the menu (Pull context from Notion at start). It takes a minute or two.

## After the write-up

`defaults write com.vaibhav.cuecard afterWriteUp "/path/to/script"` runs that command with the saved note's path once each recap is written (for example, to file it into a notes app).

## Build

`./build.sh` (installs to `~/Applications/Cuecard.app`). Checks without the UI:

- `Cuecard --simulate script.txt oneOnOne [--recap]` runs a scripted meeting through Jev and Claude
- `Cuecard --transcribe me.wav them.wav` runs audio files through the transcribers
- `Cuecard --render out.png live|prep|notes|questions|recap|mini` draws the panel with sample data
- Log: `~/Library/Logs/Cuecard.log`
