import AppKit
import AtollCore

enum AtollIcon {
    static func statusBarImage(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 22, height: 22).fill()

        let stroke = attention ? NSColor.systemOrange : NSColor.labelColor
        stroke.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 4, y: 6, width: 14, height: 10))
        path.lineWidth = 2
        path.stroke()

        let island = NSBezierPath(roundedRect: NSRect(x: 8, y: 9, width: 6, height: 4), xRadius: 2, yRadius: 2)
        stroke.setFill()
        island.fill()

        image.isTemplate = !attention
        return image
    }

    static func menuImage(for harness: AgentHarness, state: SessionState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        color(for: harness).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill()

        stateColor(for: state).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 1, width: 5, height: 5)).fill()

        return image
    }

    static func color(for harness: AgentHarness) -> NSColor {
        switch harness {
        case .opencode:
            NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.55, alpha: 1)
        case .codex:
            NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.95, alpha: 1)
        case .claude:
            NSColor(calibratedRed: 0.91, green: 0.43, blue: 0.24, alpha: 1)
        case .copilot:
            NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.42, alpha: 1)
        case .pi:
            NSColor(calibratedRed: 0.68, green: 0.50, blue: 0.96, alpha: 1)
        case .atoll:
            NSColor(calibratedRed: 0.22, green: 0.70, blue: 0.92, alpha: 1)
        }
    }

    static func stateColor(for state: SessionState) -> NSColor {
        switch state {
        case .running:
            NSColor.systemGreen
        case .done:
            NSColor.systemGray
        case .waitingForInput:
            NSColor.systemYellow
        case .waitingForPermission:
            NSColor.systemOrange
        case .unknown:
            NSColor.systemBlue
        }
    }
}
