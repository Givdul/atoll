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
            updateDoneObservationTimes(from: allSessions)
        }
    }
    @Published var settings: AtollSettings
    @Published var lastRefresh: Date?
    @Published var islandHoverState: IslandHoverState = .inactive

    private static let maxVisibleSessions = 8

    private let settingsStore: SettingsStore
    private let doneDisplayWindow: TimeInterval = 3
    private var doneObservedAt: [String: Date] = [:]

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
            case .done:
                settings.testMode || isRecentDoneNotification(session, now: now)
            case .unknown:
                false
            }
        }

        let attentionSessions = Self.attentionSessions(from: candidates)
        let regularSessions = candidates.filter { !Self.needsAttention($0) }
        let regularLimit = max(0, Self.maxVisibleSessions - attentionSessions.count)

        return Array(regularSessions.prefix(regularLimit)) + attentionSessions
    }

    var runningSessions: [AgentSession] {
        displaySessions.filter {
            $0.state == .running && $0.confidence != .historical
        }
    }

    var waitingSessions: [AgentSession] {
        Array(displaySessions.filter {
            ($0.state == .waitingForInput || $0.state == .waitingForPermission)
                && $0.confidence != .historical
        }.prefix(3))
    }

    var recentDoneSessions: [AgentSession] {
        let now = Date()
        return displaySessions.filter {
            $0.state == .done && (settings.testMode || isRecentDoneNotification($0, now: now))
        }
    }

    var hasIslandContent: Bool {
        !runningSessions.isEmpty || !waitingSessions.isEmpty || !recentDoneSessions.isEmpty
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

    private func isRecentDoneNotification(_ session: AgentSession, now: Date) -> Bool {
        guard now.timeIntervalSince(session.updatedAt) <= doneDisplayWindow else {
            return false
        }

        let observedAt = doneObservedAt[session.id] ?? session.updatedAt
        return now.timeIntervalSince(observedAt) <= doneDisplayWindow
    }

    private func updateDoneObservationTimes(from sessions: [AgentSession]) {
        let now = Date()
        let activeDoneIDs = Set(sessions.filter { $0.state == .done }.map(\.id))

        doneObservedAt = doneObservedAt.filter { id, _ in
            activeDoneIDs.contains(id)
        }

        for id in activeDoneIDs where doneObservedAt[id] == nil {
            doneObservedAt[id] = now
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
