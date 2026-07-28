import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testDistributionRequiresEveryInputBeforeCompilation() throws {
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
            XCTAssertFalse(result.output.contains("Building for production"), name)
        }
    }

    func testDistributionRejectsARepeatedBuildBeforeCompilation() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "7"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [7])
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("BUILD_NUMBER must be greater than latest published build 7"))
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsBuildBelowAuthoritativePublishedFeed() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "2"
        environment["PREVIOUS_BUILD_NUMBER"] = "1"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [7, 100])
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must match latest published build 100"))
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsInvalidHTTPSFeedURLBeforeCompilation() throws {
        var environment = Self.releaseEnvironment
        environment["SPARKLE_FEED_URL"] = "https:///appcast.xml"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must be a valid HTTPS URL with a host"))
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionAcceptsValidHTTPSFeedURL() throws {
        var environment = Self.releaseEnvironment
        environment["BUILD_NUMBER"] = "101"
        environment["PREVIOUS_BUILD_NUMBER"] = "100"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment,
            appcast: Self.appcast(builds: [100, 7])
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.contains("must be a valid HTTPS URL with a host"))
        XCTAssertTrue(result.output.contains("SIGN_IDENTITY is not available"))
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    func testDistributionRejectsPolarSandboxBeforeCompilation() throws {
        var environment = Self.releaseEnvironment
        environment["SKERRY_PURCHASE_URL"] =
            "https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_test/redirect"
        let result = try runReleaseScript(
            arguments: ["--distribution"],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("must use the production Polar checkout"))
        XCTAssertFalse(result.output.contains("Building for production"))
    }

    private static let releaseEnvironment = [
        "SIGN_IDENTITY": "Developer ID Application: Test (ABCDEFGHIJ)",
        "DEVELOPER_TEAM_ID": "ABCDEFGHIJ",
        "NOTARY_KEYCHAIN_PROFILE": "test",
        "SPARKLE_FEED_URL": "https://example.com/appcast.xml",
        "SPARKLE_PUBLIC_ED_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "SKERRY_PURCHASE_URL": "https://buy.polar.sh/polar_cl_test",
        "POLAR_ORGANIZATION_ID": "11111111-1111-4111-8111-111111111111",
        "POLAR_BENEFIT_ID": "22222222-2222-4222-8222-222222222222",
        "MARKETING_VERSION": "1.0.0",
        "BUILD_NUMBER": "8",
        "PREVIOUS_BUILD_NUMBER": "7"
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
        appcast: String? = nil
    ) throws -> (status: Int32, output: String) {
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
            "SKERRY_PURCHASE_URL",
            "POLAR_ORGANIZATION_ID",
            "POLAR_BENEFIT_ID",
            "MARKETING_VERSION",
            "BUILD_NUMBER",
            "PREVIOUS_BUILD_NUMBER"
        ].forEach { environment.removeValue(forKey: $0) }
        var mockDirectory: URL?
        if let appcast {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("skerry-release-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let curl = directory.appendingPathComponent("curl")
            try Data("#!/bin/sh\n/usr/bin/printf '%s' \"$SKERRY_TEST_APPCAST\"\n".utf8).write(to: curl)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
            environment["PATH"] = "\(directory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["SKERRY_TEST_APPCAST"] = appcast
            mockDirectory = directory
        }
        defer {
            if let mockDirectory {
                try? FileManager.default.removeItem(at: mockDirectory)
            }
        }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("Scripts/build-release.sh").path] + arguments
        process.environment = environment.merging(additions) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
