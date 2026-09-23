import AppKit

/// The menu-bar mark: the app icon's index card as a template image, with the cue line filled.
enum CuecardMark {
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            let card = NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 16, height: 11), xRadius: 1.8, yRadius: 1.8)
            card.lineWidth = 1.4
            NSColor.black.setStroke()
            card.stroke()
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: 1, y: 9.6, width: 16, height: 1.2)).fill()   // header rule
            NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5.6, width: 11, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()  // the cue
            NSBezierPath(roundedRect: NSRect(x: 3.5, y: 3.2, width: 7, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cuecard"
        return image
    }
}
