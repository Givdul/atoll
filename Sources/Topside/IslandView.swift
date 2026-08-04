import TopsideCore
import AppKit
import SwiftUI

private enum SessionStateColor {
    static let working = Color(red: 1.00, green: 0.52, blue: 0.10)
    static let question = Color(red: 0.22, green: 0.78, blue: 1.00)
    static let permission = Color(red: 1.00, green: 0.20, blue: 0.29)
    static let done = Color(red: 0.22, green: 0.95, blue: 0.42)
    static let failed = Color(red: 1.00, green: 0.20, blue: 0.29)
    static let cancelled = Color.white.opacity(0.52)

    static func accent(for state: SessionState) -> Color {
        switch state {
        case .running:
            working
        case .waitingForInput:
            question
        case .waitingForPermission:
            permission
        case .done:
            done
        case .failed:
            failed
        case .cancelled:
            cancelled
        case .unknown:
            .white.opacity(0.52)
        }
    }
}

struct IslandView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    @State private var isListMounted = false
    @State private var listUnmountGeneration = 0

    @ViewBuilder
    var body: some View {
        if let layout = state.presentation.layout {
            let hasFloatingTerminalRows = !state.presentation.floatingTerminalSessions.isEmpty

            ZStack(alignment: .top) {
                islandContent(layout: layout)
            }
            .frame(
                width: layout.hostFrame.width,
                height: layout.hostFrame.height,
                alignment: .top
            )
            .clipped()
            .onAppear {
                if state.islandHoverState.expandsList || hasFloatingTerminalRows {
                    isListMounted = true
                }
            }
            .onChange(of: hasFloatingTerminalRows) { _, hasFloatingTerminalRows in
                if hasFloatingTerminalRows {
                    showList()
                } else if !state.islandHoverState.expandsList {
                    scheduleListUnmount()
                }
            }
            .onChange(of: state.islandHoverState) { _, hoverState in
                if hoverState.expandsList {
                    showList()
                } else {
                    scheduleListUnmount()
                }
            }
        } else {
            Color.clear.frame(
                width: IslandMetrics.hostSize.width,
                height: IslandMetrics.hostSize.height
            )
        }
    }

    private func islandContent(layout: IslandPresentationLayout) -> some View {
        let metrics = layout.metrics
        let rowSessions = state.presentation.displayedRegularSessions
        let pinnedSessions = state.presentation.attentionSessions
        let showsRows = state.islandHoverState.expandsList || !rowSessions.isEmpty
        let attentionOpacity = state.islandHoverState.dimsAttentionRows ? 0.30 : 1.0

        return VStack(spacing: metrics.rowSpacing) {
            NotchActivityBorder(
                activityState: state.presentation.activityState,
                metrics: metrics,
                glassNamespace: glassNamespace
            )
            .offset(x: IslandMetrics.opticalHorizontalOffset)
            .allowsHitTesting(false)
            .zIndex(10)

            if isListMounted, !rowSessions.isEmpty {
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(rowSessions) { session in
                        SessionBubbleRow(
                            session: session,
                            metrics: metrics,
                            glassID: "row-\(session.id)",
                            glassNamespace: glassNamespace
                        )
                        .transition(terminalRowTransition)
                    }
                }
                .frame(
                    height: showsRows
                        ? layout.regularSectionBounds?.height ?? 0
                        : 0,
                    alignment: .top
                )
                .opacity(showsRows ? 1 : 0)
                .clipped()
            }

            if !pinnedSessions.isEmpty {
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(pinnedSessions) { session in
                        SessionBubbleRow(
                            session: session,
                            metrics: metrics,
                            glassID: "attention-row-\(session.id)",
                            glassNamespace: glassNamespace
                        )
                    }
                }
                .opacity(attentionOpacity)
                .animation(
                    attentionFadeAnimation(dimmed: state.islandHoverState.dimsAttentionRows),
                    value: state.islandHoverState.dimsAttentionRows
                )
            }
        }
        .padding(.top, metrics.topGap)
        .animation(listRevealAnimation, value: state.islandHoverState)
        .animation(
            rowAnimation,
            value: state.presentation.displayedSessions.map { [$0.id, $0.state.rawValue, $0.taskLabel ?? ""].joined(separator: ":") }
        )
    }

    private struct NotchActivityBorder: View {
        let activityState: SessionState?
        let metrics: IslandMetrics
        let glassNamespace: Namespace.ID
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var waitingBorderWidth: CGFloat {
            max(4.8 * metrics.scale, metrics.notchHeight * 0.24)
        }

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
                    .fill(.black)
                    .overlay {
                        notchShape
                            .stroke(.white.opacity(0.08), lineWidth: 0.8 * metrics.scale)
                    }

                if let activityState {
                    switch activityState {
                    case .running:
                        ActivityDotTrail(
                            metrics: metrics,
                            color: SessionStateColor.accent(for: activityState),
                            reduceMotion: reduceMotion,
                            topClearance: topColorClearance
                            )
                            .mask(notchColoredRegion)
                    case .waitingForInput, .waitingForPermission:
                        notchColoredEdgeShape
                            .stroke(
                                SessionStateColor.accent(for: activityState).opacity(0.74),
                                style: StrokeStyle(lineWidth: waitingBorderWidth, lineCap: .butt, lineJoin: .round)
                            )
                            .mask(notchColoredRegion)
                    case .done, .failed, .cancelled, .unknown:
                        EmptyView()
                    }
                }
            }
            .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            .contentShape(notchShape)
        }

        private var notchShape: MacNotchShape {
            MacNotchShape(cornerRadius: metrics.notchHeight * 0.46)
        }

        private var notchColoredEdgeShape: MacNotchColoredEdgeShape {
            MacNotchColoredEdgeShape(cornerRadius: metrics.notchHeight * 0.46, topClearance: topColorClearance)
        }

        private var notchColoredRegion: MacNotchColoredRegion {
            MacNotchColoredRegion(cornerRadius: metrics.notchHeight * 0.46, topClearance: topColorClearance)
        }

        private var topColorClearance: CGFloat {
            max(2, 2 * metrics.scale)
        }
    }

    private struct ActivityDotTrail: View {
        let metrics: IslandMetrics
        let color: Color
        let reduceMotion: Bool
        let topClearance: CGFloat

        var body: some View {
            TimelineView(.animation) { timeline in
                let motion = reduceMotion ? (position: 0.5, direction: 1.0) : pingPong(timeline.date.timeIntervalSinceReferenceDate * 0.42)
                let dotSize = 10 * metrics.scale
                let edgeClearance = topClearance + dotSize / 2

                ZStack {
                    ForEach(1..<24, id: \.self) { index in
                        let fraction = CGFloat(index) / 23
                        let trailPosition = reflected(motion.position - motion.direction * fraction * 0.18)
                        let point = pointOnNotchEdge(progress: trailPosition, topClearance: edgeClearance)
                        let opacity = pow(1 - fraction, 1.85) * 0.48

                        RoundedRectangle(cornerRadius: dotSize * 0.25, style: .continuous)
                            .fill(color.opacity(opacity))
                            .frame(width: dotSize, height: dotSize)
                            .offset(x: point.x, y: point.y)
                    }

                    let point = pointOnNotchEdge(progress: motion.position, topClearance: edgeClearance)
                    RoundedRectangle(cornerRadius: dotSize * 0.25, style: .continuous)
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
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

        private func pointOnNotchEdge(progress: CGFloat, topClearance: CGFloat) -> CGPoint {
            let width = metrics.notchWidth
            let height = metrics.notchHeight
            let radius = min(height * 0.48, width / 2, height)
            let edgeTopY = min(height - radius, max(0, topClearance))
            let verticalLength = max(0, height - radius - edgeTopY)
            let arcLength = (.pi / 2) * radius
            let bottomLength = max(1, width - radius * 2)
            let totalLength = verticalLength * 2 + arcLength * 2 + bottomLength
            let distance = clamped(progress) * totalLength

            let local: CGPoint
            if distance < verticalLength {
                local = CGPoint(
                    x: 0,
                    y: edgeTopY + distance
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

    private var terminalRowTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .offset(y: -18).combined(with: .opacity)
        )
    }

    private var listRevealAnimation: Animation? {
        guard !reduceMotion else {
            return nil
        }

        return .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    }

    private func attentionFadeAnimation(dimmed: Bool) -> Animation? {
        guard !reduceMotion else {
            return nil
        }

        let base = Animation.easeInOut(duration: 0.18)
        return dimmed ? base.delay(0.2) : base
    }

    private func showList() {
        listUnmountGeneration &+= 1
        guard !isListMounted else {
            return
        }

        isListMounted = true
    }

    private func scheduleListUnmount() {
        listUnmountGeneration &+= 1
        let generation = listUnmountGeneration

        let canUnmount = {
            generation == listUnmountGeneration
                && !state.islandHoverState.expandsList
                && !state.visibleSessions.contains(where: { $0.state.isTerminal })
        }

        guard !reduceMotion else {
            if canUnmount() {
                isListMounted = false
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard canUnmount() else { return }

            isListMounted = false
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

private struct MacNotchColoredEdgeShape: Shape {
    let cornerRadius: CGFloat
    let topClearance: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        let topY = min(rect.maxY - radius, rect.minY + max(0, topClearance))
        var path = Path()

        path.move(to: CGPoint(x: rect.maxX, y: topY))
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
        path.addLine(to: CGPoint(x: rect.minX, y: topY))

        return path
    }
}

private struct MacNotchColoredRegion: Shape {
    let cornerRadius: CGFloat
    let topClearance: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        let topY = min(rect.maxY - radius, rect.minY + max(0, topClearance))
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topY))
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
    let glassID: String
    let glassNamespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if session.originProcessID != nil, session.originBundleIdentifier != nil {
            Button(action: openOriginatingApplication) {
                decoratedRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rowAccessibilityLabel)
        } else {
            decoratedRow
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var decoratedRow: some View {
        if #available(macOS 26.0, *) {
            rowContent
                .padding(.leading, metrics.horizontalPadding)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                .background {
                    liquidGlassRowDecoration
                }
                .contentShape(rowShape)
                .glassEffect(.regular.tint(Color.black.opacity(0.96)), in: rowShape)
                .glassEffectID(glassID, in: glassNamespace)
                .overlay {
                    RowActivityBorder(
                        state: session.state,
                        color: appearance.accent,
                        metrics: metrics,
                        animated: session.state == .running,
                        reduceMotion: reduceMotion
                    )
                }
        } else {
            rowContent
                .padding(.leading, metrics.horizontalPadding)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                .background {
                    fallbackRowDecoration
                }
                .contentShape(rowShape)
                .overlay {
                    RowActivityBorder(
                        state: session.state,
                        color: appearance.accent,
                        metrics: metrics,
                        animated: session.state == .running,
                        reduceMotion: reduceMotion
                    )
                }
        }
    }

    private func openOriginatingApplication() {
        guard let processID = session.originProcessID,
              let bundleIdentifier = session.originBundleIdentifier else {
            return
        }

        if let application = NSRunningApplication(processIdentifier: processID),
           application.bundleIdentifier == bundleIdentifier {
            application.activate(options: [.activateAllWindows])
            return
        }

        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            application.activate(options: [.activateAllWindows])
            return
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    private var rowContent: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 9 * metrics.scale) {
                iconWell

                Text(session.presentationLabel)
                    .font(.system(size: metrics.titleFontSize, weight: appearance.titleWeight, design: .rounded))
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 1 * metrics.scale)
                    .padding(.trailing, statusSegmentWidth + 12 * metrics.scale)
            }

            HStack(spacing: 5 * metrics.scale) {
                statusIconView

                elapsedTimerView
                    .foregroundStyle(statusAccent.opacity(0.94))
            }
            .frame(width: statusSegmentWidth, height: metrics.rowHeight)
        }
    }

    private var iconWell: some View {
        HarnessOrbView(
            harness: session.harness,
            metrics: metrics,
            appearance: appearance
        )
        .frame(width: metrics.rowHeight - 4 * metrics.scale, height: metrics.rowHeight - 4 * metrics.scale)
    }

    private var elapsedTimerView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(formattedElapsed(at: timeline.date))
                .font(.system(size: max(10, metrics.detailFontSize - 0.45 * metrics.scale), weight: .heavy, design: .monospaced))
                .frame(width: 28 * metrics.scale, height: metrics.rowHeight, alignment: .center)
        }
    }

    private var statusIconView: some View {
        Image(systemName: statusSymbolName)
            .font(.system(size: metrics.detailFontSize + 0.65 * metrics.scale, weight: .black, design: .rounded))
            .foregroundStyle(statusAccent)
            .frame(width: 14 * metrics.scale, height: metrics.rowHeight, alignment: .center)
    }

    private var liquidGlassRowDecoration: some View {
        rowShape
            .fill(Color.black)
            .overlay {
                rowShape
                    .fill(rowTintSweep)
                    .blendMode(.screen)
            }
            .overlay {
                if session.state != .running {
                    rowShape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    appearance.accent.opacity(0.98),
                                    .white.opacity(0.12),
                                    appearance.accent.opacity(0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2 * metrics.scale
                        )
                        .blendMode(.screen)
                }
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 4 * metrics.scale, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .frame(width: metrics.rowWidth * 0.56, height: max(1, 1.3 * metrics.scale))
                    .blur(radius: 1.8 * metrics.scale)
                    .offset(y: 1.3 * metrics.scale)
            }
            .overlay(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: metrics.rowHeight * 0.22, style: .continuous)
                    .fill(.white.opacity(0.045))
                    .frame(width: metrics.rowWidth * 0.34, height: metrics.rowHeight * 0.32)
                    .blur(radius: 11 * metrics.scale)
                    .offset(x: -20 * metrics.scale, y: 6 * metrics.scale)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: metrics.rowHeight * 0.18, style: .continuous)
                    .fill(.white.opacity(0.025))
                    .frame(width: metrics.rowWidth * 0.24, height: metrics.rowHeight * 0.72)
                    .blur(radius: 10 * metrics.scale)
                    .offset(x: 18 * metrics.scale)
            }
            .overlay {
                if session.state != .running {
                    rowShape
                        .stroke(.black.opacity(0.42), lineWidth: 0.8 * metrics.scale)
                }
            }
    }

    private var fallbackRowDecoration: some View {
        rowShape
            .fill(Color.black)
            .overlay {
                rowShape
                    .fill(rowTintSweep.opacity(0.66))
            }
            .overlay {
                if session.state != .running {
                    rowShape
                        .stroke(appearance.accent.opacity(0.78), lineWidth: 1.1 * metrics.scale)
                }
            }
            .overlay {
                if session.state != .running {
                    rowShape
                        .stroke(.black.opacity(0.42), lineWidth: 0.8 * metrics.scale)
                }
            }
    }

    private var rowTintSweep: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.015),
                appearance.accent.opacity(0.05),
                .white.opacity(0.01)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.rowHeight * 0.28, style: .continuous)
    }

    private var statusSegmentWidth: CGFloat {
        82 * metrics.scale
    }

    private var rowAccessibilityLabel: String {
        "Open application for \(session.presentationLabel)"
    }

    private var titleForeground: Color {
        .white.opacity(appearance.titleOpacity)
    }

    private func formattedElapsed(at now: Date) -> String {
        let start = session.startedAt ?? session.updatedAt
        let end: Date

        switch session.state {
        case .done, .failed, .cancelled:
            end = session.updatedAt
        case .running, .waitingForInput, .waitingForPermission, .unknown:
            end = now
        }

        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        if elapsed < 100 {
            return String(format: "%02ds", elapsed)
        }

        let minutes = min(99, elapsed / 60)
        if minutes < 100 && elapsed < 6000 {
            return String(format: "%02dm", minutes)
        }

        let hours = min(99, elapsed / 3600)
        return String(format: "%02dh", hours)
    }

    private var statusAccent: Color {
        switch session.state {
        case .running:
            return Color(red: 1.00, green: 0.56, blue: 0.09)
        case .waitingForInput:
            return Color(red: 0.18, green: 0.80, blue: 1.00)
        case .waitingForPermission:
            return Color(red: 1.00, green: 0.22, blue: 0.34)
        case .done:
            return Color(red: 0.24, green: 0.94, blue: 0.44)
        case .failed:
            return Color(red: 1.00, green: 0.22, blue: 0.34)
        case .cancelled:
            return .white.opacity(0.52)
        case .unknown:
            return .white.opacity(0.07)
        }
    }

    private var appearance: SessionRowAppearance {
        SessionRowAppearance(state: session.state)
    }

    private var statusSymbolName: String {
        switch session.state {
        case .running:
            "terminal"
        case .done:
            "checkmark"
        case .failed:
            "exclamationmark"
        case .cancelled:
            "minus"
        case .waitingForInput:
            "questionmark"
        case .waitingForPermission:
            "hand.raised.fill"
        case .unknown:
            "ellipsis"
        }
    }
}
private struct HarnessOrbView: View {
    let harness: AgentHarness
    let metrics: IslandMetrics
    let appearance: SessionRowAppearance

