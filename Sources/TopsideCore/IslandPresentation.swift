import CoreGraphics
import Foundation

public struct IslandMetrics: Equatable, Sendable {
    public static let hostSize = CGSize(width: 439, height: 340)
    public static let opticalHorizontalOffset: CGFloat = 0.5

    public let scale: CGFloat
    public let rowWidth: CGFloat
    public let rowHeight: CGFloat
    public let horizontalPadding: CGFloat
    public let iconSize: CGFloat
    public let titleFontSize: CGFloat
    public let detailFontSize: CGFloat
    public let topGap: CGFloat
    public let rowSpacing: CGFloat
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat

    public init(displayGeometry: IslandDisplayGeometry, hasContent: Bool) {
        let factor = min(1.08, max(0.88, displayGeometry.height / 32))
        scale = factor
        rowWidth = 392 * factor
        rowHeight = max(32, min(36, displayGeometry.height * 0.92))
        horizontalPadding = 6.5 * factor
        iconSize = rowHeight - 8 * factor
        titleFontSize = min(12 * factor, rowHeight * 0.38)
        detailFontSize = min(11 * factor, rowHeight * 0.34)
        topGap = 0
        rowSpacing = 3 * factor

        let usesActiveClearance = hasContent && displayGeometry.provenance == .physical
        notchWidth = displayGeometry.width + (usesActiveClearance ? 4 : 0)
        notchHeight = displayGeometry.height + (usesActiveClearance ? 3 : 0)
    }

    public func listHeight(forRowCount rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let count = CGFloat(rowCount)
        return count * rowHeight + CGFloat(rowCount - 1) * rowSpacing
    }
}

public struct IslandRowLayout: Equatable, Sendable {
    public enum Section: Equatable, Sendable {
        case regular
        case attention
    }

    public let sessionID: String
    public let section: Section
    public let frame: CGRect
    public let isActivatable: Bool

    public init(sessionID: String, section: Section, frame: CGRect, isActivatable: Bool) {
        self.sessionID = sessionID
        self.section = section
        self.frame = frame
        self.isActivatable = isActivatable
    }
}

public struct IslandPresentationLayout: Equatable, Sendable {
    public let metrics: IslandMetrics
    public let hostFrame: CGRect
    public let notchFrame: CGRect
    public let regularSectionBounds: CGRect?
    public let attentionSectionBounds: CGRect?
    public let expandedHoverBounds: CGRect
    public let rows: [IslandRowLayout]

    public var activatableRows: [IslandRowLayout] {
        rows.filter(\.isActivatable)
    }
}

public struct IslandPresentation: Equatable, Sendable {
    public static let terminalDisplayWindow: TimeInterval = 3
    public static let maximumVisibleSessions = 8

    public let regularSessions: [AgentSession]
    public let floatingTerminalSessions: [AgentSession]
    public let displayedRegularSessions: [AgentSession]
    public let attentionSessions: [AgentSession]
    public let runningSessions: [AgentSession]
    public let waitingSessions: [AgentSession]
    public let recentTerminalSessions: [AgentSession]
    public let activityState: SessionState?
    public let nextTerminalExpiry: Date?
    public let layout: IslandPresentationLayout?

    public static let empty = IslandPresentation(
        regularSessions: [],
        floatingTerminalSessions: [],
        displayedRegularSessions: [],
        attentionSessions: [],
        runningSessions: [],
        waitingSessions: [],
        recentTerminalSessions: [],
        activityState: nil,
        nextTerminalExpiry: nil,
        layout: nil
    )

    public var visibleSessions: [AgentSession] {
        regularSessions + attentionSessions
    }

    public var displayedSessions: [AgentSession] {
        displayedRegularSessions + attentionSessions
    }

    public var hasContent: Bool {
        !runningSessions.isEmpty || !waitingSessions.isEmpty || !recentTerminalSessions.isEmpty
    }

    public var activeAttentionCount: Int {
        waitingSessions.count
    }

