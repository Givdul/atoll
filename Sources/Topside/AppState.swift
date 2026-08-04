import TopsideCore
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
    @Published private(set) var allSessions: [AgentSession] = []
    @Published private(set) var presentation: IslandPresentation = .empty
    @Published private(set) var settings: TopsideSettings
    @Published var islandHoverState: IslandHoverState = .inactive {
        didSet {
            guard islandHoverState != oldValue else { return }
            refreshPresentation()
        }
    }
    @Published var isIslandAvailable = false
    @Published var entitlement: TopsideEntitlementStatus = .recoverableError(
        message: "Topside is checking its entitlement.",
        allowsUse: true
    ) {
        didSet {
            guard entitlement != oldValue else { return }
            refreshPresentation()
        }
    }

    private struct TerminalObservation {
        var state: SessionState
        var sourceObservedAt: Date?
        var displayedAt: Date
    }

    private let settingsStore: SettingsStore
    let isDevelopmentBuild = Bundle.main.object(forInfoDictionaryKey: "TopsideDevelopmentBuild") as? Bool == true
    private var terminalObservations: [String: TerminalObservation] = [:]
    private var notchGeometry: PhysicalNotchGeometry?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        refreshPresentation()
    }

    var visibleSessions: [AgentSession] {
        presentation.visibleSessions
    }

    var runningSessions: [AgentSession] {
        presentation.runningSessions
    }

    var waitingSessions: [AgentSession] {
        presentation.waitingSessions
    }

    var recentTerminalSessions: [AgentSession] {
        presentation.recentTerminalSessions
    }

    var hasIslandContent: Bool {
        presentation.hasContent
    }

    var visibleAttentionCount: Int {
        presentation.attentionSessions.count
    }

    var visibleRegularCount: Int {
        presentation.regularSessions.count
    }

    var activeAttentionCount: Int {
        presentation.activeAttentionCount
    }

    @discardableResult
    func replaceSessions(_ sessions: [AgentSession], now: Date = Date()) -> Bool {
        let sessionsChanged = sessions != allSessions
        if sessionsChanged {
            allSessions = sessions
            updateTerminalObservationTimes(from: sessions, now: now)
        }
        return refreshPresentation(now: now) || sessionsChanged
    }

    func update(settings: TopsideSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        settingsStore.save(settings)
        refreshPresentation()
    }

    func updateNotchGeometry(_ notch: PhysicalNotchGeometry?) {
        guard notch != notchGeometry else { return }
        notchGeometry = notch
        refreshPresentation()
    }

    @discardableResult
    func refreshPresentation(now: Date = Date()) -> Bool {
        let sessions: [AgentSession]
        if !(entitlement.allowsUse || settings.testMode || isDevelopmentBuild) {
            sessions = []
        } else if settings.testMode {
            sessions = Self.testModeSessions(now: now)
        } else {
            sessions = allSessions
        }
        let next = IslandPresentation.make(
            sessions: sessions,
            terminalDisplayedAt: terminalObservations.mapValues(\.displayedAt),
            now: now,
            testMode: settings.testMode,
            isExpanded: islandHoverState.expandsList,
            notch: notchGeometry
        )
        guard next != presentation else { return false }
        presentation = next
        return true
    }

    private static func testModeSessions(now: Date) -> [AgentSession] {
        let running = LifecycleHookInstaller.supportedAgents.enumerated().map { index, harness in
            AgentSession(
                id: "test-\(harness.rawValue)-running",
                harness: harness,
                label: "\(harness.displayName) test task",
                state: .running,
                updatedAt: now.addingTimeInterval(TimeInterval(-index)),
                taskLabel: "Test task"
            )
        }
        let codexAttention = [
            AgentSession(
                id: "test-codex-question",
                harness: .codex,
                label: "Codex test question",
                state: .waitingForInput,
                updatedAt: now.addingTimeInterval(10),
                taskLabel: "Test question"
            ),
            AgentSession(
                id: "test-codex-permission",
                harness: .codex,
                label: "Codex test permission",
                state: .waitingForPermission,
                updatedAt: now.addingTimeInterval(11),
                taskLabel: "Test permission"
            )
        ]
        let doneSession = AgentSession(
            id: "test-codex-done",
            harness: .codex,
            label: "Codex test done",
            state: .done,
            updatedAt: now,
            taskLabel: "Test done"
        )
        return (running + codexAttention + [doneSession]).sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func updateTerminalObservationTimes(from sessions: [AgentSession], now: Date) {
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
}