    var body: some View {
        AgentGlyphView(
            harness: harness,
            glyphColor: appearance.iconGlyph
        )
        .frame(width: metrics.iconSize, height: metrics.iconSize)
        .scaleEffect(appearance.iconScale)
    }
}

private struct RowActivityBorder: View {
    let state: SessionState
    let color: Color
    let metrics: IslandMetrics
    let animated: Bool
    let reduceMotion: Bool

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.rowHeight * 0.28, style: .continuous)
    }

    private var activityInset: CGFloat {
        1.6 * metrics.scale
    }

    private var waitingBorderWidth: CGFloat {
        0.9 * metrics.scale
    }

    var body: some View {
        switch state {
        case .running:
            ZStack {
                rowShape
                    .stroke(color.opacity(0.22), lineWidth: waitingBorderWidth)
                    .frame(width: metrics.rowWidth, height: metrics.rowHeight)

                TimelineView(.animation) { timeline in
                    let head = reduceMotion ? CGFloat(0.5) : looped(timeline.date.timeIntervalSinceReferenceDate * 0.27)
                    let dotSize = 5.0 * metrics.scale
                    let trailCount = 36
                    let trailSpan: CGFloat = 0.15

                    ZStack {
                        ForEach(1...trailCount, id: \.self) { index in
                            let fraction = CGFloat(index) / CGFloat(trailCount)
                            let progress = looped(head - fraction * trailSpan)
                            let point = pointOnRowEdge(progress: progress, inset: activityInset)
                            let tailOpacity = pow(1 - fraction, 1.8) * 0.48

                            RoundedRectangle(cornerRadius: dotSize * 0.25, style: .continuous)
                                .fill(color.opacity(tailOpacity))
                                .frame(width: dotSize, height: dotSize)
                                .offset(x: point.x, y: point.y)
                        }

                        let point = pointOnRowEdge(progress: head, inset: activityInset)
                        RoundedRectangle(cornerRadius: dotSize * 0.25, style: .continuous)
                            .fill(color)
                            .frame(width: dotSize, height: dotSize)
                            .shadow(color: color.opacity(0.78), radius: 4 * metrics.scale)
                            .offset(x: point.x, y: point.y)
                    }
                    .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                    .mask {
                        rowShape
                            .inset(by: activityInset)
                            .stroke(.white, lineWidth: waitingBorderWidth)
                            .frame(width: metrics.rowWidth, height: metrics.rowHeight)
                    }
                }
            }
        case .waitingForInput, .waitingForPermission:
            rowShape
                .stroke(color.opacity(0.28), lineWidth: waitingBorderWidth)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
        case .done, .failed, .cancelled:
            rowShape
                .stroke(color.opacity(0.20), lineWidth: waitingBorderWidth)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
        case .unknown:
            rowShape
                .stroke(color.opacity(0.14), lineWidth: waitingBorderWidth)
                .frame(width: metrics.rowWidth, height: metrics.rowHeight)
        }
    }

    private func pointOnRowEdge(progress: CGFloat, inset: CGFloat) -> CGPoint {
        let width = max(1, metrics.rowWidth - inset * 2)
        let height = max(1, metrics.rowHeight - inset * 2)
        let radius = min(max(0, metrics.rowHeight * 0.28 - inset), width / 2, height / 2)
        let straightWidth = max(0, width - radius * 2)
        let straightHeight = max(0, height - radius * 2)
        let arcLength = CGFloat.pi / 2 * radius
        let totalLength = straightWidth * 2 + straightHeight * 2 + arcLength * 4
        var distance = reflected(progress) * totalLength

        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)

        if distance < straightWidth {
            return CGPoint(x: rect.minX + radius + distance, y: rect.minY)
        }
        distance -= straightWidth

        if distance < arcLength {
            let angle = -CGFloat.pi / 2 + distance / arcLength * CGFloat.pi / 2
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.minY + radius + sin(angle) * radius)
        }
        distance -= arcLength

        if distance < straightHeight {
            return CGPoint(x: rect.maxX, y: rect.minY + radius + distance)
        }
        distance -= straightHeight

        if distance < arcLength {
            let angle = distance / arcLength * CGFloat.pi / 2
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.maxY - radius + sin(angle) * radius)
        }
        distance -= arcLength

        if distance < straightWidth {
            return CGPoint(x: rect.maxX - radius - distance, y: rect.maxY)
        }
        distance -= straightWidth

        if distance < arcLength {
            let angle = CGFloat.pi / 2 + distance / arcLength * CGFloat.pi / 2
            return CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.maxY - radius + sin(angle) * radius)
        }
        distance -= arcLength

        if distance < straightHeight {
            return CGPoint(x: rect.minX, y: rect.maxY - radius - distance)
        }
        distance -= straightHeight

        let angle = CGFloat.pi + distance / arcLength * CGFloat.pi / 2
        return CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.minY + radius + sin(angle) * radius)
    }

    private func looped(_ value: TimeInterval) -> CGFloat {
        var phase = CGFloat(value.truncatingRemainder(dividingBy: 1))
        if phase < 0 {
            phase += 1
        }
        return phase
    }

    private func reflected(_ value: CGFloat) -> CGFloat {
        var phase = value.truncatingRemainder(dividingBy: 1)
        if phase < 0 {
            phase += 1
        }
        return phase
    }

}

