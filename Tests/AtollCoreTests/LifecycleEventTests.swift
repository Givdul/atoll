import XCTest
@testable import AtollCore

final class LifecycleEventTests: XCTestCase {
    func testRegistrySkipsPersistedRecordsForRemovedHarnesses() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("AtollLossyRegistry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let now = Date()
        let registry = LifecycleSessionRegistry(fileURL: fileURL)
        _ = registry.ingest(LifecycleEvent(sessionID: "known", harness: .codex, kind: .started, timestamp: now))

        let validRecord = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])?.first)
        var removedRecord = validRecord
        removedRecord["sessionID"] = "removed"
        removedRecord["harness"] = "kimi"
        try JSONSerialization.data(withJSONObject: [validRecord, removedRecord]).write(to: fileURL)

        let restored = LifecycleSessionRegistry(fileURL: fileURL)
        XCTAssertEqual(restored.sessions(now: now).map(\.id), ["codex-known"])
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtollLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testParsesCommonHookRecord() throws {
        let event = try XCTUnwrap(LifecycleEvent.parse(jsonLine: "{\"harness\":\"codex\",\"session_id\":\"abc\",\"event\":\"turn_started\",\"timestamp\":\"2026-07-10T12:00:00Z\"}"))
        XCTAssertEqual(event.harness, .codex)
        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.kind, .started)
    }

    func testNormalizesNativeHookPayload() throws {
        let event = try XCTUnwrap(
            LifecycleEvent.fromHookPayload(
                harness: .claude,
                kind: .started,
                json: "{\"session_id\":\"abc\",\"cwd\":\"/tmp/example\",\"prompt\":\"Fix auth\"}"
            )
        )

        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.projectPath, "/tmp/example")
        XCTAssertEqual(event.prompt, "Fix auth")
        XCTAssertEqual(LifecycleEvent.parse(jsonLine: try XCTUnwrap(event.jsonLine()))?.kind, .started)
    }

    func testJSONLinePreservesFractionalSecondTimestamp() throws {
        let timestamp = Date(timeIntervalSince1970: 1_784_204_645.375)
        let event = LifecycleEvent(sessionID: "fractional", harness: .codex, kind: .started, timestamp: timestamp)

        let jsonLine = try XCTUnwrap(event.jsonLine())
        XCTAssertTrue(jsonLine.contains(".375Z"))
        let parsed = try XCTUnwrap(LifecycleEvent.parse(jsonLine: jsonLine))
        XCTAssertEqual(parsed.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCursorTerminalStatusSelectsOfficialOutcome() throws {
        let outcomes: [(String, LifecycleEventKind)] = [
            ("completed", .finished),
            ("aborted", .cancelled),
            ("error", .failed)
        ]

        for (status, expectedKind) in outcomes {
            let event = try XCTUnwrap(
                LifecycleEvent.fromHookPayload(
                    harness: .cursor,
                    kind: .finished,
                    json: "{\"conversation_id\":\"cursor-\(status)\",\"status\":\"\(status)\"}"
                )
            )
            XCTAssertEqual(event.kind, expectedKind)
        }
    }

    func testCopilotSessionEndReasonSelectsOfficialOutcome() throws {
        let outcomes: [(String, LifecycleEventKind)] = [
            ("complete", .finished),
            ("error", .failed),
            ("abort", .cancelled),
            ("timeout", .failed),
            ("user_exit", .cancelled)
        ]

        for (reason, expectedKind) in outcomes {
            let event = try XCTUnwrap(
                LifecycleEvent.fromHookPayload(
                    harness: .copilot,
                    kind: .finished,
                    json: "{\"sessionId\":\"copilot-\(reason)\",\"cwd\":\"/tmp/project\",\"reason\":\"\(reason)\"}"
                )
            )
            XCTAssertEqual(event.kind, expectedKind)
            XCTAssertEqual(event.projectPath, "/tmp/project")
        }
    }

    func testRegistryPersistsTerminalEventAndExpiresStaleActiveSession() throws {
        let store = directory.appendingPathComponent("registry.json")
        let start = Date(timeIntervalSince1970: 1_000)
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .copilot, kind: .started, timestamp: start, title: "Fix auth"), now: start)
        XCTAssertEqual(registry.sessions(now: start).first?.state, .running)

        let reloaded = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        XCTAssertEqual(reloaded.sessions(now: start).first?.title, "Fix auth")
        XCTAssertTrue(reloaded.sessions(now: start.addingTimeInterval(61)).isEmpty)
    }

    func testFinishReplacesRunningWithoutProcessEvidence() {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let now = Date()
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: now), now: now)
        let sessions = registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertEqual(sessions.first?.state, .done)
        XCTAssertNil(sessions.first?.processID)
    }

    func testActiveRetryPreservesCycleStart() throws {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let retryAt = startedAt.addingTimeInterval(2)
        registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: startedAt),
            now: startedAt
        )

        let session = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: retryAt),
            now: retryAt
        ).first)

        XCTAssertEqual(session.startedAt, startedAt)
        XCTAssertEqual(session.updatedAt, retryAt)
    }

    func testNewActiveCycleAfterTerminalResetsCycleStart() throws {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let terminalAt = firstStart.addingTimeInterval(1)
        let secondStart = terminalAt.addingTimeInterval(1)
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: firstStart), now: firstStart)
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: terminalAt), now: terminalAt)

        let session = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: secondStart),
            now: secondStart
        ).first)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.startedAt, secondStart)
    }

    func testDelayedTerminalGetsFullDwellFromLocalObservation() {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let receivedAt = providerTime.addingTimeInterval(30)

        let received = registry.ingest(
            LifecycleEvent(sessionID: "delayed", harness: .codex, kind: .finished, timestamp: providerTime),
            now: receivedAt
        )

        XCTAssertEqual(received.first?.observedAt, receivedAt)
        XCTAssertEqual(registry.sessions(now: receivedAt.addingTimeInterval(5)).count, 1)
        XCTAssertTrue(registry.sessions(now: receivedAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testFutureSkewDoesNotBlockCorrectClockEventOrExtendLifetime() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 10,
            terminalTTL: 5
        )
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let futureProviderTime = receivedAt.addingTimeInterval(3_600)
        registry.ingest(
            LifecycleEvent(sessionID: "skewed", harness: .codex, kind: .started, timestamp: futureProviderTime),
            now: receivedAt
        )

        let correctedAt = receivedAt.addingTimeInterval(1)
        let corrected = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "skewed", harness: .codex, kind: .finished, timestamp: correctedAt),
            now: correctedAt
        ).first)

        XCTAssertEqual(corrected.state, .done)
        XCTAssertEqual(corrected.updatedAt, correctedAt)
        XCTAssertTrue(registry.sessions(now: correctedAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testTerminalCorrectionResetsLocalObservationAndDwell() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let firstObservedAt = providerTime.addingTimeInterval(10)
        let correctedObservedAt = firstObservedAt.addingTimeInterval(4)
        registry.ingest(
            LifecycleEvent(sessionID: "corrected", harness: .codex, kind: .finished, timestamp: providerTime),
            now: firstObservedAt
        )

        let corrected = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "corrected", harness: .codex, kind: .failed, timestamp: providerTime),
            now: correctedObservedAt
        ).first)

        XCTAssertEqual(corrected.state, .failed)
        XCTAssertEqual(corrected.observedAt, correctedObservedAt)
        XCTAssertEqual(registry.sessions(now: correctedObservedAt.addingTimeInterval(5)).count, 1)
        XCTAssertTrue(registry.sessions(now: correctedObservedAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testDuplicateTerminalDoesNotExtendDwell() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let firstObservedAt = providerTime.addingTimeInterval(10)
        registry.ingest(
            LifecycleEvent(sessionID: "duplicate", harness: .codex, kind: .finished, timestamp: providerTime),
            now: firstObservedAt
        )

        let duplicate = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "duplicate", harness: .codex, kind: .finished, timestamp: providerTime),
            now: firstObservedAt.addingTimeInterval(4)
        ).first)

        XCTAssertEqual(duplicate.observedAt, firstObservedAt)
        XCTAssertTrue(registry.sessions(now: firstObservedAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testGenericFinishCannotDowngradeSpecificTerminalOutcome() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let outcomes: [(String, LifecycleEventKind, SessionState)] = [
            ("failed", .failed, .failed),
            ("cancelled", .cancelled, .cancelled)
        ]

        for (sessionID, outcome, expectedState) in outcomes {
            registry.ingest(
                LifecycleEvent(sessionID: sessionID, harness: .codex, kind: .started, timestamp: startedAt),
                now: startedAt
            )
            registry.ingest(
                LifecycleEvent(sessionID: sessionID, harness: .codex, kind: outcome, timestamp: startedAt.addingTimeInterval(1)),
                now: startedAt.addingTimeInterval(1)
            )
            let afterCleanup = try XCTUnwrap(registry.ingest(
                LifecycleEvent(sessionID: sessionID, harness: .codex, kind: .finished, timestamp: startedAt.addingTimeInterval(2)),
                now: startedAt.addingTimeInterval(2)
            ).first { $0.id == "codex-\(sessionID)" })

            XCTAssertEqual(afterCleanup.state, expectedState)
            XCTAssertEqual(afterCleanup.observedAt, startedAt.addingTimeInterval(1))
        }
    }

    func testInvisibleTerminalTombstoneSuppressesLateCleanup() {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let terminalAt = Date(timeIntervalSince1970: 1_000)
        registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: terminalAt),
            now: terminalAt
        )
        XCTAssertTrue(registry.sessions(now: terminalAt.addingTimeInterval(5.01)).isEmpty)

        let cleanupAt = terminalAt.addingTimeInterval(10)
        let afterCleanup = registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: cleanupAt),
            now: cleanupAt
        )

        XCTAssertTrue(afterCleanup.isEmpty)

        let queuedNextStart = terminalAt.addingTimeInterval(6)
        let nextCycle = registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: queuedNextStart),
            now: cleanupAt.addingTimeInterval(1)
        )
        XCTAssertEqual(nextCycle.first?.state, .running)
        XCTAssertEqual(nextCycle.first?.startedAt, queuedNextStart)
    }

    func testLaterStartImmediatelyOpensCycleFromTerminalTombstone() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let terminalAt = Date(timeIntervalSince1970: 1_000)
        registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .failed, timestamp: terminalAt),
            now: terminalAt
        )

        let nextStart = terminalAt.addingTimeInterval(1)
        let session = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: nextStart),
            now: nextStart
        ).first)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.startedAt, nextStart)
        XCTAssertEqual(session.observedAt, nextStart)
    }

    func testEqualTimeActiveRetryCannotOverwriteTerminalButCanStartAfterDwell() throws {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let providerTime = Date(timeIntervalSince1970: 1_000)
        registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: providerTime),
            now: providerTime
        )

        let duringDwell = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: providerTime),
            now: providerTime.addingTimeInterval(1)
        ).first)
        XCTAssertEqual(duringDwell.state, .done)

        let afterDwell = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: providerTime),
            now: providerTime.addingTimeInterval(5.01)
        ).first)
        XCTAssertEqual(afterDwell.state, .running)
        XCTAssertEqual(afterDwell.startedAt, providerTime)
    }

    func testRegistryDecodesRecordsWrittenBeforeLocalObservationFields() throws {
        let store = directory.appendingPathComponent("registry.json")
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let oldRecord: [[String: Any]] = [[
            "sessionID": "legacy",
            "harness": "codex",
            "state": "running",
            "updatedAt": providerTime.timeIntervalSinceReferenceDate
        ]]
        try JSONSerialization.data(withJSONObject: oldRecord).write(to: store)

        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: .greatestFiniteMagnitude)
        let session = try XCTUnwrap(registry.sessions(now: providerTime).first)

        XCTAssertEqual(session.id, "codex-legacy")
        XCTAssertEqual(session.observedAt, providerTime)
    }

    func testTerminalOutcomesRemainDistinctAndExpireTogether() {
        let registry = LifecycleSessionRegistry(
            fileURL: directory.appendingPathComponent("registry.json"),
            activeTTL: 60,
            terminalTTL: 5
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let terminalAt = startedAt.addingTimeInterval(1)
        let outcomes: [(String, LifecycleEventKind, SessionState)] = [
            ("finished", .finished, .done),
            ("failed", .failed, .failed),
            ("cancelled", .cancelled, .cancelled)
        ]

        for (sessionID, kind, _) in outcomes {
            registry.ingest(
                LifecycleEvent(sessionID: sessionID, harness: .codex, kind: .started, timestamp: startedAt),
                now: startedAt
            )
            registry.ingest(
                LifecycleEvent(sessionID: sessionID, harness: .codex, kind: kind, timestamp: terminalAt),
                now: terminalAt
            )
        }

        let statesByID = Dictionary(uniqueKeysWithValues: registry.sessions(now: terminalAt).map { ($0.id, $0.state) })
        for (sessionID, _, expectedState) in outcomes {
            XCTAssertEqual(statesByID["codex-\(sessionID)"], expectedState)
        }
        XCTAssertEqual(registry.sessions(now: terminalAt.addingTimeInterval(5)).count, outcomes.count)
        XCTAssertTrue(registry.sessions(now: terminalAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testOldReplayedStartDoesNotRecreateRunningSession() {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"), activeTTL: 60)
        let old = Date().addingTimeInterval(-61)
        let sessions = registry.ingest(LifecycleEvent(sessionID: "old", harness: .copilot, kind: .started, timestamp: old))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testQueuePreservesEventsUntilTheAppDrainsThem() throws {
        let queue = LifecycleEventQueue(homeDirectory: directory)
        queue.enqueue(LifecycleEvent(sessionID: "one", harness: .copilot, kind: .started))

        XCTAssertEqual(queue.drain().map(\.sessionID), ["one"])
        XCTAssertTrue(queue.drain().isEmpty)
    }
}
