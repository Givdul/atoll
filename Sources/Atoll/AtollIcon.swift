import AppKit
import AtollCore

enum AtollIcon {
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

        let stroke = attentionColor ?? NSColor.labelColor
        drawGlyph(in: NSRect(x: 3.5, y: 5.5, width: 15, height: 11), color: stroke)

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

    private static func drawGlyph(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()

        path.move(to: point(0.50, 0.96, in: rect))
        path.curve(to: point(0.91, 0.67, in: rect), controlPoint1: point(0.70, 0.96, in: rect), controlPoint2: point(0.86, 0.84, in: rect))
        path.curve(to: point(0.83, 0.27, in: rect), controlPoint1: point(0.95, 0.51, in: rect), controlPoint2: point(0.93, 0.36, in: rect))
        path.curve(to: point(0.50, 0.08, in: rect), controlPoint1: point(0.74, 0.16, in: rect), controlPoint2: point(0.62, 0.10, in: rect))
        path.curve(to: point(0.13, 0.28, in: rect), controlPoint1: point(0.35, 0.05, in: rect), controlPoint2: point(0.20, 0.13, in: rect))
        path.curve(to: point(0.09, 0.67, in: rect), controlPoint1: point(0.05, 0.42, in: rect), controlPoint2: point(0.05, 0.56, in: rect))
        path.curve(to: point(0.50, 0.96, in: rect), controlPoint1: point(0.14, 0.84, in: rect), controlPoint2: point(0.30, 0.96, in: rect))
        path.close()

        path.move(to: point(0.50, 0.72, in: rect))
        path.curve(to: point(0.67, 0.58, in: rect), controlPoint1: point(0.58, 0.72, in: rect), controlPoint2: point(0.65, 0.66, in: rect))
        path.curve(to: point(0.61, 0.39, in: rect), controlPoint1: point(0.69, 0.50, in: rect), controlPoint2: point(0.66, 0.43, in: rect))
        path.curve(to: point(0.48, 0.34, in: rect), controlPoint1: point(0.57, 0.35, in: rect), controlPoint2: point(0.52, 0.34, in: rect))
        path.curve(to: point(0.32, 0.47, in: rect), controlPoint1: point(0.41, 0.34, in: rect), controlPoint2: point(0.35, 0.38, in: rect))
        path.curve(to: point(0.37, 0.65, in: rect), controlPoint1: point(0.30, 0.54, in: rect), controlPoint2: point(0.32, 0.61, in: rect))
        path.curve(to: point(0.50, 0.72, in: rect), controlPoint1: point(0.40, 0.69, in: rect), controlPoint2: point(0.45, 0.72, in: rect))
        path.close()

        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}
