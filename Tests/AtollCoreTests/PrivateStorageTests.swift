import XCTest
@testable import AtollCore

final class PrivateStorageTests: XCTestCase {
    private enum PermissionFailure: Error {
        case denied
    }

    private var homeDirectory: URL!

    override func setUpWithError() throws {
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtollPrivateStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: homeDirectory)
    }

    func testQueueCreatesAndRepairsUserOnlyModes() throws {
        let queue = LifecycleEventQueue(homeDirectory: homeDirectory)
        XCTAssertNotNil(queue.enqueue(
            LifecycleEvent(sessionID: "private", harness: .codex, kind: .started)
        ))

        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        let queueDirectory = root.appendingPathComponent("lifecycle-events", isDirectory: true)
        let eventFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: queueDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: queueDirectory), 0o700)
        XCTAssertEqual(try permissions(of: eventFile), 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: queueDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: eventFile.path)

        XCTAssertEqual(queue.pendingEvents().map(\.event.sessionID), ["private"])
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: queueDirectory), 0o700)
        XCTAssertEqual(try permissions(of: eventFile), 0o600)
    }

    func testRegistryCreatesAndRepairsUserOnlyModes() throws {
        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        let store = root.appendingPathComponent("lifecycle-sessions.json")
        let now = Date()
        let registry = LifecycleSessionRegistry(fileURL: store)
        XCTAssertNotNil(registry.ingestPersisting(
            LifecycleEvent(sessionID: "private", harness: .codex, kind: .started, timestamp: now),
            now: now
        ))
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: store), 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)

        let reloaded = LifecycleSessionRegistry(fileURL: store)
        XCTAssertEqual(reloaded.sessions(now: now).first?.state, .running)
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: store), 0o600)
    }

    func testRegistryWriteRollsBackWhenFileHardeningFails() throws {
        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        let store = root.appendingPathComponent("lifecycle-sessions.json")
        let now = Date()
        let original = LifecycleSessionRegistry(fileURL: store)
        XCTAssertNotNil(original.ingestPersisting(
            LifecycleEvent(sessionID: "transaction", harness: .codex, kind: .started, timestamp: now),
            now: now
        ))
        let originalData = try Data(contentsOf: store)

        let failing = LifecycleSessionRegistry(
            fileURL: store,
            filePermissionSetter: { _ in throw PermissionFailure.denied }
        )
        XCTAssertNil(failing.ingestPersisting(
            LifecycleEvent(
                sessionID: "transaction",
                harness: .codex,
                kind: .finished,
                timestamp: now.addingTimeInterval(1)
            ),
            now: now.addingTimeInterval(1)
        ))

        XCTAssertEqual(failing.sessions(now: now.addingTimeInterval(1)).first?.state, .running)
        XCTAssertEqual(try Data(contentsOf: store), originalData)
        XCTAssertEqual(try permissions(of: store), 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.hasSuffix(".tmp")
        })
    }

    func testSettingsHardensMalformedFileWithoutChangingItsContents() throws {
        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        let config = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let malformed = Data("not json\n".utf8)
        try malformed.write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)

        let settings = SettingsStore(homeDirectory: homeDirectory).load()

        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(try Data(contentsOf: config), malformed)
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: config), 0o600)
    }

    func testSettingsSaveUsesUserOnlyModes() throws {
        let store = SettingsStore(homeDirectory: homeDirectory)
        store.save(AtollSettings(
            enabled: false,
            notificationsEnabled: true,
            screenMode: "primary",
            testMode: true
        ))

        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        let config = root.appendingPathComponent("config.json")
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: config), 0o600)
        let settings = store.load()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.notificationsEnabled)
    }

    func testLegacySettingsDefaultNotificationsOff() throws {
        let root = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"enabled":false,"screenMode":"primary","testMode":true}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))

        XCTAssertFalse(SettingsStore(homeDirectory: homeDirectory).load().notificationsEnabled)
    }

    func testAtomicWriteSupportsAnExistingPrivateParentDirectory() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtollPrivateAtomic-\(UUID().uuidString).json")

        let data = Data("private".utf8)
        do {
            try PrivateStorage.writeAtomically(data, to: target)
        } catch {
            XCTFail("Atomic write failed: \(error)")
            return
        }

        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(try permissions(of: target), 0o600)
        try FileManager.default.removeItem(at: target)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
