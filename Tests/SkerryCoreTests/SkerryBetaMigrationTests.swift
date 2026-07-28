import XCTest
@testable import SkerryCore

final class SkerryBetaMigrationTests: XCTestCase {
    func testMigrationIsOneShotAndDoesNotReseedConsumedBetaEvents() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryBetaMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = UserDefaults.standard
        let suffix = UUID().uuidString
        let betaDomain = "test.skerry.beta.\(suffix)"
        let currentDomain = "test.skerry.current.\(suffix)"
        defer {
            defaults.removePersistentDomain(forName: betaDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }

        let beta = home.appendingPathComponent(".atoll", isDirectory: true)
        let current = home.appendingPathComponent(".skerry", isDirectory: true)
        try FileManager.default.createDirectory(
            at: beta.appendingPathComponent("lifecycle-events"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: beta.appendingPathComponent("backups/live-status"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: beta.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: current.appendingPathComponent("lifecycle-events"),
            withIntermediateDirectories: true
        )

        try Data("beta-config".utf8).write(to: beta.appendingPathComponent("config.json"))
        try Data("current-config".utf8).write(to: current.appendingPathComponent("config.json"))
        try Data("sessions".utf8).write(to: beta.appendingPathComponent("lifecycle-sessions.json"))
        try Data("event".utf8).write(
            to: beta.appendingPathComponent("lifecycle-events/event.json")
        )
        try Data("current-event".utf8).write(
            to: current.appendingPathComponent("lifecycle-events/current.json")
        )
        try Data("backup".utf8).write(
            to: beta.appendingPathComponent("backups/live-status/codex.json")
        )
        try Data("bridge".utf8).write(to: beta.appendingPathComponent("bin/atoll-hook"))
        try Data("socket".utf8).write(to: beta.appendingPathComponent("lifecycle.sock"))
        defaults.setPersistentDomain(
            ["hasSeenLifecycleOnboardingV2": true, "shared": "beta"],
            forName: betaDomain
        )
        defaults.setPersistentDomain(["shared": "current"], forName: currentDomain)

        try SkerryBetaMigration.migrateIfNeeded(
            homeDirectory: home,
            from: betaDomain,
            to: currentDomain,
            using: defaults
        )

        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("config.json"), encoding: .utf8),
            "current-config"
        )
        XCTAssertEqual(
            try String(
                contentsOf: current.appendingPathComponent("lifecycle-sessions.json"),
                encoding: .utf8
            ),
            "sessions"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("lifecycle-events/event.json").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: current.appendingPathComponent("lifecycle-events/current.json"),
                encoding: .utf8
            ),
            "current-event"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("backups/live-status/codex.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("bin/atoll-hook").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("lifecycle.sock").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent(
                    SkerryBetaMigration.completionMarkerName
                ).path
            )
        )

        let migrated = defaults.persistentDomain(forName: currentDomain)
        XCTAssertEqual(migrated?["hasSeenLifecycleOnboardingV2"] as? Bool, true)
        XCTAssertEqual(migrated?["shared"] as? String, "current")

        try FileManager.default.removeItem(
            at: current.appendingPathComponent("lifecycle-events/event.json")
        )
        var currentDefaults = try XCTUnwrap(defaults.persistentDomain(forName: currentDomain))
        currentDefaults.removeValue(forKey: "hasSeenLifecycleOnboardingV2")
        defaults.setPersistentDomain(currentDefaults, forName: currentDomain)

        try SkerryBetaMigration.migrateIfNeeded(
            homeDirectory: home,
            from: betaDomain,
            to: currentDomain,
            using: defaults
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent("lifecycle-events/event.json").path
            )
        )
        XCTAssertNil(
            defaults.persistentDomain(forName: currentDomain)?["hasSeenLifecycleOnboardingV2"]
        )
    }

    func testFailedMigrationDoesNotWriteMarkerOrDefaultsAndCanRetry() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkerryBetaMigrationFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = UserDefaults.standard
        let suffix = UUID().uuidString
        let betaDomain = "test.skerry.failure.beta.\(suffix)"
        let currentDomain = "test.skerry.failure.current.\(suffix)"
        defer {
            defaults.removePersistentDomain(forName: betaDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }

        let betaEvents = home.appendingPathComponent(".atoll/lifecycle-events", isDirectory: true)
        let currentEvents = home.appendingPathComponent(".skerry/lifecycle-events")
        try FileManager.default.createDirectory(at: betaEvents, withIntermediateDirectories: true)
        try Data("event".utf8).write(to: betaEvents.appendingPathComponent("event.json"))
        try FileManager.default.createDirectory(
            at: currentEvents.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("conflict".utf8).write(to: currentEvents)
        defaults.setPersistentDomain(["migrated": true], forName: betaDomain)

        XCTAssertThrowsError(
            try SkerryBetaMigration.migrateIfNeeded(
                homeDirectory: home,
                from: betaDomain,
                to: currentDomain,
                using: defaults
            )
        )
        let marker = home.appendingPathComponent(
            ".skerry/\(SkerryBetaMigration.completionMarkerName)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(defaults.persistentDomain(forName: currentDomain)?["migrated"])

        try FileManager.default.removeItem(at: currentEvents)
        try SkerryBetaMigration.migrateIfNeeded(
            homeDirectory: home,
            from: betaDomain,
            to: currentDomain,
            using: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try String(
                contentsOf: currentEvents.appendingPathComponent("event.json"),
                encoding: .utf8
            ),
            "event"
        )
        XCTAssertEqual(
            defaults.persistentDomain(forName: currentDomain)?["migrated"] as? Bool,
            true
        )
    }
}
