import Foundation
import AVFoundation

/// Command-line checks that run the real pipeline without the UI.
enum Simulate {
    /// `Cuecard --simulate <script> [mode]`: feeds a scripted meeting ("You: …" / "Them: …", "# goal: …",
    /// "# context: …", "# title: …") through Jev and Claude at speaking pace and prints every card.
    static func run(script path: String, mode: String?) {
        Log.echo = true
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); exit(1) }
        var lines: [(Speaker, String)] = []
        var title = "Simulated meeting", goal = "", context = ""
        var frameIDs: [String]?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# title:") { title = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("# goal:") { goal = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("# context:") { context += String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) + "\n" }
            else if line.hasPrefix("# frames:") { frameIDs = line.dropFirst(9).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else if line.hasPrefix("You:") { lines.append((.you, String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces))) }
            else if line.hasPrefix("Them:") { lines.append((.them, String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))) }
        }
        let meeting = Meeting(title: title, mode: Playbook.Mode(rawValue: mode ?? "") ?? .general, goal: goal, context: context)
        let library = Frame.all()
        meeting.frames = (frameIDs ?? Frame.defaults(for: meeting.mode)).compactMap { id in library.first { $0.id == id } }
        let brain = Brain(meeting: meeting)
        print("frames=\(meeting.frames.map(\.id)) of \(library.count)")
        print("mode=\(meeting.mode.label) jev=\(brain.usesJev) model=\(Prefs.shared.model.short) lines=\(lines.count)")
        var seen: [UUID: String] = [:]
        let started = Date()
        func dump() {
            for card in meeting.cards {
                let rendered = "\(card.kind.label.uppercased())\(card.owner.map { " [\($0)]" } ?? "")\(card.due.map { " (due \($0))" } ?? "") \(card.text.replacingOccurrences(of: "\n", with: " / "))\(card.resolved != nil ? " ✓answered" : "")\(card.done ? " ✓asked" : "")  ‹\(card.source ?? "")›"
                if seen[card.id] != rendered {
                    print(String(format: "  %5.1fs  ", Date().timeIntervalSince(started)) + (seen[card.id] == nil ? "+ " : "~ ") + rendered)
                    seen[card.id] = rendered
                }
            }
        }
        brain.start()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in dump() }
        var i = 0
        func next() {
            guard i < lines.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    dump()
                    print("\nmap:\n" + meeting.mapSummary)
                    print("\nbank (\(meeting.bank.count)): " + meeting.bank.map { "\($0.asked ? "✓" : "·") [\($0.topic)] \($0.text)" }.joined(separator: "\n   "))
                    if CommandLine.arguments.contains("--recap") {
                        meeting.phase = .done
                        Task {
                            await brain.writeRecap()
                            print("\n" + (meeting.recap ?? "(no recap)"))
                            Claude.shared.coolDown()
                            exit(0)
                        }
                    } else {
                        Claude.shared.coolDown()
                        exit(0)
                    }
                }
                return
            }
            let (speaker, text) = lines[i]
            i += 1
            let line = Line(speaker: speaker, text: text, at: Date())
            meeting.add(line)
            print(String(format: "%5.1fs %@: %@", Date().timeIntervalSince(started), speaker.rawValue, text))
            brain.heard(line)
            let pace = min(7, max(2.2, Double(text.split(separator: " ").count) / 2.6))
            DispatchQueue.main.asyncAfter(deadline: .now() + pace) { next() }
        }
        // Give the bank a head start, as prep would before a real meeting.
        DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--no-wait") ? 0.5 : 10)) { next() }
        RunLoop.main.run()
    }

    /// `Cuecard --transcribe me.wav [them.wav]`: runs audio files through the live transcribers.
    static func transcribe(_ paths: [String]) {
        Log.echo = true
        Task {
            let locale = await Transcriber.locale()
            _ = await Transcriber.prepare(locale) { print($0) }
            var running: [Transcriber] = []
            for (i, path) in paths.enumerated() {
                let t = Transcriber(speaker: i == 0 ? .you : .them)
                t.onEvent = { event in
                    if case .final(let text) = event { print("\(t.speaker.rawValue): \(text)") }
                }
                try? await t.start(locale: locale, vocabulary: Prefs.shared.vocabularyList)
                running.append(t)
                guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800) else { continue }
                while (try? file.read(into: buffer, frameCount: 4800)) != nil, buffer.frameLength > 0 { t.append(buffer) }
            }
            for t in running { await t.finish() }
            try? await Task.sleep(nanoseconds: 800_000_000)
            exit(0)
        }
        RunLoop.main.run()
    }

    /// `Cuecard --probe-tap 8`: opens the mic (as a call would, which switches a Bluetooth headset to call mode),
    /// records the Mac's audio, transcribes it, and logs levels and every sentence heard.
    static func probeTap(seconds: Double) {
        Log.echo = true
        let tap = SystemAudioTap()
        let mic = MicSource()
        let them = Transcriber(speaker: .them)
        var peak: Float = 0
        var buffers = 0
        var rates = Set<Double>()
        them.onEvent = { if case .final(let text) = $0 { Log.write("probe-tap heard: \(text)") } }
        Task { @MainActor in
            let locale = await Transcriber.locale()
            try? await them.start(locale: locale, vocabulary: [])
            mic.onBuffer = { _ in }
            do { try mic.start() } catch { Log.write("probe-tap: mic \(error.localizedDescription)") }
            tap.onBuffer = { buffer in
                peak = max(peak, peakLevel(buffer)); buffers += 1; rates.insert(buffer.format.sampleRate)
                them.append(buffer)
            }
            do { try tap.start() } catch { Log.write("probe-tap: failed \(error.localizedDescription)"); exit(1) }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            tap.stop()
            mic.stop()
            await them.finish()
            try? await Task.sleep(nanoseconds: 500_000_000)
            Log.write("probe-tap: buffers=\(buffers) peak=\(String(format: "%.3f", peak)) rates=\(rates.sorted())")
            Thread.sleep(forTimeInterval: 0.5)
            exit(0)
        }
        RunLoop.main.run()
    }
}
