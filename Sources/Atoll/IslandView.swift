import AtollCore
import AppKit
import SwiftUI

struct IslandMetrics {
    var scale: CGFloat
    var rowWidth: CGFloat
    var rowHeight: CGFloat
    var horizontalPadding: CGFloat
    var iconSize: CGFloat
    var titleFontSize: CGFloat
    var detailFontSize: CGFloat
    var cornerRadius: CGFloat
    var topGap: CGFloat
    var rowSpacing: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    init() {
        let baseNotchHeight = Self.screenTopReservedHeight()
        let factor = min(1.08, max(0.88, baseNotchHeight / 32))
        scale = factor
        rowWidth = 360 * factor
        rowHeight = max(32, min(36, baseNotchHeight * 0.92))
        horizontalPadding = 8 * factor
        iconSize = rowHeight - 8 * factor
        titleFontSize = min(12 * factor, rowHeight * 0.38)
        detailFontSize = min(11 * factor, rowHeight * 0.34)
        cornerRadius = rowHeight * 0.50
        topGap = 0
        rowSpacing = 4 * factor
        notchWidth = 188 * factor
        notchHeight = max(32, min(38, baseNotchHeight + 2 * factor))
    }

    private static func screenTopReservedHeight() -> CGFloat {
        guard let screen = NSScreen.screens.first else {
            return 30
        }

        let safeTop = screen.safeAreaInsets.top
        let visibleTopInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let measured = safeTop > 0 ? safeTop : visibleTopInset
        return max(28, min(44, measured > 0 ? measured : 30))
    }
}

