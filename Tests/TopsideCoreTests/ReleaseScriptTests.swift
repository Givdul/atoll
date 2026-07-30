import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testTopsideArtifactAndLegacyInstallIdentityContract() throws {
        let script = try String(contentsOf: Self.releaseScriptURL, encoding: .utf8)

        for expected in [
            "APP_NAME=\"Topside\"",
            "BUNDLE_IDENTIFIER=\"com.givdul.topside\"",
            "SKERRY_BUNDLE_IDENTIFIER=\"com.givdul.skerry\"",
            "ATOLL_BUNDLE_IDENTIFIER=\"dev.atoll.Atoll\"",
            "Bundle/Topside.icns",
            "TopsideEntitlementStorage",
            "TOPSIDE_PURCHASE_URL"
        ] {
            XCTAssertTrue(script.contains(expected), expected)
        }
        XCTAssertFalse(script.contains("Bundle/Skerry.icns\" \"$APP_BUNDLE"))
    }

    func testInstallChecksIdentityBeforeMovingEveryApplication() throws {
        let script = try String(contentsOf: Self.releaseScriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("verify_app_identity \"$INSTALLED_APP\" \"$APP_NAME\" \"$BUNDLE_IDENTIFIER\""))
        XCTAssertTrue(script.contains("verify_app_identity \"$SKERRY_INSTALLED_APP\" \"$SKERRY_APP_NAME\" \"$SKERRY_BUNDLE_IDENTIFIER\""))
        XCTAssertTrue(script.contains("verify_app_identity \"$ATOLL_INSTALLED_APP\" \"$ATOLL_APP_NAME\" \"$ATOLL_BUNDLE_IDENTIFIER\""))
        XCTAssertTrue(script.contains("restore_installed_backup \"$INSTALL_HAD_SKERRY_APP\""))
        XCTAssertTrue(script.contains("restore_installed_backup \"$INSTALL_HAD_ATOLL_APP\""))
    }
    func testDistributionRequiresEveryInputBeforeNetworkOrCompilation() throws {
        for name in Self.releaseEnvironment.keys {
            var environment = Self.releaseEnvironment
            environment.removeValue(forKey: name)
            let result = try runReleaseScript(
                arguments: ["--distribution"],
                environment: environment
            )

            XCTAssertNotEqual(result.status, 0, name)
            XCTAssertTrue(
                result.output.contains("\(name) is required for --distribution"),
                "\(name): \(result.output)"
            )
            XCTAssertEqual(result.sideEffects, [], name)
            XCTAssertFalse(result.output.contains("Building for production"), name)
        }
    }

    func testDistributionRejectsInvalidLocalInputBeforeNetworkOrCredentials() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "01"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("BUILD_NUMBER must be a positive integer"))
        XCTAssertEqual(result.sideEffects, [])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRequiresExactProductionFeedBeforeNetwork() throws {
        var environment = Self.releaseEnvironment
        environment["SPARKLE_FEED_URL"] = "https://example.com/appcast.xml"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SPARKLE_FEED_URL must be \(Self.productionFeedURL)"))
        XCTAssertEqual(result.sideEffects, [])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testBootstrapFeedAndZeroLedgerAcceptFirstBuild() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "1"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: []),
            ledger: "0"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SIGN_IDENTITY is not available"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger", "credential"])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testPublishedBuild100RejectsBuild2() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "2"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [100]),
            ledger: "100"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("BUILD_NUMBER must be greater than production build ledger 100"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testRolledBackAppcastUsesLedgerAsMonotonicAuthority() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "101"
        let accepted = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [7]),
            ledger: "100"
        )

        XCTAssertTrue(accepted.output.contains("SIGN_IDENTITY is not available"))
        XCTAssertEqual(accepted.sideEffects, ["network appcast", "network ledger", "credential"])

        environment["BUILD_NUMBER"] = "100"
        let rejected = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [7]),
            ledger: "100"
        )

        XCTAssertTrue(rejected.output.contains("BUILD_NUMBER must be greater than production build ledger 100"))
        XCTAssertEqual(rejected.sideEffects, ["network appcast", "network ledger"])
    }

    func testDescendingAppcastItemsUseGreatestBuild() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "101"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [100, 7]),
            ledger: "100"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SIGN_IDENTITY is not available"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger", "credential"])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsConflictingAppcastBuildVersions() throws {
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: Self.releaseEnvironment,
            appcast: """
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:version>100</sparkle:version>
                  <enclosure sparkle:version="101" />
                </item>
              </channel>
            </rss>
            """,
            ledger: "101"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("appcast item has conflicting build versions"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsMalformedBuildLedger() throws {
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: Self.releaseEnvironment,
            appcast: Self.appcast(builds: [100]),
            ledger: "100\n101"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("build ledger must contain one non-negative integer"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
    }

    func testDistributionRejectsMalformedAppcast() throws {
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: Self.releaseEnvironment,
            appcast: "<rss>",
            ledger: "100"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SPARKLE_FEED_URL did not return valid XML"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
    }

    func testDistributionRejectsAppcastAheadOfLedger() throws {
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: Self.releaseEnvironment,
            appcast: Self.appcast(builds: [101]),
            ledger: "100"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("appcast build 101 exceeds production build ledger 100"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
    }

    func testDistributionRejectsEmptyFeedAfterBootstrap() throws {
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: Self.releaseEnvironment,
            appcast: Self.appcast(builds: []),
            ledger: "100"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("empty Sparkle feed requires a zero production build ledger"))
        XCTAssertEqual(result.sideEffects, ["network appcast", "network ledger"])
    }

    func testDistributionRejectsPolarSandboxBeforeNetwork() throws {
        var environment = Self.releaseEnvironment
        environment["TOPSIDE_PURCHASE_URL"] =
            "https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_test/redirect"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must use the production Polar checkout"))
        XCTAssertEqual(result.sideEffects, [])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsMalformedPolarUUIDBeforeNetwork() throws {
        var environment = Self.releaseEnvironment
        environment["POLAR_BENEFIT_ID"] = "not-a-uuid"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Polar organization and benefit IDs must be UUIDs"))
        XCTAssertEqual(result.sideEffects, [])
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    private static let releaseScriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts/build-release.sh")

    private static let productionFeedURL =
        "https://raw.githubusercontent.com/Givdul/atoll/main/appcast.xml"

    private static let releaseEnvironment = [
        "SIGN_IDENTITY": "Developer ID Application: Test (ABCDEFGHIJ)",
        "DEVELOPER_TEAM_ID": "ABCDEFGHIJ",
        "NOTARY_KEYCHAIN_PROFILE": "test",
        "SPARKLE_FEED_URL": productionFeedURL,
        "SPARKLE_PUBLIC_ED_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "TOPSIDE_PURCHASE_URL": "https://buy.polar.sh/polar_cl_test",
        "POLAR_ORGANIZATION_ID": "11111111-1111-4111-8111-111111111111",
        "POLAR_BENEFIT_ID": "22222222-2222-4222-8222-222222222222",
        "MARKETING_VERSION": "1.0.0",
        "BUILD_NUMBER": "101"
    ]

    private static func appcast(builds: [Int]) -> String {
        let items = builds.enumerated().map { index, build in
            if index.isMultiple(of: 2) {
                return "<item><sparkle:version>\(build)</sparkle:version></item>"
            }
            return "<item><enclosure sparkle:version=\"\(build)\" /></item>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>\(items)</channel>
        </rss>
        """
    }

    private func runReleaseScript(
        arguments: [String],
        environment additions: [String: String] = [:],
        appcast: String? = nil,
        ledger: String = "0"
    ) throws -> (status: Int32, output: String, sideEffects: [String]) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        [
            "SIGN_IDENTITY",
            "DEVELOPER_TEAM_ID",
            "NOTARY_KEYCHAIN_PROFILE",
            "SPARKLE_FEED_URL",
            "SPARKLE_PUBLIC_ED_KEY",
            "TOPSIDE_PURCHASE_URL",
            "POLAR_ORGANIZATION_ID",
            "POLAR_BENEFIT_ID",
            "MARKETING_VERSION",
            "BUILD_NUMBER"
        ].forEach { environment.removeValue(forKey: $0) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("topside-release-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sideEffects = directory.appendingPathComponent("side-effects")
        try writeExecutable(
            named: "curl",
            in: directory,
            contents: """
            #!/bin/sh
            case "$*" in
              *appcast.xml*)
                printf 'network appcast\\n' >> "$TOPSIDE_TEST_SIDE_EFFECTS"
                printf '%s' "$TOPSIDE_TEST_APPCAST"
                ;;
              *latest-build.txt*)
                printf 'network ledger\\n' >> "$TOPSIDE_TEST_SIDE_EFFECTS"
                printf '%s' "$TOPSIDE_TEST_LEDGER"
                ;;
              *)
                exit 1
                ;;
            esac
            """
        )
        try writeExecutable(
            named: "security",
            in: directory,
            contents: """
            #!/bin/sh
            printf 'credential\\n' >> "$TOPSIDE_TEST_SIDE_EFFECTS"
            exit 1
            """
        )
        for command in ["xcrun", "swift"] {
            try writeExecutable(
                named: command,
                in: directory,
                contents: """
                #!/bin/sh
                printf '\(command)\\n' >> "$TOPSIDE_TEST_SIDE_EFFECTS"
                exit 1
                """
            )
        }

        environment["PATH"] = "\(directory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["TOPSIDE_TEST_APPCAST"] = appcast ?? Self.appcast(builds: [])
        environment["TOPSIDE_TEST_LEDGER"] = ledger
        environment["TOPSIDE_TEST_SIDE_EFFECTS"] = sideEffects.path
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("Scripts/build-release.sh").path] + arguments
        process.environment = environment.merging(additions) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let events = (try? String(contentsOf: sideEffects, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            events
        )
    }

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
