import AVFoundation
import Speech

/// Live on-device transcription of one audio source with SpeechAnalyzer (macOS 26). Two run side by side,
/// one for the microphone and one for the Mac's audio, so every sentence knows who said it.
final class Transcriber {
    enum Event {
        case partial(String)
        case final(String)
    }

    let speaker: Speaker
    var onEvent: ((Event) -> Void)?
    /// Most recent loudness, 0...1.
    private(set) var level: Float = 0
    private(set) var heardAnything = false

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    var paused = false

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    static func locale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    /// Downloads the speech model for the language if it isn't on the Mac yet. Returns false if it can't.
    static func prepare(_ locale: Locale, status: @escaping (String) -> Void) async -> Bool {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
                status("Downloading the speech model…")
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            Log.write("speech assets: \(error)")
            return false
        }
    }

    func start(locale: Locale, vocabulary: [String]) async throws {
        let transcriber = Transcriber.module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            do { try await analyzer.setContext(context) } catch { Log.write("speech context: \(error)") }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let speaker = self.speaker
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let final = result.isFinal
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if final {
                            if !text.isEmpty { self.onEvent?(.final(text)) } else { self.onEvent?(.partial("")) }
                        } else {
                            self.onEvent?(.partial(text))
                        }
                    }
                }
            } catch {
                Log.write("speech \(speaker.rawValue): \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        Log.write("speech \(speaker.rawValue): started \(locale.identifier) format=\(format.map { "\($0.sampleRate)" } ?? "?")")
    }

    /// Call from the audio thread. Converts synchronously (the buffer may not outlive the call) and queues it.
    func append(_ buffer: AVAudioPCMBuffer) {
        let peak = peakLevel(buffer)
        level = max(peak, level * 0.85)
        if peak > 0.02 { heardAnything = true }
        guard !paused, let format, let continuation else { return }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            inputFormat = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }

    func decay() { level *= 0.6 }

    func finish() async {
        continuation?.finish()
        continuation = nil
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { Log.write("speech finish: \(error)") }
        analyzer = nil
    }
}