private struct SessionRowAppearance {
    let accent: Color
    let iconGlyph: Color
    let titleOpacity: Double
    let iconScale: CGFloat
    let titleWeight: Font.Weight

    init(state: SessionState) {
        switch state {
        case .running:
            accent = SessionStateColor.working
            iconGlyph = .white
            titleOpacity = 0.95
            iconScale = 1
            titleWeight = .semibold
        case .done:
            accent = SessionStateColor.done
            iconGlyph = accent
            titleOpacity = 0.78
            iconScale = 0.94
            titleWeight = .medium
        case .failed:
            accent = SessionStateColor.failed
            iconGlyph = accent
            titleOpacity = 0.88
            iconScale = 0.94
            titleWeight = .medium
        case .cancelled:
            accent = SessionStateColor.cancelled
            iconGlyph = accent
            titleOpacity = 0.72
            iconScale = 0.94
            titleWeight = .medium
        case .waitingForInput:
            accent = SessionStateColor.question
            iconGlyph = accent
            titleOpacity = 1
            iconScale = 1.02
            titleWeight = .bold
        case .waitingForPermission:
            accent = SessionStateColor.permission
            iconGlyph = accent
            titleOpacity = 1
            iconScale = 1.02
            titleWeight = .bold
        case .unknown:
            accent = .white.opacity(0.52)
            iconGlyph = .white.opacity(0.72)
            titleOpacity = 0.82
            iconScale = 0.96
            titleWeight = .medium
        }
    }
}
