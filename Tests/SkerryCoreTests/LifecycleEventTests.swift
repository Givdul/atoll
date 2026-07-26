import XCTest
@testable import SkerryCore

final class LifecycleEventTests: XCTestCase {
    func testRegistrySkipsPersistedRecordsForRemovedHarnesses() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SkerryLossyRegistry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let now = Date()
        let registry = LifecycleSessionRegistry(fileURL: fileURL)
        _ = registry.ingest(LifecycleEvent(sessionID: "known", harness: .codex, kind: .started, timestamp: now))

        let validRecord = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])?.first)
        var removedRecord = validRecord
        removedRecord["sessionID"] = "removed"
        removedRecord["harness"] = "gemini"
        try JSONSerialization.data(withJSONObject: [validRecord, removedRecord]).write(to: fileURL)

        let restored = LifecycleSessionRegistry(fileURL: fileURL)
        XCTAssertEqual(restored.sessions(now: now).map(\.id), ["codex-known"])
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkerryLifecycleTests-\(UUID().uuidString)", isDirectory: true)
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

    func testNormalizesHookStateWithoutRetainingSensitiveContent() throws {
        let sensitive = "SENSITIVE-CONTENT-7B94E6"
        let fullPath = "/Users/private-owner/Projects/Skerry-Privacy"
        let event = try XCTUnwrap(
            LifecycleEvent.fromHookPayload(
                harness: .cursor,
                kind: .finished,
                json: """
                    {"conversation_id":"abc","cwd":"\(fullPath)","status":"error","prompt":"\(sensitive)","title":"\(sensitive)","detail":"\(sensitive)","message":"\(sensitive)","reason":"\(sensitive)","response":"\(sensitive)","command":"\(sensitive)","transcript":"\(sensitive)","diff":"\(sensitive)","environment":"\(sensitive)","model":"\(sensitive)"}
                    """
            )
        )

        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertEqual(event.kind, .failed)
        XCTAssertEqual(event.label, "Skerry-Privacy")
        XCTAssertNotNil(event.deliveryID)

        let wire = try XCTUnwrap(event.jsonLine())
        XCTAssertFalse(wire.contains(sensitive))
        XCTAssertFalse(wire.contains(fullPath))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any]
        )
        XCTAssertTrue(Set(object.keys).isSubset(of: [
            "delivery_id", "event", "harness", "label", "origin_bundle_identifier",
            "origin_process_id", "session_id", "timestamp"
        ]))
        XCTAssertEqual(LifecycleEvent.parse(jsonLine: wire)?.kind, .failed)
    }

    func testHookPayloadUsesProviderFallbackForUnusableWorkingDirectories() throws {
        for workingDirectory in [nil, "", "/", "relative/project", "~"] as [String?] {
            var payload: [String: Any] = ["session_id": UUID().uuidString]
            payload["cwd"] = workingDirectory
            let data = try JSONSerialization.data(withJSONObject: payload)
            let event = try XCTUnwrap(LifecycleEvent.fromHookPayload(
                harness: .claude,
                kind: .started,
                json: try XCTUnwrap(String(data: data, encoding: .utf8))
            ))
            XCTAssertEqual(event.label, "Claude Code session")
        }
    }

    func testQueueAndRegistryPersistOnlyPrivacySafeLifecycleMetadata() throws {
        let sensitive = "QUEUE-SENSITIVE-24A6D1"
        let fullPath = "/Users/private-owner/Projects/Queue-Project"
        let event = try XCTUnwrap(LifecycleEvent.fromHookPayload(
            harness: .codex,
            kind: .started,
            json: "{\"session_id\":\"private\",\"cwd\":\"\(fullPath)\",\"prompt\":\"\(sensitive)\",\"message\":\"\(sensitive)\",\"model\":\"\(sensitive)\"}"
        ))
        let queue = LifecycleEventQueue(homeDirectory: directory)
        let receipt = try XCTUnwrap(queue.enqueue(event))
        let queueDirectory = directory.appendingPathComponent(".skerry/lifecycle-events", isDirectory: true)
        let queueFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil).first
        )
        let queuedData = try XCTUnwrap(String(data: Data(contentsOf: queueFile), encoding: .utf8))

        let store = directory.appendingPathComponent("registry.json")
        let registry = LifecycleSessionRegistry(fileURL: store)
        let session = try XCTUnwrap(registry.ingestPersisting(receipt.event)?.first)
        let registryData = try XCTUnwrap(String(data: Data(contentsOf: store), encoding: .utf8))

        XCTAssertEqual(session.label, "Queue-Project")
        for persisted in [queuedData, registryData] {
            XCTAssertFalse(persisted.contains(sensitive))
            XCTAssertFalse(persisted.contains(fullPath))
            XCTAssertTrue(persisted.contains("Queue-Project"))
        }
    }

    func testLegacyQueueRecordDecodesWithoutCopyingSensitiveContent() throws {
        let sensitive = "LEGACY-QUEUE-SENSITIVE-9C2A"
        let fullPath = "/Users/private-owner/Projects/Legacy-Queue"
        let queueDirectory = directory.appendingPathComponent(".skerry/lifecycle-events", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let legacyFile = queueDirectory.appendingPathComponent("legacy.json")
        let receivedAt = Date().addingTimeInterval(-3_600)
        try "{\"harness\":\"claude\",\"session_id\":\"legacy-queue\",\"event\":\"started\",\"cwd\":\"\(fullPath)\",\"prompt\":\"\(sensitive)\",\"message\":\"\(sensitive)\",\"model\":\"\(sensitive)\"}"
            .write(to: legacyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: receivedAt], ofItemAtPath: legacyFile.path)

        let queue = LifecycleEventQueue(homeDirectory: directory)
        let receipt = try XCTUnwrap(queue.pendingEvents().first)
        XCTAssertEqual(receipt.event.label, "Legacy-Queue")
        XCTAssertEqual(receipt.receivedAt.timeIntervalSince1970, receivedAt.timeIntervalSince1970, accuracy: 0.01)
        let migratedQueueData = try XCTUnwrap(String(data: Data(contentsOf: legacyFile), encoding: .utf8))
        XCTAssertFalse(migratedQueueData.contains(sensitive))
        XCTAssertFalse(migratedQueueData.contains(fullPath))
        XCTAssertTrue(migratedQueueData.contains("Legacy-Queue"))

        let store = directory.appendingPathComponent("registry.json")
        let registry = LifecycleSessionRegistry(fileURL: store)
        XCTAssertNotNil(registry.ingestPersisting(receipt.event))
        XCTAssertTrue(queue.acknowledge(receipt))

        let registryData = try XCTUnwrap(String(data: Data(contentsOf: store), encoding: .utf8))
        XCTAssertFalse(registryData.contains(sensitive))
        XCTAssertFalse(registryData.contains(fullPath))
        XCTAssertTrue(registryData.contains("Legacy-Queue"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testJSONLinePreservesFractionalSecondTimestamp() throws {
        let timestamp = Date(timeIntervalSince1970: 1_784_204_645.375)
        let event = LifecycleEvent(sessionID: "fractional", harness: .codex, kind: .started, timestamp: timestamp)

        let jsonLine = try XCTUnwrap(event.jsonLine())
        XCTAssertTrue(jsonLine.contains(".375Z"))
        let parsed = try XCTUnwrap(LifecycleEvent.parse(jsonLine: jsonLine))
        XCTAssertEqual(parsed.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(parsed.deliveryID, event.deliveryID)
        XCTAssertEqual(parsed.deliveryIdentity, event.deliveryIdentity)
    }

    func testJSONLinePreservesOriginApplication() throws {
        let event = LifecycleEvent(
            sessionID: "origin",
            harness: .codex,
            kind: .started,
            originProcessID: 123,
            originBundleIdentifier: "com.apple.Terminal"
        )

        let parsed = try XCTUnwrap(
            LifecycleEvent.parse(jsonLine: try XCTUnwrap(event.jsonLine()))
        )
        XCTAssertEqual(parsed.originProcessID, 123)
        XCTAssertEqual(parsed.originBundleIdentifier, "com.apple.Terminal")
    }

    func testIncompleteOriginMetadataIsDroppedFromQueueAndLegacyRegistry() throws {
        let queue = LifecycleEventQueue(homeDirectory: directory)
        XCTAssertNotNil(queue.enqueue(LifecycleEvent(
            sessionID: "pid-only",
            harness: .codex,
            kind: .started,
            originProcessID: 123
        )))
        XCTAssertNotNil(queue.enqueue(LifecycleEvent(
            sessionID: "bundle-only",
            harness: .codex,
            kind: .started,
            originBundleIdentifier: "com.apple.Terminal"
        )))
        let queuedEvents = queue.pendingEvents().map(\.event)
        XCTAssertEqual(queuedEvents.count, 2)
        XCTAssertTrue(queuedEvents.allSatisfy {
            $0.originProcessID == nil && $0.originBundleIdentifier == nil
        })

        let now = Date()
        let store = directory.appendingPathComponent("legacy-registry.json")
        let legacyRecords: [[String: Any]] = [
            [
                "sessionID": "pid-only",
                "harness": "codex",
                "state": "running",
                "updatedAt": now.timeIntervalSinceReferenceDate,
                "originProcessID": 123
            ],
            [
                "sessionID": "bundle-only",
                "harness": "codex",
                "state": "running",
                "updatedAt": now.timeIntervalSinceReferenceDate,
                "originBundleIdentifier": "com.apple.Terminal"
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacyRecords).write(to: store)

        let sessions = LifecycleSessionRegistry(fileURL: store).sessions(now: now)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy {
            $0.originProcessID == nil && $0.originBundleIdentifier == nil
        })
        let migrated = try XCTUnwrap(String(data: Data(contentsOf: store), encoding: .utf8))
        XCTAssertFalse(migrated.contains("originProcessID"))
        XCTAssertFalse(migrated.contains("originBundleIdentifier"))
    }

    func testTransportIdentityDistinguishesIdenticalInvocationsAndSurvivesRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let first = LifecycleEvent(
            sessionID: "identical",
            harness: .codex,
            kind: .started,
            timestamp: timestamp
        )
        let second = LifecycleEvent(
            sessionID: "identical",
            harness: .codex,
            kind: .started,
            timestamp: timestamp
        )

        XCTAssertNotEqual(first.deliveryID, second.deliveryID)
        XCTAssertNotEqual(first.deliveryIdentity, second.deliveryIdentity)

        let reparsed = try XCTUnwrap(
            LifecycleEvent.parse(jsonLine: try XCTUnwrap(first.jsonLine()))
        )
        XCTAssertEqual(reparsed.deliveryID, first.deliveryID)
        XCTAssertEqual(reparsed.deliveryIdentity, first.deliveryIdentity)
        XCTAssertEqual(
            LifecycleEvent.migratedDeliveryIdentity(first.deliveryIdentity),
            first.deliveryIdentity
        )
    }

    func testLegacyWireEventWithoutTransportIdentityUsesStableCanonicalFallback() throws {
        let line = "{\"harness\":\"codex\",\"session_id\":\"legacy-wire\",\"event\":\"started\",\"timestamp\":\"2026-07-10T12:00:00Z\"}"
        let firstParse = try XCTUnwrap(LifecycleEvent.parse(jsonLine: line))
        let secondParse = try XCTUnwrap(LifecycleEvent.parse(jsonLine: line))

        XCTAssertNil(firstParse.deliveryID)
        XCTAssertNil(secondParse.deliveryID)
        XCTAssertEqual(firstParse.deliveryIdentity, secondParse.deliveryIdentity)
    }

    func testMalformedLegacyDeliveryDigestIsRehashed() {
        let malformed = "sha256:" + String(repeating: "x", count: 64)
        let migrated = LifecycleEvent.migratedDeliveryIdentity(malformed)

        XCTAssertNotEqual(migrated, malformed)
        XCTAssertEqual(migrated.count, 71)
        XCTAssertTrue(migrated.hasPrefix("sha256:"))
        XCTAssertTrue(migrated.dropFirst(7).allSatisfy(\.isHexDigit))
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

    func testRegistryPersistsTerminalEventAndExpiresStaleActiveSession() throws {
        let store = directory.appendingPathComponent("registry.json")
        let start = Date(timeIntervalSince1970: 1_000)
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: start, label: "Skerry-Privacy"), now: start)
        XCTAssertEqual(registry.sessions(now: start).first?.state, .running)

        let reloaded = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        XCTAssertEqual(reloaded.sessions(now: start).first?.label, "Skerry-Privacy")
        XCTAssertEqual(
            reloaded.ingest(
                LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: start.addingTimeInterval(1)),
                now: start.addingTimeInterval(1)
            ).first?.label,
            "Skerry-Privacy"
        )
        XCTAssertTrue(reloaded.sessions(now: start.addingTimeInterval(61)).isEmpty)
    }

    func testRegistryPersistsOriginApplicationAcrossRestart() throws {
        let store = directory.appendingPathComponent("registry.json")
        let now = Date()
        let registry = LifecycleSessionRegistry(fileURL: store)
        registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .started,
                timestamp: now,
                originProcessID: 123,
                originBundleIdentifier: "com.apple.Terminal"
            ),
            now: now
        )

        let session = try XCTUnwrap(
            LifecycleSessionRegistry(fileURL: store).sessions(now: now).first
        )
        XCTAssertEqual(session.originProcessID, 123)
        XCTAssertEqual(session.originBundleIdentifier, "com.apple.Terminal")
    }

    func testLaterEventWithoutOriginPreservesOriginApplication() throws {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let now = Date()
        registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .started,
                timestamp: now,
                originProcessID: 123,
                originBundleIdentifier: "com.apple.Terminal"
            ),
            now: now
        )

        let session = try XCTUnwrap(registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .needsInput,
                timestamp: now.addingTimeInterval(1)
            ),
            now: now.addingTimeInterval(1)
        ).first)

        XCTAssertEqual(session.originProcessID, 123)
        XCTAssertEqual(session.originBundleIdentifier, "com.apple.Terminal")
    }

    func testLaterSameStateEventReplacesOriginOnlyWithCompleteVerifiedPair() throws {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let now = Date()
        registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .finished,
                timestamp: now,
                originProcessID: 123,
                originBundleIdentifier: "com.apple.Terminal"
            ),
            now: now
        )

        let incomplete = try XCTUnwrap(registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .finished,
                timestamp: now.addingTimeInterval(1),
                originProcessID: 456
            ),
            now: now.addingTimeInterval(1)
        ).first)
        XCTAssertEqual(incomplete.originProcessID, 123)
        XCTAssertEqual(incomplete.originBundleIdentifier, "com.apple.Terminal")

        let replaced = try XCTUnwrap(registry.ingest(
            LifecycleEvent(
                sessionID: "origin",
                harness: .codex,
                kind: .finished,
                timestamp: now.addingTimeInterval(2),
                originProcessID: 456,
                originBundleIdentifier: "com.example.Editor"
            ),
            now: now.addingTimeInterval(2)
        ).first)
        XCTAssertEqual(replaced.originProcessID, 456)
        XCTAssertEqual(replaced.originBundleIdentifier, "com.example.Editor")
    }

    func testFinishReplacesRunningWithoutProcessEvidence() {
        let registry = LifecycleSessionRegistry(fileURL: directory.appendingPathComponent("registry.json"))
        let now = Date()
        registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started, timestamp: now), now: now)
        let sessions = registry.ingest(LifecycleEvent(sessionID: "one", harness: .codex, kind: .finished, timestamp: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertEqual(sessions.first?.state, .done)
        XCTAssertNil(sessions.first?.originProcessID)
        XCTAssertNil(sessions.first?.originBundleIdentifier)
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

    func testExactActiveReplayDoesNotRefreshLocalLiveness() throws {
        let store = directory.appendingPathComponent("registry.json")
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let firstObservedAt = providerTime.addingTimeInterval(10)
        let event = LifecycleEvent(
            sessionID: "replayed",
            harness: .codex,
            kind: .started,
            timestamp: providerTime
        )
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        _ = registry.ingest(event, now: firstObservedAt)

        let replayed = try XCTUnwrap(
            registry.ingest(event, now: firstObservedAt.addingTimeInterval(50)).first
        )
        XCTAssertEqual(replayed.observedAt, firstObservedAt)

        let reloaded = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        XCTAssertTrue(reloaded.ingest(event, now: firstObservedAt.addingTimeInterval(61)).isEmpty)
    }

    func testQueuedActiveReplayAfterReloadKeepsOriginalObservationTime() throws {
        let store = directory.appendingPathComponent("registry.json")
        let queue = LifecycleEventQueue(homeDirectory: directory)
        let providerTime = Date(timeIntervalSince1970: 1_000.123_456)
        let firstObservedAt = providerTime.addingTimeInterval(10)
        let receipt = try XCTUnwrap(queue.enqueue(LifecycleEvent(
            sessionID: "crash-window",
            harness: .codex,
            kind: .started,
            timestamp: providerTime
        )))
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        _ = try XCTUnwrap(registry.ingestPersisting(receipt.event, now: firstObservedAt))

        let reparsedReceipt = try XCTUnwrap(queue.pendingEvents().first)
        let reloadedRegistry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        let replayed = try XCTUnwrap(
            reloadedRegistry.ingestPersisting(
                reparsedReceipt.event,
                now: firstObservedAt.addingTimeInterval(50)
            )?.first
        )

        XCTAssertEqual(replayed.observedAt, firstObservedAt)
    }

    func testLegacyLastEventKeyMigratesIntoDigestLedger() throws {
        let store = directory.appendingPathComponent("registry.json")
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let observedAt = providerTime.addingTimeInterval(10)
        let sensitive = "LEGACY-SENSITIVE-4E3D90"
        let fullPath = "/Users/private-owner/Projects/Legacy-Project"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyWire = """
            {"harness":"codex","session_id":"legacy-delivery-key","event":"started","timestamp":"\(formatter.string(from: providerTime))","title":"\(sensitive)","detail":"\(sensitive)","prompt":"\(sensitive)","project_path":"\(fullPath)","model":"\(sensitive)"}
            """
        let event = try XCTUnwrap(LifecycleEvent.parse(jsonLine: legacyWire))
        let legacyRecord: [[String: Any]] = [[
            "sessionID": event.sessionID,
            "harness": event.harness.rawValue,
            "state": SessionState.running.rawValue,
            "updatedAt": providerTime.timeIntervalSinceReferenceDate,
            "observedAt": observedAt.timeIntervalSinceReferenceDate,
            "orderingAt": providerTime.timeIntervalSinceReferenceDate,
            "startedAt": providerTime.timeIntervalSinceReferenceDate,
            "title": sensitive,
            "detail": sensitive,
            "prompt": sensitive,
            "projectPath": fullPath,
            "model": sensitive,
            "lastEventKey": legacyWire
        ]]
        try JSONSerialization.data(withJSONObject: legacyRecord).write(to: store)

        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        XCTAssertEqual(registry.sessions(now: observedAt).first?.observedAt, observedAt)
        let scrubbedOnLoad = try XCTUnwrap(String(data: Data(contentsOf: store), encoding: .utf8))
        XCTAssertFalse(scrubbedOnLoad.contains(sensitive))
        XCTAssertFalse(scrubbedOnLoad.contains(fullPath))

        let replayed = try XCTUnwrap(
            registry.ingest(event, now: observedAt.addingTimeInterval(20)).first
        )
        XCTAssertEqual(replayed.observedAt, observedAt)

        let migrated = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]]
        )
        XCTAssertNil(migrated.first?["lastEventKey"])
        XCTAssertEqual(migrated.first?["label"] as? String, "Codex session")
        let identities = try XCTUnwrap(migrated.first?["recentDeliveries"] as? [[String: Any]])
        XCTAssertEqual(identities.count, 1)
        XCTAssertTrue((identities.first?["identity"] as? String)?.hasPrefix("sha256:") == true)
        let migratedData = try XCTUnwrap(String(data: Data(contentsOf: store), encoding: .utf8))
        XCTAssertFalse(migratedData.contains(sensitive))
        XCTAssertFalse(migratedData.contains(fullPath))
    }

    func testLegacyQueueReplayMatchesPreexistingDigestLedgerAfterSanitization() throws {
        let store = directory.appendingPathComponent("registry.json")
        let providerTime = Date(timeIntervalSince1970: 1_000)
        let observedAt = providerTime.addingTimeInterval(10)
        let sensitive = "LEGACY-REPLAY-SENSITIVE-7D5B"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacyWire = """
            {"event":"started","harness":"codex","prompt":"\(sensitive)","session_id":"legacy-replay","timestamp":"\(formatter.string(from: providerTime))"}
            """
        let legacyIdentity = LifecycleEvent.deliveryIdentity(forCanonicalRepresentation: legacyWire)
        let legacyRecord: [[String: Any]] = [[
            "sessionID": "legacy-replay",
            "harness": "codex",
            "state": "running",
            "updatedAt": providerTime.timeIntervalSinceReferenceDate,
            "observedAt": observedAt.timeIntervalSinceReferenceDate,
            "orderingAt": providerTime.timeIntervalSinceReferenceDate,
            "startedAt": providerTime.timeIntervalSinceReferenceDate,
            "recentDeliveries": [[
                "identity": legacyIdentity,
                "receivedAt": observedAt.timeIntervalSinceReferenceDate
            ]]
        ]]
        try JSONSerialization.data(withJSONObject: legacyRecord).write(to: store)

        let queueDirectory = directory.appendingPathComponent(".skerry/lifecycle-events", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let legacyFile = queueDirectory.appendingPathComponent("legacy-replay.json")
        try legacyWire.write(to: legacyFile, atomically: true, encoding: .utf8)

        let queue = LifecycleEventQueue(homeDirectory: directory)
        let receipt = try XCTUnwrap(queue.pendingEvents().first)
        XCTAssertEqual(receipt.event.deliveryIdentity, legacyIdentity)
        let sanitizedQueue = try XCTUnwrap(String(data: Data(contentsOf: legacyFile), encoding: .utf8))
        XCTAssertFalse(sanitizedQueue.contains(sensitive))
        XCTAssertTrue(sanitizedQueue.contains(legacyIdentity))

        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        let replayed = try XCTUnwrap(
            registry.ingest(receipt.event, now: observedAt.addingTimeInterval(20)).first
        )
        XCTAssertEqual(replayed.observedAt, observedAt)
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
        let started = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "skewed", harness: .codex, kind: .started, timestamp: futureProviderTime),
            now: receivedAt
        ).first)
        XCTAssertEqual(started.updatedAt, receivedAt)
        XCTAssertEqual(started.startedAt, receivedAt)

        let correctedAt = receivedAt.addingTimeInterval(1)
        let corrected = try XCTUnwrap(registry.ingest(
            LifecycleEvent(sessionID: "skewed", harness: .codex, kind: .finished, timestamp: correctedAt),
            now: correctedAt
        ).first)

        XCTAssertEqual(corrected.state, .done)
        XCTAssertEqual(corrected.updatedAt, correctedAt)
        XCTAssertTrue(registry.sessions(now: correctedAt.addingTimeInterval(5.01)).isEmpty)
    }

    func testNonAdjacentFutureSkewReplayCannotReopenTerminalState() throws {
        let store = directory.appendingPathComponent("registry.json")
        let queue = LifecycleEventQueue(homeDirectory: directory)
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let futureStart = LifecycleEvent(
            sessionID: "future-replay",
            harness: .codex,
            kind: .started,
            timestamp: receivedAt.addingTimeInterval(3_600)
        )
        let receipt = try XCTUnwrap(queue.enqueue(futureStart))
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        _ = try XCTUnwrap(registry.ingestPersisting(receipt.event, now: receivedAt))

        let terminalAt = receivedAt.addingTimeInterval(1)
        _ = try XCTUnwrap(registry.ingestPersisting(
            LifecycleEvent(
                sessionID: "future-replay",
                harness: .codex,
                kind: .finished,
                timestamp: terminalAt
            ),
            now: terminalAt
        ))

        let reparsedReceipt = try XCTUnwrap(queue.pendingEvents().first)
        let reloaded = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        let replayed = try XCTUnwrap(
            reloaded.ingestPersisting(
                reparsedReceipt.event,
                now: receivedAt.addingTimeInterval(2)
            )?.first
        )

        XCTAssertEqual(replayed.state, .done)
        XCTAssertEqual(replayed.updatedAt, terminalAt)
        XCTAssertEqual(replayed.observedAt, terminalAt)
    }

    func testNoOpActiveRetryCannotBecomeValidAfterTerminalDwell() throws {
        let store = directory.appendingPathComponent("registry.json")
        let terminalAt = Date(timeIntervalSince1970: 1_000)
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        _ = try XCTUnwrap(registry.ingestPersisting(
            LifecycleEvent(
                sessionID: "no-op-replay",
                harness: .codex,
                kind: .finished,
                timestamp: terminalAt
            ),
            now: terminalAt
        ))

        let equalTimeRetry = LifecycleEvent(
            sessionID: "no-op-replay",
            harness: .codex,
            kind: .started,
            timestamp: terminalAt
        )
        let duringDwell = try XCTUnwrap(
            registry.ingestPersisting(
                equalTimeRetry,
                now: terminalAt.addingTimeInterval(1)
            )?.first
        )
        XCTAssertEqual(duringDwell.state, .done)

        let reloaded = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        let afterDwell = try XCTUnwrap(
            reloaded.ingestPersisting(
                equalTimeRetry,
                now: terminalAt.addingTimeInterval(6)
            )
        )
        XCTAssertTrue(afterDwell.isEmpty)
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

    func testEqualTimeActiveRetryCannotOverwriteTerminalButDistinctStartCanBeginAfterDwell() throws {
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

        let ignoredRetry = LifecycleEvent(
            sessionID: "one",
            harness: .codex,
            kind: .started,
            timestamp: providerTime
        )
        let duringDwell = try XCTUnwrap(
            registry.ingest(ignoredRetry, now: providerTime.addingTimeInterval(1)).first
        )
        XCTAssertEqual(duringDwell.state, .done)

        let distinctInvocation = LifecycleEvent(
            sessionID: "one",
            harness: .codex,
            kind: .started,
            timestamp: providerTime
        )
        XCTAssertNotEqual(distinctInvocation.deliveryIdentity, ignoredRetry.deliveryIdentity)
        let afterDwell = try XCTUnwrap(registry.ingest(
            distinctInvocation,
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
        XCTAssertNil(session.originProcessID)
        XCTAssertNil(session.originBundleIdentifier)
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
        let sessions = registry.ingest(LifecycleEvent(sessionID: "old", harness: .codex, kind: .started, timestamp: old))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPersistingIngestRollsBackAndCanBeRetriedAfterWriteFailure() throws {
        let store = directory.appendingPathComponent("registry.json", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let registry = LifecycleSessionRegistry(fileURL: store)
        let queue = LifecycleEventQueue(
            homeDirectory: directory.appendingPathComponent("queue-home", isDirectory: true)
        )
        let now = Date()
        let event = LifecycleEvent(sessionID: "retry", harness: .codex, kind: .started, timestamp: now)
        let receipt = try XCTUnwrap(queue.enqueue(event))

        XCTAssertNil(registry.ingestPersisting(receipt.event, now: now))
        XCTAssertTrue(registry.sessions(now: now).isEmpty)
        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["retry"])

        try FileManager.default.removeItem(at: store)
        let persisted = try XCTUnwrap(registry.ingestPersisting(receipt.event, now: now))
        XCTAssertEqual(persisted.map(\.id), ["codex-retry"])
        XCTAssertTrue(queue.acknowledge(receipt))
        XCTAssertTrue(queue.pendingEvents().isEmpty)

        let reloaded = LifecycleSessionRegistry(fileURL: store)
        XCTAssertEqual(reloaded.sessions(now: now).map(\.id), ["codex-retry"])
    }

    func testQueuePreservesEventsUntilReceiptIsAcknowledged() throws {
        let queue = LifecycleEventQueue(homeDirectory: directory)
        let receipt = try XCTUnwrap(
            queue.enqueue(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started))
        )

        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["one"])
        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["one"])

        XCTAssertTrue(queue.acknowledge(receipt))
        XCTAssertTrue(queue.acknowledge(receipt))
        XCTAssertTrue(queue.pendingEvents().isEmpty)
    }

    func testQueueAcknowledgesOnlyReceiptFromSameDirectory() throws {
        let firstHome = directory.appendingPathComponent("first", isDirectory: true)
        let secondHome = directory.appendingPathComponent("second", isDirectory: true)
        let firstQueue = LifecycleEventQueue(homeDirectory: firstHome)
        let secondQueue = LifecycleEventQueue(homeDirectory: secondHome)
        let receipt = try XCTUnwrap(
            firstQueue.enqueue(LifecycleEvent(sessionID: "one", harness: .codex, kind: .started))
        )

        XCTAssertFalse(secondQueue.acknowledge(receipt))
        XCTAssertEqual(firstQueue.pendingEvents().map(\.event.sessionID), ["one"])
    }

    func testQueueRemovesMalformedFilesWithoutDroppingValidEvents() throws {
        let queue = LifecycleEventQueue(homeDirectory: directory)
        queue.enqueue(LifecycleEvent(sessionID: "valid", harness: .claude, kind: .needsInput))

        let queueDirectory = directory.appendingPathComponent(".skerry/lifecycle-events", isDirectory: true)
        let malformedFile = queueDirectory.appendingPathComponent("malformed.json")
        try "{not-json".write(to: malformedFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["valid"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedFile.path))
        XCTAssertEqual(queue.pendingEvents().map(\.event.kind), [.needsInput])
    }

    func testQueueRejectsInternalHarnessAndRemovesLegacyRecord() throws {
        let queue = LifecycleEventQueue(homeDirectory: directory)
        XCTAssertNil(queue.enqueue(LifecycleEvent(sessionID: "internal", harness: .skerry, kind: .started)))

        let queueDirectory = directory.appendingPathComponent(".skerry/lifecycle-events", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let legacyFile = queueDirectory.appendingPathComponent("internal.json")
        let event = LifecycleEvent(sessionID: "internal", harness: .skerry, kind: .started)
        try XCTUnwrap(event.jsonLine()).write(to: legacyFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(queue.pendingEvents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testDeliveryIdentityLedgerHasExplicitSizeAndTimeBounds() throws {
        let store = directory.appendingPathComponent("registry.json")
        let registry = LifecycleSessionRegistry(fileURL: store, activeTTL: 60, terminalTTL: 5)
        let start = Date(timeIntervalSince1970: 1_000)
        let eventCount = LifecycleSessionRegistry.maximumRecentDeliveryIdentities + 1

        for index in 0..<eventCount {
            let timestamp = start.addingTimeInterval(TimeInterval(index))
            XCTAssertNotNil(registry.ingestPersisting(
                LifecycleEvent(
                    sessionID: "bounded-ledger",
                    harness: .codex,
                    kind: .started,
                    timestamp: timestamp
                ),
                now: timestamp
            ))
        }

        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]]
        )
        let deliveries = try XCTUnwrap(persisted.first?["recentDeliveries"] as? [[String: Any]])
        XCTAssertEqual(deliveries.count, LifecycleSessionRegistry.maximumRecentDeliveryIdentities)
        XCTAssertTrue(deliveries.allSatisfy {
            ($0["identity"] as? String)?.hasPrefix("sha256:") == true
        })

        let expiration = start.addingTimeInterval(
            TimeInterval(eventCount) + LifecycleSessionRegistry.deliveryIdentityRetention + 1
        )
        XCTAssertTrue(registry.sessions(now: expiration).isEmpty)
        let expired = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]]
        )
        XCTAssertTrue(expired.isEmpty)
    }
}