struct IslandView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    @State private var isIslandHover = false

    var body: some View {
        let metrics = IslandMetrics()
        let visibleSessions = state.visibleSessions

        ZStack(alignment: .top) {
            islandStack(metrics: metrics, sessions: visibleSessions)
        }
        .frame(width: 440, height: 340, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private func islandStack(
        metrics: IslandMetrics,
        sessions: [AgentSession]
    ) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: metrics.rowSpacing * 1.5) {
                islandContent(metrics: metrics, sessions: sessions)
            }
        } else {
            islandContent(metrics: metrics, sessions: sessions)
        }
    }

    private func islandContent(
        metrics: IslandMetrics,
        sessions: [AgentSession]
    ) -> some View {
        VStack(spacing: metrics.rowSpacing) {
            NotchActivityBorder(
                isActive: sessions.contains { $0.state == .running },
                needsAttention: sessions.contains { $0.state == .waitingForInput || $0.state == .waitingForPermission },
                metrics: metrics,
                glassNamespace: glassNamespace
            )
            .onHover { hovering in
                guard hovering else {
                    return
                }

                withOptionalAnimation {
                    isIslandHover = true
                }
            }
            .zIndex(10)

            if isIslandHover {
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(sessions) { session in
                        SessionBubbleRow(
                            session: session,
                            metrics: metrics,
                            animatedIcon: session.state == .running
                                || session.state == .waitingForInput
                                || session.state == .waitingForPermission,
                            glassID: "row-\(session.id)",
                            glassNamespace: glassNamespace
                        )
                        .transition(rowTransition(metrics: metrics))
                    }
                }
                .transition(rowTransition(metrics: metrics))
            }
        }
        .padding(.top, metrics.topGap)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !hovering, isIslandHover else {
                return
            }

            withOptionalAnimation {
                isIslandHover = false
            }
        }
        .animation(rowAnimation, value: isIslandHover)
        .animation(rowAnimation, value: sessions.map(\.id))
    }

    private struct NotchActivityBorder: View {
        let isActive: Bool
        let needsAttention: Bool
        let metrics: IslandMetrics
        let glassNamespace: Namespace.ID
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            if #available(macOS 26.0, *) {
                border
                    .glassEffectID("notch-activity-border", in: glassNamespace)
            } else {
                border
            }
        }

        private var border: some View {
            ZStack {
                notchShape
                    .fill(.black.opacity(0.96))

                notchShape
                    .stroke(.black.opacity(0.94), lineWidth: 2.2 * metrics.scale)

                notchShape
                    .stroke(.white.opacity(0.16), lineWidth: 0.8 * metrics.scale)
                    .blendMode(.screen)

                if isActive || needsAttention {
                    ActivityDotTrail(metrics: metrics, color: activityColor, reduceMotion: reduceMotion)
                        .clipShape(notchShape)
                }
            }
            .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            .contentShape(notchShape)
        }

        private var notchShape: MacNotchShape {
            MacNotchShape(cornerRadius: metrics.notchHeight * 0.46)
        }

        private var activityColor: Color {
            if needsAttention {
                return .orange
            }
            return Color(red: 0.34, green: 0.62, blue: 1.0)
        }
    }

    private struct ActivityDotTrail: View {
        let metrics: IslandMetrics
        let color: Color
        let reduceMotion: Bool

        var body: some View {
            TimelineView(.animation) { timeline in
                let motion = reduceMotion ? (position: 0.5, direction: 1.0) : pingPong(timeline.date.timeIntervalSinceReferenceDate * 0.42)

                ZStack {
                    ForEach(1..<42, id: \.self) { index in
                        let fraction = CGFloat(index) / 41
                        let trailPosition = reflected(motion.position - motion.direction * fraction * 0.18)
                        let point = pointOnNotchEdge(progress: trailPosition)
                        let opacity = pow(1 - fraction, 1.85) * 0.48

                        Capsule()
                            .fill(color.opacity(opacity))
                            .frame(
                                width: 7.4 * metrics.scale,
                                height: 4.2 * metrics.scale
                            )
                            .offset(x: point.x, y: point.y)
                    }

                    let point = pointOnNotchEdge(progress: motion.position)
                    RoundedRectangle(cornerRadius: 2.5 * metrics.scale, style: .continuous)
                        .fill(color)
                        .frame(width: 10 * metrics.scale, height: 10 * metrics.scale)
                        .shadow(color: color.opacity(0.75), radius: 6 * metrics.scale)
                        .offset(x: point.x, y: point.y)
                }
                .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            }
        }

        private func pingPong(_ value: TimeInterval) -> (position: CGFloat, direction: CGFloat) {
            let phase = value.truncatingRemainder(dividingBy: 2)
            let raw = CGFloat(phase <= 1 ? phase : 2 - phase)
            let eased = raw * raw * (3 - 2 * raw)
            if phase <= 1 {
                return (eased, 1)
            }
            return (eased, -1)
        }

        private func reflected(_ value: CGFloat) -> CGFloat {
            var phase = value.truncatingRemainder(dividingBy: 2)
            if phase < 0 {
                phase += 2
            }
            return phase <= 1 ? phase : 2 - phase
        }

        private func pointOnNotchEdge(progress: CGFloat) -> CGPoint {
            let width = metrics.notchWidth
            let height = metrics.notchHeight
            let radius = min(height * 0.48, width / 2, height)
            let verticalLength = max(0, height - radius)
            let arcLength = (.pi / 2) * radius
            let bottomLength = max(1, width - radius * 2)
            let totalLength = verticalLength * 2 + arcLength * 2 + bottomLength
            let distance = clamped(progress) * totalLength

            let local: CGPoint
            if distance < verticalLength {
                local = CGPoint(
                    x: 0,
                    y: distance
                )
            } else if distance < verticalLength + arcLength {
                let arcDistance = distance - verticalLength
                let angle = .pi - (arcDistance / arcLength) * (.pi / 2)
                local = CGPoint(
                    x: radius + cos(angle) * radius,
                    y: height - radius + sin(angle) * radius
                )
            } else if distance < verticalLength + arcLength + bottomLength {
                local = CGPoint(
                    x: radius + distance - verticalLength - arcLength,
                    y: height
                )
            } else if distance < verticalLength + arcLength * 2 + bottomLength {
                let arcDistance = distance - verticalLength - arcLength - bottomLength
                let angle = (.pi / 2) - (arcDistance / arcLength) * (.pi / 2)
                local = CGPoint(
                    x: width - radius + cos(angle) * radius,
                    y: height - radius + sin(angle) * radius
                )
            } else {
                let sideDistance = distance - verticalLength - arcLength * 2 - bottomLength
                local = CGPoint(
                    x: width,
                    y: height - radius - sideDistance
                )
            }

            return CGPoint(
                x: local.x - width / 2,
                y: local.y - height / 2
            )
        }

        private func clamped(_ value: CGFloat) -> CGFloat {
            min(1, max(0, value))
        }
    }

    private var rowAnimation: Animation? {
        guard !reduceMotion else {
            return nil
        }
        return .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    }

    private func rowTransition(metrics: IslandMetrics) -> AnyTransition {
        guard !reduceMotion else {
            return .identity
        }

        let verticalTravel = max(28, metrics.rowHeight * 0.9)
        return .asymmetric(
            insertion: .offset(y: -verticalTravel).combined(with: .opacity),
            removal: .offset(y: -verticalTravel).combined(with: .opacity)
        )
    }

    private func withOptionalAnimation(_ changes: @escaping () -> Void) {
        if let rowAnimation {
            withAnimation(rowAnimation, changes)
        } else {
            changes()
        }
    }
}

