import AtollCore
import AppKit
import SwiftUI

struct AgentGlyphView: View {
    let harness: AgentHarness
    var glyphColor: Color = .white

    var body: some View {
        Group {
            if let icon = AgentIconLibrary.image(for: harness) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(iconPadding)
                    .accessibilityHidden(true)
            } else {
                fallbackGlyph
            }
        }
    }

    private var iconPadding: CGFloat {
        switch harness {
        case .deepseek, .droid, .hermes, .qoder:
            1.8
        case .opencode, .amp, .pi:
            1.2
        default:
            1.5
        }
    }

    @ViewBuilder
    private var fallbackGlyph: some View {
        switch harness {
        case .opencode:
            OpenCodeGlyph()
                .stroke(glyphColor, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .padding(5)
        case .codex:
            CodexGlyph()
                .stroke(glyphColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .padding(5)
        case .claude:
            ClaudeCrabGlyph()
                .fill(glyphColor)
                .padding(4)
        case .gemini, .cursor, .droid, .qoder, .qwen, .kimi, .deepseek, .codebuddy, .kiro, .hermes, .amp:
            Text(harness.shortName)
                .font(.system(size: 8.5, weight: .black, design: .rounded))
                .foregroundStyle(glyphColor)
        case .copilot:
            CopilotGlyph()
                .stroke(glyphColor, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(5)
        case .pi:
            PiGlyph()
                .stroke(glyphColor, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(3.8)
        case .atoll:
            AtollGlyph()
                .stroke(glyphColor, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(5)
        }
    }

}

private enum AgentIconLibrary {
    private static let bundleName = "Atoll_Atoll.bundle"

    static func image(for harness: AgentHarness) -> NSImage? {
        guard let fileName = iconFileName(for: harness),
              let image = directIconImage(for: fileName) ?? bundleIconImage(fileName: fileName) else {
            return nil
        }

        image.isTemplate = false
        return image
    }

    private static func directIconImage(for fileName: String) -> NSImage? {
        if let moduleResource = Bundle.module.url(forResource: fileName, withExtension: "svg", subdirectory: "AgentIcons"),
           let image = NSImage(contentsOf: moduleResource) {
            return image
        }

        if let directResource = Bundle.main.url(forResource: fileName, withExtension: "svg", subdirectory: "AgentIcons"),
           let image = NSImage(contentsOf: directResource) {
            return image
        }

        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }

        let directPaths = [
            executableDirectory.appendingPathComponent("Resources/AgentIcons/\(fileName).svg"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/AgentIcons/\(fileName).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("AgentIcons/\(fileName).svg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AgentIcons/\(fileName).svg")
        ]

        return directPaths
            .compactMap { $0 }
            .compactMap { NSImage(contentsOf: $0) }
            .first
    }

    private static func bundleIconImage(fileName: String) -> NSImage? {
        guard let url = resourceBundles
            .lazy
            .compactMap({ $0.url(forResource: fileName, withExtension: "svg") })
            .first else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func iconFileName(for harness: AgentHarness) -> String? {
        switch harness {
        case .opencode:
            "opencode"
        case .codex:
            "codex"
        case .claude:
            "claude"
        case .gemini:
            "gemini"
        case .cursor:
            "cursor"
        case .droid:
            "droid"
        case .qoder:
            "qoder"
        case .qwen:
            "qwen"
        case .kimi:
            "kimi"
        case .deepseek:
            "deepseek"
        case .copilot:
            "copilot"
        case .codebuddy:
            "codebuddy"
        case .kiro:
            "kiro"
        case .hermes:
            "hermes"
        case .amp:
            "amp"
        case .pi:
            "pi"
        case .atoll:
            nil
        }
    }

    private static var resourceBundles: [Bundle] {
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            executableDirectory?.appendingPathComponent(bundleName),
            executableDirectory?
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent(bundleName)
        ]

        return candidates.compactMap { url in
            guard let url else { return nil }
            return Bundle(url: url)
        }
    }
}

private struct OpenCodeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.43, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.43, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX * 0.57, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.57, y: rect.maxY))
        return path
    }
}

private struct CodexGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.34
        for index in 0..<3 {
            let angle = CGFloat(index) * .pi * 2 / 3
            let start = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let end = CGPoint(x: center.x + cos(angle + .pi * 0.84) * radius, y: center.y + sin(angle + .pi * 0.84) * radius)
            path.move(to: start)
            path.addQuadCurve(to: end, control: center)
        }
        return path
    }
}

private struct ClaudeCrabGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.34, width: rect.width * 0.56, height: rect.height * 0.40)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: body.height * 0.45, height: body.height * 0.45))

        let leftClaw = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.12, width: rect.width * 0.30, height: rect.height * 0.28)
        let rightClaw = CGRect(x: rect.maxX - rect.width * 0.30, y: leftClaw.minY, width: rect.width * 0.30, height: rect.height * 0.28)
        path.addEllipse(in: leftClaw)
        path.addEllipse(in: rightClaw)

        path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.18, width: rect.width * 0.12, height: rect.height * 0.18))
        path.addEllipse(in: CGRect(x: rect.maxX - rect.width * 0.44, y: rect.minY + rect.height * 0.18, width: rect.width * 0.12, height: rect.height * 0.18))
        return path
    }
}

private struct CopilotGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = CGRect(x: rect.minX, y: rect.midY - rect.height * 0.20, width: rect.width * 0.42, height: rect.height * 0.40)
        let right = CGRect(x: rect.maxX - rect.width * 0.42, y: left.minY, width: rect.width * 0.42, height: left.height)
        path.addRoundedRect(in: left, cornerSize: CGSize(width: left.height * 0.4, height: left.height * 0.4))
        path.addRoundedRect(in: right, cornerSize: CGSize(width: right.height * 0.4, height: right.height * 0.4))
        path.move(to: CGPoint(x: left.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: right.minX, y: rect.midY))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.26))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.minY + rect.height * 0.26), control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private struct PiGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width * 0.45
        let radius = rect.width * 0.06
        let leftX = rect.midX - width
        let rightX = rect.midX + width - rect.width * 0.12
        let topY = rect.minY + rect.height * 0.08

        path.addRoundedRect(
            in: CGRect(
                x: leftX,
                y: topY,
                width: rect.width * 0.12,
                height: rect.height * 0.84
            ),
            cornerSize: CGSize(width: radius, height: radius)
        )

        path.addRoundedRect(
            in: CGRect(
                x: rightX,
                y: topY,
                width: rect.width * 0.12,
                height: rect.height * 0.84
            ),
            cornerSize: CGSize(width: radius, height: radius)
        )

        path.move(to: CGPoint(x: leftX + rect.width * 0.06, y: rect.midY + rect.height * 0.03))
        path.addLine(to: CGPoint(x: rightX + rect.width * 0.06, y: rect.midY + rect.height * 0.03))
        return path
    }
}

private struct AtollGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.24))
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.33, dy: rect.height * 0.38))
        return path
    }
}
