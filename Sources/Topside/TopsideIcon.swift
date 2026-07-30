import AppKit
import TopsideCore

private enum TopsideMarkGeometry {
    static let topWidth: CGFloat = 0.94
    static let lowerWidth: CGFloat = 0.34
    static let capsuleHeight: CGFloat = 0.18
    static let rows: [CGFloat] = [0.06, 0.36, 0.66]

    static func rects(in rect: CGRect, originAtTop: Bool) -> [CGRect] {
        rows.enumerated().map { index, normalizedY in
            let normalizedWidth = index == 0 ? topWidth : lowerWidth
            let width = rect.width * normalizedWidth
            let height = rect.height * capsuleHeight
            let y = originAtTop
                ? rect.minY + rect.height * normalizedY
                : rect.maxY - rect.height * normalizedY - height
            return CGRect(
                x: rect.midX - width / 2,
                y: y,
                width: width,
                height: height
            )
        }
    }
}

enum TopsideIcon {
    static func appIconImage(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

        drawGlyph(in: rect.insetBy(dx: size * 0.18, dy: size * 0.24), color: .white)
        return image
    }

    static func statusBarImage(attentionColor: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 22, height: 22).fill()

        drawGlyph(
            in: NSRect(x: 2, y: 4, width: 18, height: 14),
            color: attentionColor ?? .labelColor
        )

        image.isTemplate = attentionColor == nil
        return image
    }

    static func stateColor(for state: SessionState) -> NSColor {
        switch state {
        case .running:
            NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.04, alpha: 1)
        case .done:
            NSColor(calibratedRed: 0.10, green: 0.96, blue: 0.40, alpha: 1)
        case .failed:
            NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.18, alpha: 1)
        case .cancelled:
            NSColor.secondaryLabelColor
        case .waitingForInput:
            NSColor(calibratedRed: 0.18, green: 0.74, blue: 1.0, alpha: 1)
        case .waitingForPermission:
            NSColor(calibratedRed: 1.0, green: 0.06, blue: 0.16, alpha: 1)
        case .unknown:
            NSColor.systemBlue
        }
    }

    static func markRects(in rect: CGRect) -> [CGRect] {
        TopsideMarkGeometry.rects(in: rect, originAtTop: true)
    }

    private static func drawGlyph(in rect: NSRect, color: NSColor) {
        color.setFill()
        for capsule in TopsideMarkGeometry.rects(in: rect, originAtTop: false) {
            NSBezierPath(
                roundedRect: capsule,
                xRadius: capsule.height / 2,
                yRadius: capsule.height / 2
            ).fill()
        }
    }
}
