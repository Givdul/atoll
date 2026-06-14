import AtollCore
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var allSessions: [AgentSession] = []
    @Published var settings: AtollSettings
    @Published var lastRefresh: Date?

    private let settingsStore: SettingsStore
    private let doneDisplayWindow: TimeInterval = 5

    private var displaySessions: [AgentSession] {
        settings.testMode ? Self.testModeSessions() : allSessions
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    var visibleSessions: [AgentSession] {
        let filtered = runningSessions + waitingSessions + recentDoneSessions

        return Array(filtered.prefix(8))
    }

    var menuSessions: [AgentSession] {
        displaySessions
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
        displaySessions.filter {
            $0.state == .done && Date().timeIntervalSince($0.updatedAt) <= doneDisplayWindow
        }
    }

    var hasIslandContent: Bool {
        !runningSessions.isEmpty || !waitingSessions.isEmpty || !recentDoneSessions.isEmpty
    }

    var islandRowCount: Int {
        max(1, visibleSessions.count)
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
                model: "test",
                state: .waitingForPermission,
                updatedAt: now.addingTimeInterval(11),
                sourcePath: "atoll://test-mode/codex/permission",
                confidence: .live
            )
        ]

        return (running + codexAttention).sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
