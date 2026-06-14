import AtollCore
import SwiftUI

struct AgentGlyphView: View {
    let harness: AgentHarness

    var body: some View {
        ZStack {
            Circle()
                .fill(baseColor)

            switch harness {
            case .opencode:
                OpenCodeGlyph()
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    .padding(5)
            case .codex:
                CodexGlyph()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .padding(5)
            case .claude:
                ClaudeCrabGlyph()
                    .fill(.white)
                    .padding(4)
            case .copilot:
                CopilotGlyph()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .padding(5)
            case .pi:
                Text("pi")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            case .atoll:
                AtollGlyph()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                    .padding(5)
            }
        }
        .overlay {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var baseColor: Color {
        switch harness {
        case .opencode:
            Color(red: 0.10, green: 0.68, blue: 0.50)
        case .codex:
            Color(red: 0.35, green: 0.49, blue: 0.95)
        case .claude:
            Color(red: 0.88, green: 0.38, blue: 0.20)
        case .copilot:
            Color(red: 0.23, green: 0.72, blue: 0.36)
        case .pi:
            Color(red: 0.62, green: 0.46, blue: 0.91)
        case .atoll:
            Color(red: 0.12, green: 0.58, blue: 0.78)
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

private struct AtollGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.24))
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.33, dy: rect.height * 0.38))
        return path
    }
}