private struct MacNotchShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()

        return path
    }
}

private struct SessionBubbleRow: View {
    let session: AgentSession
    let metrics: IslandMetrics
    let animatedIcon: Bool
    let glassID: String
    let glassNamespace: Namespace.ID

    var body: some View {
        if #available(macOS 26.0, *) {
            rowContent
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                .contentShape(rowShape)
                .glassEffect(.regular.tint(statusGlassTint).interactive(), in: rowShape)
                .glassEffectID(glassID, in: glassNamespace)
                .shadow(color: .black.opacity(0.10), radius: 7 * metrics.scale, x: 0, y: 4 * metrics.scale)
        } else {
            rowContent
                .padding(.horizontal, metrics.horizontalPadding)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                .background {
                    rowShape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            rowShape
                                .fill(Color.black.opacity(0.26))
                        }
                        .overlay {
                            rowShape
                                .fill(rowTint)
                        }
                }
                .glassStroke(rowShape, tint: strokeTint, lineWidth: 1)
                .shadow(color: .black.opacity(0.18), radius: 8 * metrics.scale, x: 0, y: 4 * metrics.scale)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8 * metrics.scale) {
            HarnessOrbView(harness: session.harness, metrics: metrics, animated: animatedIcon)

            Text(session.title)
                .font(.system(size: metrics.titleFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(titleForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(statusText)
                .font(.system(size: metrics.detailFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(detailForeground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    private var titleForeground: Color {
        if #available(macOS 26.0, *) {
            .primary
        } else {
            .white.opacity(0.94)
        }
    }

    private var detailForeground: Color {
        if #available(macOS 26.0, *) {
            .secondary
        } else {
            .white.opacity(0.84)
        }
    }

    private var statusGlassTint: Color {
        switch session.state {
        case .waitingForPermission:
            .orange.opacity(0.12)
        case .waitingForInput:
            Color(red: 0.25, green: 0.64, blue: 1.0).opacity(0.11)
        case .done:
            .green.opacity(0.08)
        case .running:
            Color(red: 0.38, green: 0.75, blue: 1.0).opacity(0.09)
        case .unknown:
            .white.opacity(0.04)
        }
    }

    private var rowTint: LinearGradient {
        LinearGradient(
            colors: [
                statusColor.opacity(0.16),
                .white.opacity(0.10),
                .black.opacity(0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var strokeTint: Color {
        switch session.state {
        case .waitingForPermission:
            .orange.opacity(0.70)
        case .waitingForInput:
            Color(red: 0.25, green: 0.64, blue: 1.0).opacity(0.70)
        case .done:
            .green.opacity(0.55)
        case .running:
            .white.opacity(0.38)
        case .unknown:
            .white.opacity(0.28)
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .waitingForPermission:
            .orange
        case .waitingForInput:
            Color(red: 0.25, green: 0.64, blue: 1.0)
        case .done:
            .green
        case .running:
            Color(red: 0.38, green: 0.75, blue: 1.0)
        case .unknown:
            .white
        }
    }

    private var statusText: String {
        switch session.state {
        case .running:
            "Working"
        case .done:
            "Done"
        case .waitingForInput:
            "Needs input"
        case .waitingForPermission:
            "Needs permission"
        case .unknown:
            "Unknown"
        }
    }
}
private struct HarnessOrbView: View {
    let harness: AgentHarness
    let metrics: IslandMetrics
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AgentGlyphView(harness: harness)
                .frame(width: metrics.iconSize, height: metrics.iconSize)

            TimelineView(.animation) { timeline in
                let angle = animated && !reduceMotion
                    ? timeline.date.timeIntervalSinceReferenceDate * 120
                    : 0

                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                harnessColor.opacity(0.15),
                                harnessColor,
                                .white.opacity(0.88),
                                harnessColor.opacity(0.15)
                            ],
                            center: .center
                        ),
                        lineWidth: 2 * metrics.scale
                    )
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: metrics.iconSize, height: metrics.iconSize)
    }

    private var harnessColor: Color {
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

private extension View {
    func glassStroke<S: Shape>(_ shape: S, tint: Color, lineWidth: CGFloat) -> some View {
        overlay {
            shape
                .stroke(.white.opacity(0.42), lineWidth: lineWidth)
                .blendMode(.screen)
        }
        .overlay {
            shape
                .stroke(tint, lineWidth: max(1, lineWidth))
        }
    }
}
