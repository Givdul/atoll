import XCTest
@testable import TopsideCore

final class TopsideMigrationTests: XCTestCase {
    func testMigrationUsesTopsideThenSkerryThenAtollPrecedence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("topside-config", to: ".topside/config.json")
        try fixture.write("skerry-config", to: ".skerry/config.json")
        try fixture.write("atoll-config", to: ".atoll/config.json")
        try fixture.write("skerry-session", to: ".skerry/lifecycle-sessions.json")
        try fixture.write("atoll-session", to: ".atoll/lifecycle-sessions.json")
        try fixture.write("skerry-event", to: ".skerry/lifecycle-events/shared.json")
        try fixture.write("atoll-event", to: ".atoll/lifecycle-events/shared.json")
        try fixture.write("atoll-only", to: ".atoll/lifecycle-events/atoll.json")
        try fixture.write("trial", to: ".skerry/trial-entitlement-v1.json")
        try fixture.write("bridge", to: ".skerry/bin/skerry-hook")
        try fixture.write("socket", to: ".skerry/lifecycle.sock")
        try fixture.write("lock", to: ".skerry/.lifecycle-events.writer.lock")

        fixture.defaults.setPersistentDomain(
            ["topside": true, "shared": "topside"],
            forName: fixture.topsideDomain
        )
        fixture.defaults.setPersistentDomain(
            ["skerry": true, "shared": "skerry"],
            forName: fixture.skerryDomain
        )
        fixture.defaults.setPersistentDomain(
            ["atoll": true, "shared": "atoll"],
            forName: fixture.atollDomain
        )

        try fixture.migrate()

        XCTAssertEqual(try fixture.read(".topside/config.json"), "topside-config")
        XCTAssertEqual(try fixture.read(".topside/lifecycle-sessions.json"), "skerry-session")
        XCTAssertEqual(try fixture.read(".topside/lifecycle-events/shared.json"), "skerry-event")
        XCTAssertEqual(try fixture.read(".topside/lifecycle-events/atoll.json"), "atoll-only")
        XCTAssertEqual(try fixture.read(".topside/trial-entitlement-v1.json"), "trial")
        XCTAssertFalse(fixture.exists(".topside/bin/skerry-hook"))
        XCTAssertFalse(fixture.exists(".topside/lifecycle.sock"))
        XCTAssertFalse(fixture.exists(".topside/.lifecycle-events.writer.lock"))
        XCTAssertTrue(fixture.exists(".skerry/lifecycle-events/shared.json"))
        XCTAssertTrue(fixture.exists(".atoll/lifecycle-events/shared.json"))

        let migrated = fixture.defaults.persistentDomain(forName: fixture.topsideDomain)
        XCTAssertEqual(migrated?["topside"] as? Bool, true)
        XCTAssertEqual(migrated?["skerry"] as? Bool, true)
        XCTAssertEqual(migrated?["atoll"] as? Bool, true)
        XCTAssertEqual(migrated?["shared"] as? String, "topside")
        XCTAssertTrue(fixture.exists(".topside/\(TopsideMigration.completionMarkerName)"))
    }

    func testCompletionPreventsReseedingConsumedEvents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("event", to: ".skerry/lifecycle-events/event.json")

        try fixture.migrate()
        try FileManager.default.removeItem(at: fixture.url(".topside/lifecycle-events/event.json"))
        try fixture.migrate()

        XCTAssertFalse(fixture.exists(".topside/lifecycle-events/event.json"))
        XCTAssertTrue(fixture.exists(".skerry/lifecycle-events/event.json"))
    }

    func testFailureDoesNotWriteMarkerOrDefaultsAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("event", to: ".skerry/lifecycle-events/event.json")
        try fixture.write("conflict", to: ".topside/lifecycle-events")
        fixture.defaults.setPersistentDomain(["migrated": true], forName: fixture.skerryDomain)

        XCTAssertThrowsError(try fixture.migrate())
        XCTAssertFalse(fixture.exists(".topside/\(TopsideMigration.completionMarkerName)"))
        XCTAssertNil(fixture.defaults.persistentDomain(forName: fixture.topsideDomain)?["migrated"])

        try FileManager.default.removeItem(at: fixture.url(".topside/lifecycle-events"))
        try fixture.migrate()

        XCTAssertEqual(try fixture.read(".topside/lifecycle-events/event.json"), "event")
        XCTAssertEqual(
            fixture.defaults.persistentDomain(forName: fixture.topsideDomain)?["migrated"] as? Bool,
            true
        )
    }

    func testSymlinkSourcesAreNotFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.write("outside", to: "outside.json")
        try FileManager.default.createDirectory(
            at: fixture.url(".skerry"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.url(".skerry/config.json"),
            withDestinationURL: fixture.url("outside.json")
        )

        try fixture.migrate()

        XCTAssertFalse(fixture.exists(".topside/config.json"))
    }
}

private final class Fixture {
    let home: URL
    let defaults = UserDefaults.standard
    let skerryDomain: String
    let atollDomain: String
    let topsideDomain: String

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TopsideMigration-\(UUID().uuidString)", isDirectory: true)
        let suffix = UUID().uuidString
        skerryDomain = "test.topside.skerry.\(suffix)"
        atollDomain = "test.topside.atoll.\(suffix)"
        topsideDomain = "test.topside.current.\(suffix)"
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func migrate() throws {
        try TopsideMigration.migrateIfNeeded(
            homeDirectory: home,
            skerryDomain: skerryDomain,
            atollDomain: atollDomain,
            topsideDomain: topsideDomain,
            using: defaults
        )
    }

    func url(_ path: String) -> URL {
        home.appendingPathComponent(path)
    }

    func write(_ value: String, to path: String) throws {
        let destination = url(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: destination)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: skerryDomain)
        defaults.removePersistentDomain(forName: atollDomain)
        defaults.removePersistentDomain(forName: topsideDomain)
        try? FileManager.default.removeItem(at: home)
    }
}
