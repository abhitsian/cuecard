import Foundation

extension Simulate {
    /// `Cuecard --judge cases.json out.json`: for each labelled case (the 8 lines before a turn, then the turn),
    /// runs the turn through Jev exactly as a live meeting would and records what reached the board, plus every
    /// score ≥ 0.5. Meeting mode, no prep, no Claude calls. Cases run one at a time.
    static func judge(cases path: String, out: String) {
        Log.echo = false
        guard let data = FileManager.default.contents(atPath: path),
              let cases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { print("can't read \(path)"); exit(1) }
        var results: [[String: Any]] = []
        var index = 0
        func speaker(_ s: String) -> Speaker { s == "You" ? .you : .them }
        func next() {
            guard index < cases.count else {
                let json = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                FileManager.default.createFile(atPath: out, contents: json)
                print("wrote \(results.count) results to \(out)")
                exit(0)
            }
            let c = cases[index]
            index += 1
            let meeting = Meeting(title: "Judged turn", mode: .general, goal: "", context: "")
            for raw in c["context"] as? [String] ?? [] {
                let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                meeting.add(Line(speaker: speaker(parts[0]), text: parts[1].trimmingCharacters(in: .whitespaces), at: Date()))
            }
            let brain = Brain(meeting: meeting)
            guard brain.usesJev else { print("Jev is off or has no key"); exit(1) }
            brain.dryRun = true
            var scores: [String: Double] = [:], ms = 0
            brain.onJudged = { _, _, s, t in scores = s; ms = Int(t * 1000) }
            let line = Line(speaker: speaker(c["speaker"] as? String ?? "Them"), text: c["text"] as? String ?? "", at: Date())
            meeting.add(line)
            brain.heard(line)
            // The turn flushes 1.3 s after its last line; Jev answers in under a second. Allow 8 s, then read the board.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let board = meeting.cards.map { ["kind": $0.kind.label, "owner": $0.owner ?? "", "score": $0.score ?? 0, "text": $0.text] as [String: Any] }
                results.append(["id": c["id"] ?? "", "board": board, "scores": scores, "ms": ms])
                print("\(c["id"] ?? "") \(ms)ms  " + (board.isEmpty ? "—" : board.map { "\($0["kind"]!)" }.joined(separator: ", ")))
                _ = brain
                next()
            }
        }
        next()
        RunLoop.main.run()
    }
}
