import AppKit
import SwiftUI
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private let session = Session.shared
    private let detector = MeetingDetectorState.shared
    private var lastIcon = ""
    private var sharingObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch")
        panel = PanelController(session: session)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatus()

        session.onShowPanel = { [weak self] in self?.panel.show() }
        session.onChange = { [weak self] in self?.refreshStatus() }

        hotKeys = [
            HotKey(keyCode: HotKey.keyA) { [weak self] in self?.toggleListening() },
            HotKey(keyCode: HotKey.keyS) { [weak self] in self?.panel.toggle() },
            HotKey(keyCode: HotKey.keyN) { [weak self] in self?.session.nudge() },
        ]
        for key in hotKeys where !key.registered { Log.write("hotkey not registered") }

        detector.onChange = { [weak self] app in self?.callChanged(app) }
        if Prefs.shared.detectMeetings { detector.start() }
        sharingObserver = Prefs.shared.$hideFromSharing.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panel.applySharing() }
        }

        session.refreshFromCalendar()
        if ProcessInfo.processInfo.arguments.contains("--show") || !UserDefaults.standard.bool(forKey: "launched") {
            UserDefaults.standard.set(true, forKey: "launched")
            panel.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = session.meeting, m.live { Archive.write(m) }
        Claude.shared.coolDown()
    }

    // MARK: Actions

    @objc func toggleListening() {
        if session.meeting?.live == true {
            session.stop()
        } else {
            session.start()
        }
        panel.show()
    }

    @objc func hidePanel() { panel.hide() }
    @objc func showPanel() { panel.focus() }
    @objc func nudge() { session.nudge() }
    @objc func pause() { session.pause() }
    @objc func newMeeting() { session.reset(); panel.focus() }
    @objc func openFolder() { NSWorkspace.shared.open(Prefs.meetingsFolder) }
    @objc func openRecent(_ item: NSMenuItem) { if let url = item.representedObject as? URL { NSWorkspace.shared.open(url) } }
    @objc func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc func setModel(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let model = SuggestModel(rawValue: raw) { Prefs.shared.model = model }
    }

    @objc func toggleSetting(_ item: NSMenuItem) {
        let prefs = Prefs.shared
        switch item.tag {
        case 1: prefs.systemAudio.toggle()
        case 2: prefs.autoSuggest.toggle()
        case 3:
            prefs.detectMeetings.toggle()
            prefs.detectMeetings ? detector.start() : detector.stop()
        case 4: prefs.hideFromSharing.toggle(); panel.applySharing()
        case 5: prefs.launchAtLogin.toggle()
        default: break
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Cuecard Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(Prefs.shared))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Calls starting and ending

    private func callChanged(_ app: String?) {
        guard session.meeting?.live != true else { return }
        session.detected = app
        guard let app, Prefs.shared.detectMeetings else { return }
        Log.write("detector: \(app) took the mic")
        if session.meeting != nil { session.reset() }
        session.refreshFromCalendar()
        panel.show()
        // The offer fades if it isn't taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            if self?.session.meeting == nil, self?.session.detected == app { self?.session.detected = nil }
        }
    }

    // MARK: Menu bar

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let m = session.meeting
        let symbol: String
        var title = ""
        switch m?.phase {
        case .listening?:
            symbol = m?.thinking == true ? "waveform.badge.magnifyingglass" : "waveform"
            title = " " + (m?.elapsed ?? "")
        case .paused?: symbol = "pause.circle"; title = " Paused"
        case .wrapping?: symbol = "text.badge.checkmark"; title = " Writing up"
        default:
            // A finished meeting's recap still being written in the background.
            if session.writingUp > 0 { symbol = "text.badge.checkmark"; title = " Writing up" } else { symbol = "text.bubble" }
        }
        let key = symbol + title
        guard key != lastIcon else { return }
        lastIcon = key
        let image = symbol == "text.bubble" ? CuecardMark.menuBar() : NSImage(systemSymbolName: symbol, accessibilityDescription: "Cuecard")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = session.meeting?.live == true
        let prefs = Prefs.shared

        if let m = session.meeting, live {
            let header = NSMenuItem(title: "\(m.title) · \(m.elapsed)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(item("Stop and write up", #selector(toggleListening), key: "a"))
            menu.addItem(item(m.phase == .paused ? "Resume" : "Pause", #selector(pause)))
            menu.addItem(item("Help me now", #selector(nudge), key: "n"))
        } else {
            menu.addItem(item("Start listening", #selector(toggleListening), key: "a"))
            menu.addItem(item("Prepare for a meeting…", #selector(newMeeting)))
        }
        menu.addItem(item(panel.visible ? "Hide panel" : "Show panel", panel.visible ? #selector(hidePanel) : #selector(showPanel), key: "s"))
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recent meetings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for url in Archive.recent() {
            let entry = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            sub.addItem(entry)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")) }
        sub.addItem(.separator())
        sub.addItem(item("Open meetings folder", #selector(openFolder)))
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())

        let model = NSMenuItem(title: "Model: \(prefs.model.short)", action: nil, keyEquivalent: "")
        let models = NSMenu()
        for m in SuggestModel.allCases {
            let entry = NSMenuItem(title: m.label, action: #selector(setModel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = m.rawValue
            entry.state = prefs.model == m ? .on : .off
            models.addItem(entry)
        }
        model.submenu = models
        menu.addItem(model)
        menu.addItem(toggle("Hear the other side", 1, prefs.systemAudio))
        menu.addItem(toggle("Suggest automatically", 2, prefs.autoSuggest))
        menu.addItem(toggle("Offer to listen when a call starts", 3, prefs.detectMeetings))
        menu.addItem(toggle("Hide from screen sharing", 4, prefs.hideFromSharing))
        menu.addItem(toggle("Open at login", 5, prefs.launchAtLogin))
        let jev = NSMenuItem(title: prefs.useJev && prefs.jevKey != nil ? "Jev: on" : "Jev: off (keyword rules)", action: nil, keyEquivalent: "")
        jev.isEnabled = false
        menu.addItem(jev)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(NSMenuItem(title: "Quit Cuecard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty, key != "," { entry.keyEquivalentModifierMask = [.control, .option] }
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ tag: Int, _ on: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = tag
        entry.state = on ? .on : .off
        return entry
    }
}
