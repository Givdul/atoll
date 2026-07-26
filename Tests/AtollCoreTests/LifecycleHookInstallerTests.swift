import XCTest
@testable import AtollCore

final class LifecycleHookInstallerTests: XCTestCase {
    private var home: URL!
    private let executable = "/Applications/Atoll.app/Contents/MacOS/Atoll"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AtollHookInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testInstallsEverySupportedIntegrationIdempotently() throws {
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try write([
            "theme": "dark",
            "hooks": ["Stop": [["matcher": "existing", "hooks": [["type": "command", "command": "keep-me"]]]]]
        ], to: claudeURL)
        let legacyOpenCodePlugin = home.appendingPathComponent(".config/opencode/plugin/atoll.js")
        try FileManager.default.createDirectory(at: legacyOpenCodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Atoll Live Status managed integration\n// stale".write(to: legacyOpenCodePlugin, atomically: true, encoding: .utf8)

        let installer = makeInstaller()
        try installer.install()
        let firstClaudeConfiguration = try Data(contentsOf: claudeURL)
        try installer.install()
        XCTAssertEqual(firstClaudeConfiguration, try Data(contentsOf: claudeURL))

        let bridgeURL = home.appendingPathComponent(".atoll/bin/atoll-hook")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
        XCTAssertTrue(bridge.contains("'\(executable)' --lifecycle-event \"$1\" \"$2\""))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: bridgeURL.path)[.posixPermissions] as? NSNumber,
            0o700
        )

        let codex = try read(home.appendingPathComponent(".codex/hooks.json"))
        XCTAssertEqual(commands(in: codex, event: "UserPromptSubmit"), [hook("codex", "started")])
        XCTAssertEqual(commands(in: codex, event: "Stop"), [hook("codex", "finished")])

        let claude = try read(claudeURL)
        XCTAssertEqual(claude["theme"] as? String, "dark")
        XCTAssertEqual(commands(in: claude, event: "UserPromptSubmit"), [hook("claude", "started")])
        XCTAssertTrue(commands(in: claude, event: "Stop").contains("keep-me"))
        XCTAssertTrue(commands(in: claude, event: "Stop").contains(hook("claude", "finished")))
        XCTAssertEqual(commands(in: claude, event: "StopFailure"), [hook("claude", "failed")])
        XCTAssertEqual(
            commands(in: claude, event: "Notification", matcher: "permission_prompt"),
            [hook("claude", "needsPermission")]
        )
        XCTAssertEqual(
            commands(in: claude, event: "Notification", matcher: "elicitation_dialog"),
            [hook("claude", "needsInput")]
        )
        XCTAssertTrue(commands(in: claude, event: "SessionEnd").isEmpty)

        let cursor = try read(home.appendingPathComponent(".cursor/hooks.json"))
        XCTAssertEqual(commands(in: cursor, event: "beforeSubmitPrompt"), [hook("cursor", "started")])
        XCTAssertEqual(commands(in: cursor, event: "stop"), [hook("cursor", "finished")])
        XCTAssertTrue(commands(in: cursor, event: "sessionStart").isEmpty)
        XCTAssertTrue(commands(in: cursor, event: "sessionEnd").isEmpty)

        let pi = try String(contentsOf: home.appendingPathComponent(".pi/agent/extensions/atoll.ts"), encoding: .utf8)
        XCTAssertTrue(pi.contains("agent_start"))
        XCTAssertTrue(pi.contains("agent_end"))
        XCTAssertTrue(pi.contains("agent_settled"))
        XCTAssertTrue(pi.contains("stopReason === \"error\" || stopReason === \"length\""))
        XCTAssertTrue(pi.contains("stopReason === \"aborted\""))
        XCTAssertTrue(pi.contains("emit(outcome, ctx)"))
        XCTAssertTrue(pi.contains("cwd: ctx.cwd"))
        XCTAssertFalse(pi.contains("getCwd()"))
        XCTAssertFalse(pi.contains("cwd: process.cwd()"))

