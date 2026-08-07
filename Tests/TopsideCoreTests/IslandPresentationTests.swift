import CoreGraphics
import XCTest
@testable import TopsideCore

final class IslandPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let physicalGeometry = IslandDisplayGeometry(notch: PhysicalNotchGeometry(
        safeAreaTop: 32,
        auxiliaryLeftMaxX: 663,
        auxiliaryRightMinX: 848
    )!)
    private let virtualGeometry = IslandDisplayGeometry(
        fallbackFrame: CGRect(x: 100, y: 20, width: 500, height: 300)
    )

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

    func testEmptyPresentationUsesPhysicalNotchDimensions() throws {
        let presentation = make([])
        let layout = try XCTUnwrap(presentation.layout)

        XCTAssertFalse(presentation.hasContent)
        XCTAssertEqual(layout.metrics.notchWidth, physicalGeometry.width)
        XCTAssertEqual(layout.metrics.notchHeight, physicalGeometry.height)
        XCTAssertEqual(layout.notchFrame.size, CGSize(width: physicalGeometry.width, height: physicalGeometry.height))
        XCTAssertEqual(layout.hostFrame.size, IslandMetrics.hostSize)
        XCTAssertEqual(layout.notchFrame.maxY, layout.hostFrame.maxY)
    }

    func testActivePhysicalPresentationsAddClearance() throws {
        for state in [SessionState.running, .waitingForInput, .waitingForPermission] {
            let presentation = make([session(state.rawValue, state: state, offset: 0)])
            let layout = try XCTUnwrap(presentation.layout)

            XCTAssertTrue(presentation.hasContent, "Expected content for \(state.rawValue)")
            XCTAssertEqual(layout.metrics.notchWidth, physicalGeometry.width + 4)
            XCTAssertEqual(layout.metrics.notchHeight, physicalGeometry.height + 3)
            if state == .running {
                XCTAssertTrue(presentation.displayedRegularSessions.isEmpty)
            }
        }
    }

    func testVirtualPresentationKeepsNominalDimensionsWhileIdleAndActive() throws {
        let states: [SessionState?] = [nil, .running, .waitingForInput, .waitingForPermission]

        for state in states {
            let sessions = state.map { [session($0.rawValue, state: $0, offset: 0)] } ?? []
            let presentation = make(sessions, geometry: virtualGeometry)
            let layout = try XCTUnwrap(presentation.layout)

            XCTAssertEqual(presentation.hasContent, state != nil)
            assertVirtualNotchLayout(layout)
        }
    }

    func testTerminalExpiryUsesOneExplicitClockBoundary() throws {
        let displayedAt = now.addingTimeInterval(-5)
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

        let atBoundaryLayout = try XCTUnwrap(atBoundary.layout)
        let afterBoundaryLayout = try XCTUnwrap(afterBoundary.layout)

        XCTAssertEqual(atBoundary.floatingTerminalSessions.map(\.id), ["done"])
        XCTAssertEqual(atBoundary.nextTerminalExpiry, now)
        XCTAssertTrue(atBoundary.hasContent)
        XCTAssertEqual(atBoundaryLayout.metrics.notchWidth, physicalGeometry.width + 4)
        XCTAssertEqual(atBoundaryLayout.metrics.notchHeight, physicalGeometry.height + 3)
        XCTAssertTrue(afterBoundary.floatingTerminalSessions.isEmpty)
        XCTAssertNil(afterBoundary.nextTerminalExpiry)
        XCTAssertFalse(afterBoundary.hasContent)
        XCTAssertEqual(afterBoundaryLayout.metrics.notchWidth, physicalGeometry.width)
        XCTAssertEqual(afterBoundaryLayout.metrics.notchHeight, physicalGeometry.height)
    }

    func testVirtualTerminalBoundaryKeepsNominalDimensions() throws {
        let displayedAt = now.addingTimeInterval(-5)
        let atBoundary = make(
            [session("done", state: .done, offset: -20)],
            displayedAt: ["done": displayedAt],
            at: now,
            geometry: virtualGeometry
        )
        let afterBoundary = make(
            [session("done", state: .done, offset: -20)],
            displayedAt: ["done": displayedAt],
            at: now.addingTimeInterval(0.001),
            geometry: virtualGeometry
        )

        XCTAssertTrue(atBoundary.hasContent)
        XCTAssertEqual(atBoundary.nextTerminalExpiry, now)
        assertVirtualNotchLayout(try XCTUnwrap(atBoundary.layout))
        XCTAssertFalse(afterBoundary.hasContent)
        XCTAssertNil(afterBoundary.nextTerminalExpiry)
        assertVirtualNotchLayout(try XCTUnwrap(afterBoundary.layout))
    }

    private func make(
        _ sessions: [AgentSession],
        displayedAt: [String: Date] = [:],
        at date: Date? = nil,
        expanded: Bool = false,
        geometry: IslandDisplayGeometry? = nil
    ) -> IslandPresentation {
        IslandPresentation.make(
            sessions: sessions,
            terminalDisplayedAt: displayedAt,
            now: date ?? now,
            testMode: false,
            isExpanded: expanded,
            displayGeometry: geometry ?? physicalGeometry
        )
    }

    private func assertVirtualNotchLayout(
        _ layout: IslandPresentationLayout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(layout.metrics.notchWidth, 185, file: file, line: line)
        XCTAssertEqual(layout.metrics.notchHeight, 32, file: file, line: line)
        XCTAssertEqual(layout.notchFrame.size, CGSize(width: 185, height: 32), file: file, line: line)
        XCTAssertEqual(layout.hostFrame.size, IslandMetrics.hostSize, file: file, line: line)
        XCTAssertEqual(layout.notchFrame.maxY, layout.hostFrame.maxY, file: file, line: line)
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
