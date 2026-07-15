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
        removedRecord["harness"] = "deepseek"
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