    public static func make(
        sessions: [AgentSession],
        terminalDisplayedAt: [String: Date],
        now: Date,
        testMode: Bool,
        isExpanded: Bool,
        displayGeometry: IslandDisplayGeometry?
    ) -> IslandPresentation {
        let candidates = sessions.filter { session in
            switch session.state {
            case .running, .waitingForInput, .waitingForPermission:
                true
            case .done, .failed, .cancelled:
                testMode || isRecentTerminal(
                    session,
                    terminalDisplayedAt: terminalDisplayedAt,
                    now: now
                )
            case .unknown:
                false
            }
        }

        let allAttention = candidates
            .filter(\.state.needsAttention)
            .sorted(by: attentionOrdering)
        let attentionSessions = Array(allAttention.prefix(maximumVisibleSessions))
        let regularLimit = max(0, maximumVisibleSessions - attentionSessions.count)
        let terminalSessions = candidates
            .filter { $0.state.isTerminal && !$0.state.needsAttention }
            .sorted {
                terminalDisplayDate(for: $0, terminalDisplayedAt: terminalDisplayedAt)
                    > terminalDisplayDate(for: $1, terminalDisplayedAt: terminalDisplayedAt)
            }
        let activeSessions = candidates
            .filter { !$0.state.isTerminal && !$0.state.needsAttention }
            .sorted { $0.updatedAt > $1.updatedAt }
        let regularSessions = Array((terminalSessions + activeSessions).prefix(regularLimit))
        let floatingTerminalSessions = regularSessions.filter(\.state.isTerminal)
        let displayedRegularSessions = isExpanded ? regularSessions : floatingTerminalSessions
        let waitingSessions = sessions.filter(\.state.needsAttention)
        let runningSessions = sessions.filter { $0.state == .running }
        let recentTerminalSessions = sessions.filter {
            $0.state.isTerminal && (testMode || isRecentTerminal(
                $0,
                terminalDisplayedAt: terminalDisplayedAt,
                now: now
            ))
        }
        let nextTerminalExpiry = testMode ? nil : recentTerminalSessions
            .map {
                terminalDisplayDate(for: $0, terminalDisplayedAt: terminalDisplayedAt)
                    .addingTimeInterval(terminalDisplayWindow)
            }
            .filter { $0 >= now }
            .min()
        let hasContent = !candidates.isEmpty
        let activityState: SessionState?
        if candidates.contains(where: { $0.state == .waitingForPermission }) {
            activityState = .waitingForPermission
        } else if candidates.contains(where: { $0.state == .waitingForInput }) {
            activityState = .waitingForInput
        } else if candidates.contains(where: { $0.state == .running }) {
            activityState = .running
        } else {
            activityState = nil
        }

        let layout = displayGeometry.map {
            makeLayout(
                metrics: IslandMetrics(displayGeometry: $0, hasContent: hasContent),
                regularSessions: displayedRegularSessions,
                attentionSessions: attentionSessions
            )
        }
        return IslandPresentation(
            regularSessions: regularSessions,
            floatingTerminalSessions: floatingTerminalSessions,
            displayedRegularSessions: displayedRegularSessions,
            attentionSessions: attentionSessions,
            runningSessions: runningSessions,
            waitingSessions: waitingSessions,
            recentTerminalSessions: recentTerminalSessions,
            activityState: activityState,
            nextTerminalExpiry: nextTerminalExpiry,
            layout: layout
        )
    }

    private static func makeLayout(
        metrics: IslandMetrics,
        regularSessions: [AgentSession],
        attentionSessions: [AgentSession]
    ) -> IslandPresentationLayout {
        let hostFrame = CGRect(origin: .zero, size: IslandMetrics.hostSize)
        let notchFrame = CGRect(
            x: (hostFrame.width - metrics.notchWidth) / 2 + IslandMetrics.opticalHorizontalOffset,
            y: hostFrame.height - metrics.notchHeight,
            width: metrics.notchWidth,
            height: metrics.notchHeight
        )
        let rowX = (hostFrame.width - metrics.rowWidth) / 2
        var top = notchFrame.minY
        var rows: [IslandRowLayout] = []

        func append(
            _ sessions: [AgentSession],
            section: IslandRowLayout.Section
        ) -> CGRect? {
            guard !sessions.isEmpty else { return nil }
            top -= metrics.rowSpacing
            let sectionTop = top
            for session in sessions {
                top -= metrics.rowHeight
                rows.append(IslandRowLayout(
                    sessionID: session.id,
                    section: section,
                    frame: CGRect(x: rowX, y: top, width: metrics.rowWidth, height: metrics.rowHeight),
                    isActivatable: session.originProcessID != nil
                        && session.originBundleIdentifier?.isEmpty == false
                ))
                if session.id != sessions.last?.id {
                    top -= metrics.rowSpacing
                }
            }
            return CGRect(x: rowX, y: top, width: metrics.rowWidth, height: sectionTop - top)
        }

        let regularBounds = append(regularSessions, section: .regular)
        let attentionBounds = append(attentionSessions, section: .attention)
        let lowerBound = min(
            regularBounds?.minY ?? notchFrame.minY,
            attentionBounds?.minY ?? notchFrame.minY
        )
        let expandedHoverBounds = CGRect(
            x: rowX,
            y: lowerBound,
            width: metrics.rowWidth,
            height: hostFrame.height - lowerBound
        )
        return IslandPresentationLayout(
            metrics: metrics,
            hostFrame: hostFrame,
            notchFrame: notchFrame,
            regularSectionBounds: regularBounds,
            attentionSectionBounds: attentionBounds,
            expandedHoverBounds: expandedHoverBounds,
            rows: rows
        )
    }

    private static func isRecentTerminal(
        _ session: AgentSession,
        terminalDisplayedAt: [String: Date],
        now: Date
    ) -> Bool {
        now.timeIntervalSince(
            terminalDisplayDate(for: session, terminalDisplayedAt: terminalDisplayedAt)
        ) <= terminalDisplayWindow
    }

    private static func terminalDisplayDate(
        for session: AgentSession,
        terminalDisplayedAt: [String: Date]
    ) -> Date {
        terminalDisplayedAt[session.id] ?? session.observedAt ?? session.updatedAt
    }

    private static func attentionOrdering(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.state.attentionBottomRank != rhs.state.attentionBottomRank {
            return lhs.state.attentionBottomRank < rhs.state.attentionBottomRank
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private extension SessionState {
    var needsAttention: Bool {
        self == .waitingForInput || self == .waitingForPermission
    }

    var attentionBottomRank: Int {
        switch self {
        case .waitingForInput: 0
        case .waitingForPermission: 1
        default: 2
        }
    }
}
