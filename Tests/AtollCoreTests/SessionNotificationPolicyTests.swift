import XCTest
@testable import AtollCore

final class SessionNotificationPolicyTests: XCTestCase {
    func testOnlyNewActionableTransitionsNotify() {
        let previous = [session(state: .running)]

        XCTAssertEqual(
            notifications(previous: previous, current: [session(state: .waitingForInput)]),
            [SessionNotification(
                identifier: "atoll.session.waitingForInput",
                title: "Claude Code needs input"
            )]
        )
        XCTAssertEqual(
            notifications(previous: previous, current: [session(state: .waitingForPermission)]).first?.title,
            "Claude Code needs approval"
        )
        XCTAssertEqual(
            notifications(previous: previous, current: [session(state: .failed)]).first?.title,
            "Claude Code failed"
        )

        for state in [SessionState.running, .done, .cancelled, .unknown] {
            XCTAssertTrue(notifications(previous: previous, current: [session(state: state)]).isEmpty)
        }
    }

    func testDuplicateReplayRefreshAndRestorationDoNotNotify() {
        let waiting = [session(state: .waitingForInput)]

        XCTAssertTrue(notifications(previous: waiting, current: waiting).isEmpty)
        XCTAssertTrue(notifications(previous: nil, current: waiting).isEmpty)
        XCTAssertTrue(
            notifications(
                previous: [session(state: .running)],
                current: waiting,
                isEnabled: false
            ).isEmpty
        )
    }

    func testStableSessionStateIdentifierSupportsASecondRealTransition() {
        let first = notifications(
            previous: [session(state: .running)],
            current: [session(state: .waitingForInput)]
        )
        let second = notifications(
            previous: [session(state: .running)],
            current: [session(state: .waitingForInput)]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
    }

    func testOnlyACompleteFrontmostOriginMatchSuppresses() {
        let frontmost = ApplicationIdentity(
            processID: 123,
            bundleIdentifier: "com.example.Terminal"
        )
        let matching = session(
            state: .waitingForPermission,
            originProcessID: 123,
            originBundleIdentifier: "com.example.Terminal"
        )

        XCTAssertTrue(
            notifications(
                previous: [session(state: .running)],
                current: [matching],
                frontmostApplication: frontmost
            ).isEmpty
        )
        XCTAssertEqual(
            notifications(
                previous: [session(state: .running)],
                current: [session(
                    state: .waitingForPermission,
                    originProcessID: 456,
                    originBundleIdentifier: "com.example.Terminal"
                )],
                frontmostApplication: frontmost
            ).count,
            1
        )
        XCTAssertEqual(
            notifications(
                previous: [session(state: .running)],
                current: [session(
                    state: .waitingForPermission,
                    originProcessID: 123
                )],
                frontmostApplication: frontmost
            ).count,
            1
        )
    }

    func testAuthorizationIsRequestedOnlyForAnUndeterminedUserEnable() {
        XCTAssertTrue(SessionNotificationPolicy.shouldRequestAuthorization(
            forUserInitiatedEnable: true,
            status: .notDetermined
        ))
        XCTAssertFalse(SessionNotificationPolicy.shouldRequestAuthorization(
            forUserInitiatedEnable: false,
            status: .notDetermined
        ))
        XCTAssertFalse(SessionNotificationPolicy.shouldRequestAuthorization(
            forUserInitiatedEnable: true,
            status: .authorized
        ))
        XCTAssertFalse(SessionNotificationPolicy.shouldRequestAuthorization(
            forUserInitiatedEnable: true,
            status: .denied
        ))
    }

    func testTrackerKeepsRestorationSilentAndDeduplicatesQueueSocketRace() {
        var tracker = SessionNotificationTracker()
        let restored = [session(state: .waitingForInput)]

        XCTAssertTrue(tracker.notifications(
            for: restored,
            isEnabled: true,
            frontmostApplication: nil
        ).isEmpty)

        tracker.synchronize([session(state: .running)])
        XCTAssertEqual(
            tracker.notifications(
                for: [session(state: .waitingForInput)],
                isEnabled: true,
                frontmostApplication: nil
            ).count,
            1
        )
        XCTAssertTrue(tracker.notifications(
            for: [session(state: .waitingForInput)],
            isEnabled: true,
            frontmostApplication: nil
        ).isEmpty)
    }

    private func notifications(
        previous: [AgentSession]?,
        current: [AgentSession],
        isEnabled: Bool = true,
        frontmostApplication: ApplicationIdentity? = nil
    ) -> [SessionNotification] {
        SessionNotificationPolicy.notifications(
            previousSessions: previous,
            currentSessions: current,
            isEnabled: isEnabled,
            frontmostApplication: frontmostApplication
        )
    }

    private func session(
        state: SessionState,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session",
            harness: .claude,
            label: "/Users/private/project secret prompt",
            state: state,
            updatedAt: Date(),
            originProcessID: originProcessID,
            originBundleIdentifier: originBundleIdentifier
        )
    }
}
