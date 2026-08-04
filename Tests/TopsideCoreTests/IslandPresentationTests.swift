import CoreGraphics
import XCTest
@testable import TopsideCore

final class IslandPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let notch = PhysicalNotchGeometry(
        safeAreaTop: 32,
        auxiliaryLeftMaxX: 663,
        auxiliaryRightMinX: 848
    )!

    func testOrdersTerminalsBeforeRunningAndPinsAttentionByKind() {
        let sessions = [
            session("running", state: .running, offset: -1),
            session("permission", state: .waitingForPermission, offset: 4),
            session("input", state: .waitingForInput, offset: 3),
            session("done", state: .done, offset: 2)
        ]
        let presentation = make(
            sessions,
            displayedAt: ["done": now.addingTimeInterval(-1)],
            expanded: true
        )

        XCTAssertEqual(presentation.regularSessions.map(\.id), ["done", "running"])
        XCTAssertEqual(presentation.attentionSessions.map(\.id), ["input", "permission"])
        XCTAssertEqual(presentation.displayedRegularSessions.map(\.id), ["done", "running"])
        XCTAssertEqual(presentation.activityState, .waitingForPermission)
    }

    func testAttentionConsumesEightRowCapBeforeRegularSessions() {
        let attention = (0..<7).map {
            session("attention-\($0)", state: .waitingForInput, offset: TimeInterval($0))
        }
        let sessions = attention + [
            session("terminal", state: .done, offset: 20),
            session("running", state: .running, offset: 19)
        ]
        let presentation = make(
            sessions,
            displayedAt: ["terminal": now],
            expanded: true
        )

        XCTAssertEqual(presentation.attentionSessions.count, 7)
        XCTAssertEqual(presentation.regularSessions.map(\.id), ["terminal"])
        XCTAssertEqual(presentation.visibleSessions.count, 8)
    }

    func testCollapsedLayoutContainsOnlyTerminalAndAttentionRows() {
        let sessions = [
            session("running", state: .running, offset: 2),
            session("terminal", state: .done, offset: 1),
            session("attention", state: .waitingForInput, offset: 3)
        ]
        let collapsed = make(
            sessions,
            displayedAt: ["terminal": now],
            expanded: false
        )
        let expanded = make(
            sessions,
            displayedAt: ["terminal": now],
            expanded: true
        )

        XCTAssertEqual(collapsed.displayedRegularSessions.map(\.id), ["terminal"])
        XCTAssertEqual(collapsed.layout?.rows.map(\.sessionID), ["terminal", "attention"])
        XCTAssertEqual(expanded.layout?.rows.map(\.sessionID), ["terminal", "running", "attention"])
        XCTAssertNil(collapsed.layout?.rows.first { $0.sessionID == "running" })
    }

    func testEveryVisibleRowHasOneLayoutRectangleAndOnlyCompleteOriginsActivate() {
        let sessions = [
            session("interactive", state: .running, offset: 2, interactive: true),
            session("headless", state: .running, offset: 1),
            session("attention", state: .waitingForPermission, offset: 3, interactive: true)
        ]
        let presentation = make(sessions, expanded: true)
        let rows = presentation.layout?.rows ?? []

        XCTAssertEqual(rows.map(\.sessionID), presentation.displayedSessions.map(\.id))
        XCTAssertEqual(Set(rows.map(\.sessionID)).count, rows.count)
        XCTAssertEqual(rows.filter(\.isActivatable).map(\.sessionID), ["interactive", "attention"])
        XCTAssertTrue(rows.allSatisfy { !$0.frame.isEmpty })
    }

    func testSectionBoundsShareRowGeometryAndSpacingAuthority() throws {
        let sessions = [
            session("one", state: .running, offset: 2),
            session("two", state: .running, offset: 1),
            session("attention", state: .waitingForInput, offset: 3)
        ]
        let layout = try XCTUnwrap(make(sessions, expanded: true).layout)
        let regularRows = layout.rows.filter { $0.section == .regular }
        let attentionRow = try XCTUnwrap(layout.rows.first { $0.section == .attention })
        let regularBounds = try XCTUnwrap(layout.regularSectionBounds)
        let attentionBounds = try XCTUnwrap(layout.attentionSectionBounds)

        XCTAssertEqual(layout.hostFrame.size, IslandMetrics.hostSize)
        XCTAssertEqual(layout.notchFrame.maxY, layout.hostFrame.maxY)
        XCTAssertEqual(regularBounds.minY, regularRows.last?.frame.minY)
        XCTAssertEqual(regularBounds.maxY, regularRows.first?.frame.maxY)
        XCTAssertEqual(attentionBounds, attentionRow.frame)
        XCTAssertEqual(
            regularRows.last!.frame.minY - attentionRow.frame.maxY,
            layout.metrics.rowSpacing,
            accuracy: 0.001
        )
    }

    func testTerminalExpiryUsesOneExplicitClockBoundary() {
        let displayedAt = now.addingTimeInterval(-IslandPresentation.terminalDisplayWindow)
        let atBoundary = make(
            [session("done", state: .done, offset: -20)],
            displayedAt: ["done": displayedAt],
            at: now
        )
        let afterBoundary = make(
            [session("done", state: .done, offset: -20)],
            displayedAt: ["done": displayedAt],
            at: now.addingTimeInterval(0.001)
        )

        XCTAssertEqual(atBoundary.floatingTerminalSessions.map(\.id), ["done"])
        XCTAssertEqual(atBoundary.nextTerminalExpiry, now)
        XCTAssertTrue(afterBoundary.floatingTerminalSessions.isEmpty)
        XCTAssertNil(afterBoundary.nextTerminalExpiry)
    }

    private func make(
        _ sessions: [AgentSession],
        displayedAt: [String: Date] = [:],
        at date: Date? = nil,
        expanded: Bool = false
    ) -> IslandPresentation {
        IslandPresentation.make(
            sessions: sessions,
            terminalDisplayedAt: displayedAt,
            now: date ?? now,
            testMode: false,
            isExpanded: expanded,
            notch: notch
        )
    }

    private func session(
        _ id: String,
        state: SessionState,
        offset: TimeInterval,
        interactive: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id,
            harness: .codex,
            label: id,
            state: state,
            updatedAt: now.addingTimeInterval(offset),
            observedAt: now.addingTimeInterval(offset),
            originProcessID: interactive ? 42 : nil,
            originBundleIdentifier: interactive ? "com.example.Editor" : nil
        )
    }
}
