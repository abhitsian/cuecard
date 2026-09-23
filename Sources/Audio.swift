import AVFoundation
import CoreAudio

/// The microphone through AVAudioEngine. Reinstalls itself when the input device changes (AirPods connecting).
final class MicSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    func start() throws {
        try install()
    }

    private func install() throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Cuecard", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.onBuffer?(buffer) }
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("mic: device changed, restarting")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            do { try self.install() } catch { Log.write("mic: restart failed \(error)") }
        }
        Log.write("mic: \(format.sampleRate) Hz × \(format.channelCount)")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays (the other side of a call), through a Core Audio process tap. Audio-only
/// permission ("System Audio Recording Only"), no screen recording, works with headphones.
///
/// The tap reports 48 kHz, but the aggregate device runs at its clock device's rate: a Bluetooth headset in a
/// call drops to 16 or 24 kHz. Buffers are labelled with the aggregate's live rate, and the tap rebuilds itself
/// when the output device changes.
final class SystemAudioTap {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "cuecard.tap", qos: .userInitiated)
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var channels: AVAudioChannelCount = 1
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "System audio \(step) failed (\(status))" }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() throws {
        running = true
        try build()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            Log.write("tap: output device changed, rebuilding")
            self.teardown()
            do { try self.build() } catch { Log.write("tap: rebuild failed \(error.localizedDescription)") }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(SystemAudioTap.system, &SystemAudioTap.defaultOutputAddress, queue, listener)
    }

    private func build() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Cuecard"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure(step: "tap", status: status) }
        tapID = tap

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { teardown(); throw Failure(step: "format", status: status) }
        channels = AVAudioChannelCount(max(1, asbd.mChannelsPerFrame))

        let output = try SystemAudioTap.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cuecard Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { teardown(); throw Failure(step: "aggregate device", status: status) }
        aggregateID = device
        updateFormat()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateFormat() }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(device, &rateAddress, queue, listener)

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.lock.withLock({ self.format }),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self.onBuffer?(buffer)
        }
        guard status == noErr else { teardown(); throw Failure(step: "io proc", status: status) }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else { teardown(); throw Failure(step: "start", status: status) }
        Log.write("tap: tap says \(asbd.mSampleRate) Hz, device runs at \(format?.sampleRate ?? 0) Hz × \(channels), via \(output)")
    }

    /// Labels buffers with the rate the aggregate device is actually running at.
    private func updateFormat() {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0,
              let next = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false) else { return }
        let changed = lock.withLock { () -> Bool in
            defer { format = next }
            return format.map { $0.sampleRate != rate } ?? false
        }
        if changed { Log.write("tap: device rate now \(rate) Hz") }
    }

    func stop() {
        running = false
        if let outputListener { AudioObjectRemovePropertyListenerBlock(SystemAudioTap.system, &SystemAudioTap.defaultOutputAddress, queue, outputListener) }
        outputListener = nil
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener { AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, queue, rateListener) }
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        rateListener = nil
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    static func defaultOutputUID() throws -> String {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        guard status == noErr else { throw Failure(step: "output device", status: status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw Failure(step: "output uid", status: status) }
        return uid.takeRetainedValue() as String
    }
}

/// Loudness of a buffer, 0...1, for the level meters.
func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    var top: Float = 0
    let n = Int(buffer.frameLength)
    for c in 0..<Int(buffer.format.channelCount) {
        let p = channels[c]
        var i = 0
        while i < n { top = max(top, abs(p[i])); i += 4 }
    }
    return min(1, top)
}
