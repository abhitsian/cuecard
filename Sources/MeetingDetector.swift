import AppKit
import CoreAudio

/// Notices when another app starts using the microphone (a call starting) and when it stops.
final class MeetingDetector {
    /// The app now using the mic, or nil when none is.
    var onChange: ((String?) -> Void)?
    private var timer: Timer?
    private var candidate: (name: String, since: Date)?
    private(set) var current: String?
    private let ignored = ["Cuecard", "Pointer", "Showtell", "Siri", "Dictation", "Voice Control", "SpeechRecognitionCore", "corespeechd", "Seek", "Mudra", "Poised", "loginwindow"]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() { timer?.invalidate() }

    private func check() {
        let name = MeetingDetector.appsUsingMic().first { app in !ignored.contains { app.localizedCaseInsensitiveContains($0) } }
        if let name {
            if candidate?.name != name { candidate = (name, Date()) }
            // A few seconds of use, so a dictation blip doesn't count.
            if current != name, let c = candidate, Date().timeIntervalSince(c.since) >= 5 {
                current = name
                onChange?(name)
            }
        } else {
            candidate = nil
            if current != nil { current = nil; onChange?(nil) }
        }
    }

    /// Names of apps (other than this one) currently taking microphone input.
    static func appsUsingMic() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid)
            if pid == me { continue }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle)
            let bundleID = bundle?.takeRetainedValue() as String? ?? ""
            names.append(appName(pid: pid, bundleID: bundleID))
        }
        return names
    }

    /// Helper processes (Chrome's, Teams' WebView) report their own bundle id; map them to the app people know.
    private static func appName(pid: pid_t, bundleID: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName,
           !name.lowercased().contains("helper") { return name }
        let known: [(String, String)] = [("com.google.chrome", "Chrome"), ("com.microsoft.teams", "Teams"), ("us.zoom", "Zoom"),
                                         ("com.apple.safari", "Safari"), ("com.apple.facetime", "FaceTime"), ("com.tinyspeck.slack", "Slack"),
                                         ("company.thebrowser", "Arc"), ("com.microsoft.edge", "Edge"), ("com.cisco.webex", "Webex")]
        let lower = bundleID.lowercased()
        if let match = known.first(where: { lower.hasPrefix($0.0) }) { return match.1 }
        return NSWorkspace.shared.runningApplications.first { !bundleID.isEmpty && bundleID.hasPrefix($0.bundleIdentifier ?? "~") }?.localizedName
            ?? (bundleID.isEmpty ? "An app" : bundleID)
    }
}