        let openCode = try String(
            contentsOf: home.appendingPathComponent(".config/opencode/plugins/atoll.js"),
            encoding: .utf8
        )
        XCTAssertTrue(openCode.contains("status.type === \"busy\" || status.type === \"retry\""))
        XCTAssertTrue(openCode.contains("event.type === \"session.error\""))
        XCTAssertTrue(openCode.contains("MessageAbortedError"))
        XCTAssertTrue(openCode.contains("event.type === \"permission.asked\" || event.type === \"permission.updated\""))
        XCTAssertTrue(openCode.contains("event.type === \"question.asked\""))
        XCTAssertTrue(openCode.contains("stdin: \"pipe\""))
        XCTAssertTrue(openCode.contains("child.stdin.write(JSON.stringify"))
        XCTAssertTrue(openCode.contains("child.stdin.end()"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyOpenCodePlugin.path))

        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .configured, "\(agent.rawValue) should be configured")
        }
    }

    func testSupportedHarnessesAreExactlyTheFiveShippedAgentsInDisplayOrder() {
        let expected: [AgentHarness] = [.codex, .claude, .cursor, .opencode, .pi]
        XCTAssertEqual(LifecycleHookInstaller.supportedAgents, expected)
        XCTAssertEqual(Set(AgentHarness.allCases), Set(expected).union([.atoll]))
        for removed in ["gemini", "copilot", "droid", "qoder", "qwen", "hermes", "amp", "kimi", "kiro", "codebuddy"] {
            XCTAssertNil(AgentHarness.parse(removed))
        }
    }

    func testManagedPluginCollisionIsNotOverwritten() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugins/atoll.js")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)

        let installer = makeInstaller()
        XCTAssertTrue(installer.canUninstall(for: .opencode))
        XCTAssertThrowsError(try installer.install(agents: [.opencode]))
        XCTAssertEqual(try String(contentsOf: plugin, encoding: .utf8), "// another plugin")
    }

    func testLegacyManagedPluginCollisionIsNotOverwritten() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugin/atoll.js")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try makeInstaller().install(agents: [.opencode]))
        XCTAssertEqual(try String(contentsOf: plugin, encoding: .utf8), "// another plugin")
    }

    func testInvalidConfigurationIsReportedWithoutBeingOverwritten() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: settings, atomically: true, encoding: .utf8)
        let installer = makeInstaller()

        guard case .invalidConfiguration = installer.readiness(for: .claude) else {
            return XCTFail("Expected invalid Claude configuration")
        }
        XCTAssertThrowsError(try installer.install(agents: [.claude]))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "not json")
    }

    func testCursorRejectsUnknownSchemaWithoutOverwritingIt() throws {
        let hooks = home.appendingPathComponent(".cursor/hooks.json")
        try write(["version": 2, "hooks": [:]], to: hooks)
        let installer = makeInstaller()

        guard case .invalidConfiguration = installer.readiness(for: .cursor) else {
            return XCTFail("Expected unknown Cursor schema to require user action")
        }
        XCTAssertThrowsError(try installer.install(agents: [.cursor]))
        XCTAssertEqual(try read(hooks)["version"] as? Int, 2)
    }

    func testDetectionAndCustomUserHomesCoverAllDocumentedOverrides() throws {
        let codex = home.appendingPathComponent("custom-codex")
        let claude = home.appendingPathComponent("custom-claude")
        let pi = home.appendingPathComponent("custom-pi-agent")
        let openCode = home.appendingPathComponent("custom-opencode")
        try FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCode, withIntermediateDirectories: true)

        let installer = makeInstaller(environment: [
            "CODEX_HOME": codex.path,
            "CLAUDE_CONFIG_DIR": claude.path,
            "PI_CODING_AGENT_DIR": pi.path,
            "OPENCODE_CONFIG_DIR": openCode.path
        ])
        XCTAssertTrue(Set([AgentHarness.pi, .opencode]).isSubset(of: Set(installer.detectedAgents())))

        try installer.install(agents: [.codex, .claude, .pi, .opencode])

        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("hooks.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pi.appendingPathComponent("extensions/atoll.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: openCode.appendingPathComponent("plugins/atoll.js").path))
    }

    func testDetectedAgentsAreInstalledOnlyInDisplayOrderAndScopedInstallPreservesOthers() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write(["theme": "dark"], to: claude)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/opencode"),
            withIntermediateDirectories: true
        )
        let pi = home.appendingPathComponent(".local/bin/pi")
        try FileManager.default.createDirectory(at: pi.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pi.path)

        let installer = makeInstaller(
            environment: ["PATH": home.appendingPathComponent("bin").path],
            fileManager: HomeScopedFileManager(home: home)
        )
        XCTAssertEqual(installer.detectedAgents(), [.claude, .cursor, .opencode, .pi])

        let originalClaude = try Data(contentsOf: claude)
        try installer.install(agents: [.codex])
        XCTAssertEqual(try Data(contentsOf: claude), originalClaude)
    }

    func testCodexDisabledHooksArePreserved() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = "[features]\nhooks = false # explicitly disabled\n"
        try source.write(to: config, atomically: true, encoding: .utf8)
        let installer = makeInstaller()

        guard case .invalidConfiguration(let detail) = installer.readiness(for: .codex) else {
            return XCTFail("Expected disabled Codex hooks to require user action")
        }
        XCTAssertTrue(detail.contains("hooks are disabled"), detail)
        XCTAssertThrowsError(try installer.install(agents: [.codex]))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), source)
    }

    func testInstallRemovesOnlyLegacyClaudeAndCursorHooks() throws {
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try write([
            "hooks": [
                "SessionEnd": [[
                    "hooks": [
                        ["type": "command", "command": hook("claude", "finished")],
                        ["type": "command", "command": "keep-claude"]
                    ]
                ]]
            ]
        ], to: claudeURL)

        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        try write([
            "hooks": [
                "sessionStart": [
                    ["command": hook("cursor", "started")],
                    ["command": "keep-start"]
                ],
                "sessionEnd": [
                    ["command": hook("cursor", "finished")],
                    ["command": "keep-end"]
                ]
            ]
        ], to: cursorURL)

        let installer = makeInstaller()
        try installer.install(agents: [.claude, .cursor])

        XCTAssertEqual(commands(in: try read(claudeURL), event: "SessionEnd"), ["keep-claude"])
        XCTAssertEqual(commands(in: try read(cursorURL), event: "sessionStart"), ["keep-start"])
        XCTAssertEqual(commands(in: try read(cursorURL), event: "sessionEnd"), ["keep-end"])
        XCTAssertEqual(installer.readiness(for: .claude), .configured)
        XCTAssertEqual(installer.readiness(for: .cursor), .configured)
    }

    func testPiVersionGateAndManagedFileRepair() throws {
        let supported = makeInstaller(piVersionOutput: "pi-coding-agent 0.80.4")
        try supported.install(agents: [.pi, .opencode])

        let managedFiles: [(AgentHarness, String)] = [
            (.pi, ".pi/agent/extensions/atoll.ts"),
            (.opencode, ".config/opencode/plugins/atoll.js")
        ]
        for (agent, path) in managedFiles {
            let url = home.appendingPathComponent(path)
            try "// Atoll Live Status managed integration\n// stale".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(supported.readiness(for: agent), .notConfigured)
            try supported.install(agents: [agent])
            XCTAssertEqual(supported.readiness(for: agent), .configured)
        }

        let old = makeInstaller(piVersionOutput: "pi-coding-agent 0.80.3")
        XCTAssertEqual(
            old.readiness(for: .pi),
            .invalidConfiguration("Pi 0.80.4 or newer is required for Live Status; found 0.80.3.")
        )
        XCTAssertThrowsError(try old.install(agents: [.pi]))
    }

    func testEveryIntegrationRequiresTheCurrentExecutableBridge() throws {
        let installer = makeInstaller()
        let bridge = home.appendingPathComponent(".atoll/bin/atoll-hook")
        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)

        try installer.install(agents: [.pi])
        try "#!/bin/sh\nexit 0\n".write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)
    }

    func testFirstSharedConfigurationBackupIsExactPrivateAndNeverOverwritten() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"theme":"dark","hooks":{"Stop":[]}}"#.utf8)
        try original.write(to: claude)
        let installer = makeInstaller()

        try installer.install(agents: [.claude, .codex])
        let backupDirectory = home.appendingPathComponent(".atoll/backups/live-status")
        let backupURLs = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        let claudeBackupURL = try XCTUnwrap(backupURLs.first { $0.lastPathComponent.hasPrefix("claude-") })
        let codexMarkerURL = try XCTUnwrap(backupURLs.first { $0.lastPathComponent.hasPrefix("codex-") })
        XCTAssertEqual(claudeBackupURL.pathExtension, "json")
        XCTAssertEqual(codexMarkerURL.pathExtension, "absent")

        let backupData = try Data(contentsOf: claudeBackupURL)
        let backup = try JSONDecoder().decode(SharedConfigurationBackupFixture.self, from: backupData)
        XCTAssertEqual(backup.provider, "claude")
        XCTAssertEqual(backup.originalPath, claude.path)
        XCTAssertEqual(backup.contents, original)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backupDirectory.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: claudeBackupURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        try installer.install(agents: [.claude, .codex])
        XCTAssertEqual(try Data(contentsOf: claudeBackupURL), backupData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("codex-") }
                .map(\.pathExtension),
            ["absent"]
        )
    }

    func testSharedConfigurationMutationKeepsTheOriginalSnapshotAndDoesNotOverwriteConcurrentChanges() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write(["theme": "before"], to: claude)
        let original = try Data(contentsOf: claude)
        let replacement = try JSONSerialization.data(withJSONObject: ["theme": "concurrent"])
        let fileManager = BackupMutationFileManager(
            configurationURL: claude,
            replacement: replacement
        )
        let installer = makeInstaller(fileManager: fileManager)

        XCTAssertThrowsError(try installer.install(agents: [.claude])) { error in
            guard case LifecycleHookInstaller.Error.configurationChanged(let url) = error else {
                return XCTFail("Expected concurrent configuration change, got \(error)")
            }
            XCTAssertEqual(url, claude)
        }
        XCTAssertEqual(try Data(contentsOf: claude), replacement)

        let backupDirectory = home.appendingPathComponent(".atoll/backups/live-status")
        let backupURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let backup = try JSONDecoder().decode(
            SharedConfigurationBackupFixture.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(backup.contents, original)
    }

    func testInstallAndUninstallPreserveSharedConfigurationSymlink() throws {
        let target = home.appendingPathComponent("shared/claude-settings.json")
        try write(["theme": "dark"], to: target)
        let original = try Data(contentsOf: target)
        let link = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let installer = makeInstaller()

        try installer.install(agents: [.claude])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(installer.hasIntegration(for: .claude))
        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.removed])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try read(target)["theme"] as? String, "dark")

        let backupDirectory = home.appendingPathComponent(".atoll/backups/live-status")
        let backupURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let backup = try JSONDecoder().decode(
            SharedConfigurationBackupFixture.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(backup.originalPath, link.path)
        XCTAssertEqual(backup.contents, original)
    }

    func testTargetedUninstallSubtractsEveryOwnedCommandAndPreservesUserChanges() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write([
            "theme": "dark",
            "hooks": [
                "Stop": [[
                    "matcher": "existing",
                    "hooks": [["type": "command", "command": "keep-before"]]
                ]]
            ]
        ], to: claude)
        let installer = makeInstaller()
        try installer.install(agents: [.claude])

        var updated = try read(claude)
        var hooks = try XCTUnwrap(updated["hooks"] as? [String: Any])
        hooks["CustomEvent"] = [[
            "matcher": "*",
            "note": "keep-group",
            "hooks": [
                ["type": "command", "command": hook("claude", "cancelled")],
                ["type": "command", "command": "keep-after"],
                ["type": "http", "url": "https://example.invalid"]
            ]
        ]]
        updated["hooks"] = hooks
        updated["userChange"] = true
        try write(updated, to: claude)

        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.removed])
        let removed = try read(claude)
        XCTAssertEqual(removed["theme"] as? String, "dark")
        XCTAssertEqual(removed["userChange"] as? Bool, true)
        XCTAssertTrue(commands(in: removed, event: "Stop").contains("keep-before"))
        XCTAssertEqual(commands(in: removed, event: "CustomEvent"), ["keep-after"])
        let customGroup = try XCTUnwrap(
            ((removed["hooks"] as? [String: Any])?["CustomEvent"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(customGroup["note"] as? String, "keep-group")
        XCTAssertEqual((customGroup["hooks"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(installer.hasIntegration(for: .claude))
        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.notInstalled])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path))
    }

    func testUninstallRemovesOwnedHooksEvenWhenClaudeHooksAreDisabled() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        let installer = makeInstaller()
        try installer.install(agents: [.claude])
        var root = try read(claude)
        root["disableAllHooks"] = true
        root["theme"] = "dark"
        try write(root, to: claude)

        guard case .invalidConfiguration = installer.readiness(for: .claude) else {
            return XCTFail("Expected disabled hooks to remain unavailable for setup")
        }
        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.removed])
        let removed = try read(claude)
        XCTAssertEqual(removed["disableAllHooks"] as? Bool, true)
        XCTAssertEqual(removed["theme"] as? String, "dark")
        XCTAssertTrue(commands(in: removed, event: "Stop").isEmpty)
    }

    func testInstallUpdateUninstallAndReinstallAllProviders() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.install()

        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.removed])
        XCTAssertFalse(installer.hasIntegration(for: .claude))
        XCTAssertTrue(installer.hasIntegration(for: .codex))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path))

        let remaining: [AgentHarness] = [.codex, .cursor, .opencode, .pi]
        XCTAssertEqual(installer.uninstall(agents: remaining).map(\.outcome), Array(repeating: .removed, count: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path))
        XCTAssertEqual(installer.uninstall().map(\.outcome), Array(repeating: .notInstalled, count: 5))

        try installer.install()
        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .configured)
        }
    }

    func testBridgeReferenceDetectionReadsEscapedJSONCommands() throws {
        let installer = makeInstaller()
        try installer.install(agents: [.codex, .pi])
        let codex = home.appendingPathComponent(".codex/hooks.json")
        XCTAssertTrue(try String(contentsOf: codex, encoding: .utf8).contains(#"\/"#))
        XCTAssertTrue(installer.hasIntegration(for: .codex))

        XCTAssertEqual(installer.uninstall(agents: [.pi]).map(\.outcome), [.removed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path))
        XCTAssertEqual(installer.uninstall(agents: [.codex]).map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path))
    }

    func testUninstallPreservesAndReportsUnownedOrMalformedFiles() throws {
        let installer = makeInstaller()
        try installer.install()
        let bridge = home.appendingPathComponent(".atoll/bin/atoll-hook")
        let pi = home.appendingPathComponent(".pi/agent/extensions/atoll.ts")
        let openCode = home.appendingPathComponent(".config/opencode/plugins/atoll.js")
        let codex = home.appendingPathComponent(".codex/hooks.json")
        let unownedPi = "// user extension\nconst bridge = \"\(bridge.path)\";\n"
        let unownedOpenCode = "// user plugin\n"
        let malformedCodex = Data([0xFF, 0xFE, 0xFD])
        try unownedPi.write(to: pi, atomically: true, encoding: .utf8)
        try unownedOpenCode.write(to: openCode, atomically: true, encoding: .utf8)
        try malformedCodex.write(to: codex, options: .atomic)

        let results = installer.uninstall()
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.first(where: { $0.agent == .claude })?.outcome, .removed)
        XCTAssertEqual(results.first(where: { $0.agent == .cursor })?.outcome, .removed)
        for agent in [AgentHarness.codex, .opencode, .pi] {
            guard case .failed(let detail) = results.first(where: { $0.agent == agent })?.outcome else {
                return XCTFail("Expected \(agent.rawValue) uninstall failure")
            }
            XCTAssertFalse(detail.isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: pi, encoding: .utf8), unownedPi)
        XCTAssertEqual(try String(contentsOf: openCode, encoding: .utf8), unownedOpenCode)
        XCTAssertEqual(try Data(contentsOf: codex), malformedCodex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.path))
    }

    func testPiVersionCommandTimesOutWithinBound() throws {
        let bin = home.appendingPathComponent("bin")
        let pi = bin.appendingPathComponent("pi")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        trap 'exit 0' TERM
        while :; do :; done
        """.write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pi.path)
        let installer = LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            environment: ["PATH": bin.path],
            commandTimeout: 0.10
        )

        let start = Date()
        XCTAssertThrowsError(try installer.install(agents: [.pi])) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out after 0.10 seconds"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    private func hook(_ harness: String, _ kind: String) -> String {
        "'\(home.path)/.atoll/bin/atoll-hook' \(harness) \(kind)"
    }

    private func makeInstaller(
        piVersionOutput: String = "pi-coding-agent 0.80.4",
        environment: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> LifecycleHookInstaller {
        LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            fileManager: fileManager,
            piVersionOutput: { piVersionOutput },
            environment: environment
        )
    }

    private func commands(in root: [String: Any], event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any]
        return collectCommands(hooks?[event]).sorted()
    }

    private func commands(in root: [String: Any], event: String, matcher: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any]
        let entries = hooks?[event] as? [[String: Any]] ?? []
        return entries
            .filter { $0["matcher"] as? String == matcher }
            .flatMap(collectCommands)
            .sorted()
    }

    private func collectCommands(_ object: Any?) -> [String] {
        if let dictionary = object as? [String: Any] {
            return ([dictionary["command"] as? String].compactMap { $0 }) + dictionary.values.flatMap(collectCommands)
        }
        return (object as? [Any])?.flatMap(collectCommands) ?? []
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private struct SharedConfigurationBackupFixture: Decodable {
    let provider: String
    let originalPath: String
    let contents: Data
}

private final class BackupMutationFileManager: FileManager {
    private let configurationURL: URL
    private let replacement: Data
    private var didMutate = false

    init(configurationURL: URL, replacement: Data) {
        self.configurationURL = configurationURL
        self.replacement = replacement
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if !didMutate, path.contains("/.atoll/backups/live-status") {
            didMutate = true
            try replacement.write(to: configurationURL, options: .atomic)
        }
    }
}

private final class HomeScopedFileManager: FileManager {
    private let homePath: String

    init(home: URL) {
        homePath = home.path + "/"
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        path.hasPrefix(homePath) && super.fileExists(atPath: path)
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        path.hasPrefix(homePath) && super.isExecutableFile(atPath: path)
    }
}
