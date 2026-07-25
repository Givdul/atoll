import AtollCore
import Combine
import Foundation

enum IslandHoverState: Equatable {
    case inactive
    case expanding
    case attention

    var expandsList: Bool {
        self == .expanding
    }

    var dimsAttentionRows: Bool {
        self == .attention
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var allSessions: [AgentSession] = []
    {
        didSet {
            updateTerminalObservationTimes(from: allSessions)
        }
    }
    @Published var settings: AtollSettings
    @Published var lastRefresh: Date?
    @Published var islandHoverState: IslandHoverState = .inactive

    private static let maxVisibleSessions = 8

    private let settingsStore: SettingsStore
    private let terminalDisplayWindow: TimeInterval = 3
    private struct TerminalObservation {
        var state: SessionState
        var sourceObservedAt: Date?
        var displayedAt: Date
    }
    private var terminalObservations: [String: TerminalObservation] = [:]

    private var displaySessions: [AgentSession] {
        settings.testMode ? Self.testModeSessions() : allSessions
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    var visibleSessions: [AgentSession] {
        let now = Date()
        let candidates = displaySessions.filter { session in
            switch session.state {
            case .waitingForPermission, .waitingForInput, .running:
                session.confidence != .historical
            case .done, .failed, .cancelled:
                settings.testMode || isRecentTerminalNotification(session, now: now)
            case .unknown:
                false
            }
        }

        let attentionSessions = Array(
            Self.attentionSessions(from: candidates).prefix(Self.maxVisibleSessions)
        )
        let regularCandidates = candidates.filter { !Self.needsAttention($0) }
        let terminalSessions = regularCandidates
            .filter { $0.state.isTerminal }
            .sorted { terminalDisplayDate(for: $0) > terminalDisplayDate(for: $1) }
        let activeSessions = regularCandidates.filter { !$0.state.isTerminal }
        let regularSessions = terminalSessions + activeSessions
        let regularLimit = max(0, Self.maxVisibleSessions - attentionSessions.count)

        return Array(regularSessions.prefix(regularLimit)) + attentionSessions
    }

    var runningSessions: [AgentSession] {
        displaySessions.filter {
            $0.state == .running && $0.confidence != .historical
        }
    }

    var waitingSessions: [AgentSession] {
        displaySessions.filter {
            ($0.state == .waitingForInput || $0.state == .waitingForPermission)
                && $0.confidence != .historical
        }
    }

    var recentTerminalSessions: [AgentSession] {
        let now = Date()
        return displaySessions.filter {
            $0.state.isTerminal && (settings.testMode || isRecentTerminalNotification($0, now: now))
        }
    }

    var hasIslandContent: Bool {
        !runningSessions.isEmpty || !waitingSessions.isEmpty || !recentTerminalSessions.isEmpty
    }

    var visibleAttentionCount: Int {
        visibleSessions.filter(Self.needsAttention).count
    }

    var visibleRegularCount: Int {
        max(0, visibleSessions.count - visibleAttentionCount)
    }

    var activeAttentionCount: Int {
        waitingSessions.count
    }

    func update(settings: AtollSettings) {
        self.settings = settings
        settingsStore.save(settings)
    }

    private static func testModeSessions(now: Date = Date()) -> [AgentSession] {
        let running = AgentHarness.allCases.enumerated().map { index, harness in
            AgentSession(
                id: "test-\(harness.rawValue)-running",
                harness: harness,
                title: "\(harness.displayName) test task",
                detail: "Test Mode",
                prompt: "Run \(harness.displayName) test task",
                lastToolCall: "Shell",
                projectPath: nil,
                model: "test",
                state: .running,
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                sourcePath: "atoll://test-mode/\(harness.rawValue)/running",
                processID: nil,
                confidence: .live
            )
        }

        let codexAttention = [
            AgentSession(
                id: "test-codex-question",
                harness: .codex,
                title: "Codex test question",
                detail: "Test Mode",
                prompt: "Choose a Codex test option",
                model: "test",
                state: .waitingForInput,
                updatedAt: now.addingTimeInterval(10),
                sourcePath: "atoll://test-mode/codex/question",
                confidence: .live
            ),
            AgentSession(
                id: "test-codex-permission",
                harness: .codex,
                title: "Codex test permission",
                detail: "Test Mode",
                prompt: "Run a permission-gated Codex test",
                lastToolCall: "Shell",
                model: "test",
                state: .waitingForPermission,
                updatedAt: now.addingTimeInterval(11),
                sourcePath: "atoll://test-mode/codex/permission",
                confidence: .live
            )
        ]

        let doneSession = AgentSession(
            id: "test-codex-done",
            harness: .codex,
            title: "Codex test done",
            detail: "Test Mode",
            prompt: "Completed a done-state scenario",
            model: "test",
            state: .done,
            updatedAt: now,
            sourcePath: "atoll://test-mode/codex/done",
            confidence: .live
        )

        return (running + codexAttention + [doneSession]).sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func attentionSessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions
            .filter(needsAttention)
            .sorted {
                if attentionBottomRank($0.state) != attentionBottomRank($1.state) {
                    return attentionBottomRank($0.state) < attentionBottomRank($1.state)
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private static func needsAttention(_ session: AgentSession) -> Bool {
        session.state == .waitingForInput || session.state == .waitingForPermission
    }

    private func isRecentTerminalNotification(_ session: AgentSession, now: Date) -> Bool {
        let observedAt = terminalDisplayDate(for: session)
        return now.timeIntervalSince(observedAt) <= terminalDisplayWindow
    }

    private func terminalDisplayDate(for session: AgentSession) -> Date {
        terminalObservations[session.id]?.displayedAt
            ?? session.observedAt
            ?? session.updatedAt
    }

    private func updateTerminalObservationTimes(from sessions: [AgentSession]) {
        let now = Date()
        let activeTerminalIDs = Set(sessions.filter { $0.state.isTerminal }.map(\.id))

        terminalObservations = terminalObservations.filter { id, _ in
            activeTerminalIDs.contains(id)
        }

        for session in sessions where session.state.isTerminal {
            let existing = terminalObservations[session.id]
            let shouldReset = existing == nil
                || existing?.state != session.state
                || existing?.sourceObservedAt != session.observedAt
            guard shouldReset else { continue }

            terminalObservations[session.id] = TerminalObservation(
                state: session.state,
                sourceObservedAt: session.observedAt,
                displayedAt: now
            )
        }
    }

    private static func attentionBottomRank(_ state: SessionState) -> Int {
        switch state {
        case .waitingForInput:
            0
        case .waitingForPermission:
            1
        default:
            2
        }
    }
}
