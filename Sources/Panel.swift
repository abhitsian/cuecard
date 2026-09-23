import AppKit
import SwiftUI

/// A floating glass panel that sits over the meeting without taking focus from it, follows you across Spaces
/// and full-screen apps, and by default is left out of screen sharing and recordings.
final class CuecardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController {
    let panel: CuecardPanel
    private var miniObserver: Any?
    private var fullHeight: CGFloat = 640

    init(session: Session) {
        panel = CuecardPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 640),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                           backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 340, height: 120)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.appearance = NSAppearance(named: .vibrantDark)
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.55).cgColor
        let host = NSHostingView(rootView: PanelView().environmentObject(session).environmentObject(Prefs.shared))
        host.sizingOptions = []
        for view in [tint, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: glass.leadingAnchor), view.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                view.topAnchor.constraint(equalTo: glass.topAnchor), view.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        }
        panel.contentView = glass
        applySharing()

        if !panel.setFrameUsingName("CuecardPanel"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.maxX - 384 - 16, y: visible.maxY - 640 - 12, width: 384, height: 640), display: false)
        }
        panel.setFrameAutosaveName("CuecardPanel")

        miniObserver = session.$mini.dropFirst().sink { [weak self] mini in self?.setMini(mini) }
    }

    var visible: Bool { panel.isVisible }

    func applySharing() {
        panel.sharingType = Prefs.shared.hideFromSharing ? .none : .readOnly
    }

    func show() {
        restoreIfShrunk()
        panel.orderFrontRegardless()
    }

    /// A panel left compact (saved frame, or a meeting that ended while compact) comes back full size.
    private func restoreIfShrunk() {
        guard !Session.shared.mini, panel.frame.height < 300 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = max(fullHeight, 560)
        frame.origin.y = top - frame.height
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY + 8
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    func focus() {
        show()
        panel.makeKey()
    }

    func hide() { panel.orderOut(nil) }

    func toggle() { panel.isVisible ? hide() : show() }

    /// Compact keeps the top edge where it is and shrinks to the latest suggestion.
    private func setMini(_ mini: Bool) {
        var frame = panel.frame
        let top = frame.maxY
        if mini {
            if frame.height >= 300 { fullHeight = frame.height }
            frame.size.height = 118
        } else {
            frame.size.height = max(fullHeight, 480)
        }
        frame.origin.y = top - frame.height
        if !mini, let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY + 8
        }
        panel.setFrame(frame, display: true, animate: true)
    }
}
