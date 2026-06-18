import AppKit
import AtollCore

enum AtollIcon {
    static func statusBarImage(attentionColor: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 22, height: 22).fill()

        let stroke = attentionColor ?? NSColor.labelColor
        stroke.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 4, y: 6, width: 14, height: 10))
        path.lineWidth = 2
        path.stroke()

        let island = NSBezierPath(roundedRect: NSRect(x: 8, y: 9, width: 6, height: 4), xRadius: 2, yRadius: 2)
        stroke.setFill()
        island.fill()

        image.isTemplate = attentionColor == nil
        return image
    }

    static func stateColor(for state: SessionState) -> NSColor {
        switch state {
        case .running:
            NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.04, alpha: 1)
        case .done:
            NSColor(calibratedRed: 0.10, green: 0.96, blue: 0.40, alpha: 1)
        case .waitingForInput:
            NSColor(calibratedRed: 0.18, green: 0.74, blue: 1.0, alpha: 1)
        case .waitingForPermission:
            NSColor(calibratedRed: 1.0, green: 0.06, blue: 0.16, alpha: 1)
        case .unknown:
            NSColor.systemBlue
        }
    }
}
