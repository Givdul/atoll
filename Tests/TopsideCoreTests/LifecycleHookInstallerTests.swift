import XCTest
@testable import TopsideCore

final class LifecycleHookInstallerTests: XCTestCase {
    private var home: URL!
    private let executable = "/Applications/Topside.app/Contents/MacOS/Topside"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("TopsideHookInstallerTests-\(UUID().uuidString)")
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
        let legacyOpenCodePlugin = home.appendingPathComponent(".config/opencode/plugin/topside.js")
        try FileManager.default.createDirectory(at: legacyOpenCodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Topside Live Status managed integration\n// stale".write(to: legacyOpenCodePlugin, atomically: true, encoding: .utf8)

        let installer = makeInstaller()
        try installer.install(agents: LifecycleHookInstaller.supportedAgents)
        let firstClaudeConfiguration = try Data(contentsOf: claudeURL)
        try installer.install(agents: LifecycleHookInstaller.supportedAgents)
        XCTAssertEqual(firstClaudeConfiguration, try Data(contentsOf: claudeURL))

        let bridgeURL = home.appendingPathComponent(".topside/bin/topside-hook")
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
        XCTAssertEqual(
            commands(in: claude, event: "Notification", matcher: "agent_needs_input"),
            [hook("claude", "needsInput")]
        )
        XCTAssertEqual(
            commands(in: claude, event: "Notification", matcher: "elicitation_complete"),
            [hook("claude", "started")]
        )
        XCTAssertEqual(
            commands(in: claude, event: "Notification", matcher: "elicitation_response"),
            [hook("claude", "started")]
        )
        XCTAssertEqual(commands(in: claude, event: "PostToolUse", matcher: "*"), [hook("claude", "started")])
        XCTAssertEqual(commands(in: claude, event: "PostToolUseFailure", matcher: "*"), [hook("claude", "started")])
        XCTAssertEqual(commands(in: claude, event: "PermissionDenied", matcher: "*"), [hook("claude", "started")])
        XCTAssertTrue(commands(in: claude, event: "SessionEnd").isEmpty)

        let cursor = try read(home.appendingPathComponent(".cursor/hooks.json"))
        XCTAssertEqual(commands(in: cursor, event: "beforeSubmitPrompt"), [hook("cursor", "started")])
        XCTAssertEqual(commands(in: cursor, event: "stop"), [hook("cursor", "finished")])
        XCTAssertTrue(commands(in: cursor, event: "sessionStart").isEmpty)
        XCTAssertTrue(commands(in: cursor, event: "sessionEnd").isEmpty)

        let pi = try String(contentsOf: home.appendingPathComponent(".pi/agent/extensions/topside.ts"), encoding: .utf8)
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
            contentsOf: home.appendingPathComponent(".config/opencode/plugins/topside.js"),
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyOpenCodePlugin.path))

        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .configured, "\(agent.rawValue) should be configured")
        }
    }

    func testReadinessAndDoctorShareTheSameContractClassification() throws {
        let installer = makeInstaller()
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try installer.install(agents: [.claude])
        var claude = try read(claudeURL)
        var hooks = try XCTUnwrap(claude["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "PostToolUseFailure")
        claude["hooks"] = hooks
        try write(claude, to: claudeURL)

        XCTAssertEqual(installer.readiness(for: .claude), .notConfigured)
        XCTAssertEqual(
            installer.diagnostic(
                for: .claude,
                socketAvailable: true,
                lastValidEventAt: nil
            ).integration,
            .outdated
        )
    }

    func testRepairMigratesEveryOwnedAtollIntegrationAndPreservesUnrelatedConfiguration() throws {
        let codex = home.appendingPathComponent(".codex/hooks.json")
        try write([
            "keep": true,
            "hooks": [
                "UserPromptSubmit": [[
                    "hooks": [
                        ["type": "command", "command": betaHook("codex", "started")],
                        ["type": "command", "command": "keep-codex"]
                    ]
                ]]
            ]
        ], to: codex)

        let claude = home.appendingPathComponent(".claude/settings.json")
        try write([
            "theme": "dark",
            "hooks": [
                "Stop": [[
                    "hooks": [
                        ["type": "command", "command": betaHook("claude", "finished")],
                        ["type": "command", "command": "keep-claude"]
                    ]
                ]]
            ]
        ], to: claude)

        let cursor = home.appendingPathComponent(".cursor/hooks.json")
        try write([
            "version": 1,
            "hooks": [
                "beforeSubmitPrompt": [
                    ["command": betaHook("cursor", "started")],
                    ["command": "keep-cursor"]
                ]
            ]
        ], to: cursor)

        let betaPi = home.appendingPathComponent(".pi/agent/extensions/atoll.ts")
        try FileManager.default.createDirectory(
            at: betaPi.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        // Atoll Live Status managed integration
        const bridge = "\(home.path)/.atoll/bin/atoll-hook";
        """.write(
            to: betaPi,
            atomically: true,
            encoding: .utf8
        )

        let betaOpenCode = home.appendingPathComponent(".config/opencode/plugins/atoll.js")
        let unrelatedOpenCode = home.appendingPathComponent(".config/opencode/plugin/atoll.js")
        try FileManager.default.createDirectory(
            at: betaOpenCode.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelatedOpenCode.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        // Atoll Live Status managed integration
        const bridge = "\(home.path)/.atoll/bin/atoll-hook";
        """.write(
            to: betaOpenCode,
            atomically: true,
            encoding: .utf8
        )
        try "// user-owned wrapper mentioning Atoll Live Status managed integration\n".write(
            to: unrelatedOpenCode,
            atomically: true,
            encoding: .utf8
        )

        let installer = makeInstaller()
        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .notConfigured, agent.rawValue)
        }

        try installer.install(agents: LifecycleHookInstaller.supportedAgents)

        XCTAssertEqual(try read(codex)["keep"] as? Bool, true)
        XCTAssertTrue(commands(in: try read(codex), event: "UserPromptSubmit").contains("keep-codex"))
        XCTAssertFalse(
            commands(in: try read(codex), event: "UserPromptSubmit")
                .contains(betaHook("codex", "started"))
        )
        XCTAssertEqual(try read(claude)["theme"] as? String, "dark")
        XCTAssertTrue(commands(in: try read(claude), event: "Stop").contains("keep-claude"))
        XCTAssertFalse(commands(in: try read(claude), event: "Stop").contains(betaHook("claude", "finished")))
        XCTAssertTrue(commands(in: try read(cursor), event: "beforeSubmitPrompt").contains("keep-cursor"))
        XCTAssertFalse(
            commands(in: try read(cursor), event: "beforeSubmitPrompt")
                .contains(betaHook("cursor", "started"))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: betaPi.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: betaOpenCode.path))
        XCTAssertEqual(
            try String(contentsOf: unrelatedOpenCode, encoding: .utf8),
            "// user-owned wrapper mentioning Atoll Live Status managed integration\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".pi/agent/extensions/topside.ts").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".config/opencode/plugins/topside.js").path
            )
        )
        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .configured, agent.rawValue)
        }
    }

    func testRepairMigratesOwnedSkerryIntegrations() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write([
            "hooks": [
                "Stop": [[
                    "hooks": [["type": "command", "command": skerryHook("claude", "finished")]]
                ]]
            ]
        ], to: claude)

        let pi = home.appendingPathComponent(".pi/agent/extensions/skerry.ts")
        try FileManager.default.createDirectory(at: pi.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        // Skerry Live Status managed integration
        const bridge = "\(home.path)/.skerry/bin/skerry-hook";
        """.write(
            to: pi,
            atomically: true,
            encoding: .utf8
        )
        let openCode = home.appendingPathComponent(".config/opencode/plugins/skerry.js")
        try FileManager.default.createDirectory(at: openCode.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        // Skerry Live Status managed integration
        const bridge = "\(home.path)/.skerry/bin/skerry-hook";
        """.write(
            to: openCode,
            atomically: true,
            encoding: .utf8
        )

        let installer = makeInstaller()
        try installer.install(agents: [.claude, .pi, .opencode])

        XCTAssertFalse(commands(in: try read(claude), event: "Stop").contains(skerryHook("claude", "finished")))
        XCTAssertTrue(commands(in: try read(claude), event: "Stop").contains(hook("claude", "finished")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pi.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openCode.path))
        XCTAssertEqual(installer.readiness(for: .claude), .configured)
        XCTAssertEqual(installer.readiness(for: .pi), .configured)
        XCTAssertEqual(installer.readiness(for: .opencode), .configured)
    }

    func testSupportedHarnessesAreExactlyTheFiveShippedAgentsInDisplayOrder() {
        let expected: [AgentHarness] = [.codex, .claude, .cursor, .opencode, .pi]
        XCTAssertEqual(LifecycleHookInstaller.supportedAgents, expected)
        XCTAssertEqual(Set(AgentHarness.allCases), Set(expected).union([.topside]))
        for removed in ["gemini", "copilot", "droid", "qoder", "qwen", "hermes", "amp", "kimi", "kiro", "codebuddy"] {
            XCTAssertNil(AgentHarness.parse(removed))
        }
    }

    func testTopsideHarnessDecodesLegacySkerryAndEncodesCurrentIdentity() throws {
        XCTAssertEqual(AgentHarness.parse("topside"), .topside)
        XCTAssertEqual(AgentHarness.parse("skerry"), .topside)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentHarness.self, from: Data("\"skerry\"".utf8)),
            .topside
        )
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(AgentHarness.topside), encoding: .utf8),
            "\"topside\""
        )
    }

    func testManagedPluginCollisionIsNotOverwritten() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugins/topside.js")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)

        let installer = makeInstaller()
        XCTAssertTrue(installer.canUninstall(for: .opencode))
        XCTAssertThrowsError(try installer.install(agents: [.opencode]))
        XCTAssertEqual(try String(contentsOf: plugin, encoding: .utf8), "// another plugin")
    }

    func testUnownedLegacyPluginIsPreserved() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugin/topside.js")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)

        try makeInstaller().install(agents: [.opencode])
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: pi.appendingPathComponent("extensions/topside.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: openCode.appendingPathComponent("plugins/topside.js").path))
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
            (.pi, ".pi/agent/extensions/topside.ts"),
            (.opencode, ".config/opencode/plugins/topside.js")
        ]
        for (agent, path) in managedFiles {
            let url = home.appendingPathComponent(path)
            try "// Topside Live Status managed integration\nconst bridge = \"\(home.path)/.topside/bin/topside-hook\"; // stale".write(to: url, atomically: true, encoding: .utf8)
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
        let bridge = home.appendingPathComponent(".topside/bin/topside-hook")
        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)

        try installer.install(agents: [.pi])
        try "#!/bin/sh\nexit 0\n".write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)
    }

    func testInstallDoesNotCreateRecoveryBackups() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write(["theme": "dark"], to: claude)
        let installer = makeInstaller()

        try installer.install(agents: [.claude, .codex])

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".topside/backups").path
            )
        )
    }

    func testSharedConfigurationMutationDoesNotOverwriteConcurrentChanges() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write(["theme": "before"], to: claude)
        let replacement = try JSONSerialization.data(withJSONObject: ["theme": "concurrent"])
        let fileManager = ConfigurationMutationFileManager(
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".topside/backups").path
            )
        )
    }

    func testInstallAndUninstallPreserveSharedConfigurationSymlink() throws {
        let target = home.appendingPathComponent("shared/claude-settings.json")
        try write(["theme": "dark"], to: target)
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".topside/backups").path
            )
        )
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside/bin/topside-hook").path))
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
        try installer.install(agents: LifecycleHookInstaller.supportedAgents)
        try installer.install(agents: LifecycleHookInstaller.supportedAgents)

        XCTAssertEqual(installer.uninstall(agents: [.claude]).map(\.outcome), [.removed])
        XCTAssertFalse(installer.hasIntegration(for: .claude))
        XCTAssertTrue(installer.hasIntegration(for: .codex))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside/bin/topside-hook").path))

        let remaining: [AgentHarness] = [.codex, .cursor, .opencode, .pi]
        XCTAssertEqual(installer.uninstall(agents: remaining).map(\.outcome), Array(repeating: .removed, count: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside/bin/topside-hook").path))
        XCTAssertEqual(installer.uninstall(agents: LifecycleHookInstaller.supportedAgents).map(\.outcome), Array(repeating: .notInstalled, count: 5))

        try installer.install(agents: LifecycleHookInstaller.supportedAgents)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside/bin/topside-hook").path))
        XCTAssertEqual(installer.uninstall(agents: [.codex]).map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".topside/bin/topside-hook").path))
    }

    func testUninstallPreservesAndReportsUnownedOrMalformedFiles() throws {
        let installer = makeInstaller()
        try installer.install(agents: LifecycleHookInstaller.supportedAgents)
        let bridge = home.appendingPathComponent(".topside/bin/topside-hook")
        let pi = home.appendingPathComponent(".pi/agent/extensions/topside.ts")
        let openCode = home.appendingPathComponent(".config/opencode/plugins/topside.js")
        let codex = home.appendingPathComponent(".codex/hooks.json")
        let unownedPi = "// user extension\nconst bridge = \"\(bridge.path)\";\n"
        let unownedOpenCode = "// user plugin\n"
        let malformedCodex = Data([0xFF, 0xFE, 0xFD])
        try unownedPi.write(to: pi, atomically: true, encoding: .utf8)
        try unownedOpenCode.write(to: openCode, atomically: true, encoding: .utf8)
        try malformedCodex.write(to: codex, options: .atomic)

        let results = installer.uninstall(agents: LifecycleHookInstaller.supportedAgents)
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

    func testManagedFileRepairAndRemovalPreserveConcurrentReplacement() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugins/topside.js")
        let seedInstaller = makeInstaller()
        try seedInstaller.install(agents: [.opencode])
        let owned = try String(contentsOf: plugin, encoding: .utf8) + "\n// stale\n"
        try owned.write(to: plugin, atomically: true, encoding: .utf8)
        let replacement = Data("// user plugin\n".utf8)

        let repairFileManager = ManagedFileMutationFileManager(target: plugin, replacement: replacement)
        XCTAssertThrowsError(try makeInstaller(fileManager: repairFileManager).install(agents: [.opencode]))
        XCTAssertEqual(try Data(contentsOf: plugin), replacement)

        try FileManager.default.removeItem(at: plugin)
        try seedInstaller.install(agents: [.opencode])
        let removalFileManager = ManagedFileMutationFileManager(target: plugin, replacement: replacement)
        let removal = makeInstaller(fileManager: removalFileManager).uninstall(agents: [.opencode])
        guard case .failed = removal.first?.outcome else {
            return XCTFail("Expected concurrent replacement to stop removal")
        }
        XCTAssertEqual(try Data(contentsOf: plugin), replacement)
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

    func testDoctorHealthFixturesCoverEveryState() {
        typealias Diagnostic = LifecycleHookInstaller.Diagnostic
        let eventTime = Date(timeIntervalSince1970: 123)
        let fixtures: [(Diagnostic, Diagnostic.Health)] = [
            (Diagnostic(agent: .codex, agentFound: false, integration: .missing, bridge: .missing, shadowing: .notDetected, socketAvailable: false, lastValidEventAt: nil), .agentNotFound),
            (Diagnostic(agent: .codex, agentFound: true, integration: .missing, bridge: .current, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: eventTime), .integrationMissing),
            (Diagnostic(agent: .codex, agentFound: true, integration: .outdated, bridge: .current, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: eventTime), .integrationOutdated),
            (Diagnostic(agent: .codex, agentFound: true, integration: .invalid("invalid"), bridge: .current, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: eventTime), .externalConfiguration("invalid")),
            (Diagnostic(agent: .claude, agentFound: true, integration: .current, bridge: .current, shadowing: .blocked("managed"), socketAvailable: true, lastValidEventAt: eventTime), .shadowed("managed")),
            (Diagnostic(agent: .codex, agentFound: true, integration: .current, bridge: .incorrectPermissions, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: eventTime), .bridgeUnavailable),
            (Diagnostic(agent: .codex, agentFound: true, integration: .current, bridge: .current, shadowing: .notDetected, socketAvailable: false, lastValidEventAt: eventTime), .socketUnavailable),
            (Diagnostic(agent: .codex, agentFound: true, integration: .current, bridge: .current, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: nil), .runtimeUnverified),
            (Diagnostic(agent: .codex, agentFound: true, integration: .current, bridge: .current, shadowing: .notDetected, socketAvailable: true, lastValidEventAt: eventTime), .ready(eventTime))
        ]

        for (diagnostic, expected) in fixtures {
            XCTAssertEqual(diagnostic.health, expected)
        }
    }

    func testDoctorRepairsEverySupportedProviderAndRerunsCleanly() throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for command in ["codex", "claude", "cursor", "opencode", "pi"] {
            let executable = bin.appendingPathComponent(command)
            try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let installer = makeInstaller(
            environment: ["PATH": bin.path],
            fileManager: HomeScopedFileManager(home: home)
        )

        for agent in LifecycleHookInstaller.supportedAgents {
            let before = installer.diagnostic(for: agent, socketAvailable: true, lastValidEventAt: nil)
            XCTAssertEqual(before.health, .integrationMissing, agent.rawValue)
            XCTAssertTrue(before.canRepair, agent.rawValue)

            try installer.install(agents: [agent])
            let after = installer.diagnostic(for: agent, socketAvailable: true, lastValidEventAt: nil)
            XCTAssertEqual(after.integration, .current, agent.rawValue)
            XCTAssertEqual(after.bridge, .current, agent.rawValue)
            XCTAssertEqual(after.health, .runtimeUnverified, agent.rawValue)
            XCTAssertFalse(after.canRepair, agent.rawValue)

            try installer.install(agents: [agent])
            XCTAssertEqual(
                installer.diagnostic(for: agent, socketAvailable: true, lastValidEventAt: nil),
                after,
                agent.rawValue
            )
        }
    }

    func testDoctorDoesNotOfferRepairForUnownedManagedFile() throws {
        let plugin = home.appendingPathComponent(".config/opencode/plugins/topside.js")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("opencode")
        try "#!/bin/sh\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let installer = makeInstaller(environment: ["PATH": bin.path])

        let diagnostic = installer.diagnostic(for: .opencode, socketAvailable: true, lastValidEventAt: nil)
        guard case .unowned = diagnostic.integration else {
            return XCTFail("Expected an unowned integration")
        }
        XCTAssertFalse(diagnostic.canRepair)
    }

    func testDoctorReportsLocallyVisibleCodexManagedPolicies() throws {
        let requirements = home.appendingPathComponent("requirements.toml")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)

        try "[features]\nhooks = false\n".write(to: requirements, atomically: true, encoding: .utf8)
        var diagnostic = makeInstaller(
            environment: ["PATH": bin.path],
            codexRequirementsURL: requirements
        ).diagnostic(for: .codex, socketAvailable: true, lastValidEventAt: Date())
        guard case .disabled = diagnostic.integration else {
            return XCTFail("Expected managed hooks=false to be reported")
        }
        XCTAssertFalse(diagnostic.canRepair)

        try "allow_managed_hooks_only = true\n".write(to: requirements, atomically: true, encoding: .utf8)
        diagnostic = makeInstaller(
            environment: ["PATH": bin.path],
            codexRequirementsURL: requirements
        ).diagnostic(for: .codex, socketAvailable: true, lastValidEventAt: Date())
        guard case .shadowed = diagnostic.health else {
            return XCTFail("Expected managed-only hooks to shadow the user integration")
        }
        XCTAssertFalse(diagnostic.canRepair)

        try "[profile]\nallow_managed_hooks_only = true\n".write(to: requirements, atomically: true, encoding: .utf8)
        diagnostic = makeInstaller(
            environment: ["PATH": bin.path],
            codexRequirementsURL: requirements
        ).diagnostic(for: .codex, socketAvailable: true, lastValidEventAt: Date())
        XCTAssertEqual(diagnostic.shadowing, .notDetected)

        let userConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: userConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".write(to: userConfig, atomically: true, encoding: .utf8)
        try "[features]\nhooks = true\n".write(to: requirements, atomically: true, encoding: .utf8)
        let managedInstaller = makeInstaller(
            environment: ["PATH": bin.path],
            codexRequirementsURL: requirements
        )
        diagnostic = managedInstaller.diagnostic(
            for: .codex,
            socketAvailable: true,
            lastValidEventAt: Date()
        )
        XCTAssertEqual(diagnostic.integration, .missing)
        XCTAssertTrue(diagnostic.canRepair)
    }

    private func hook(_ harness: String, _ kind: String) -> String {
        "'\(home.path)/.topside/bin/topside-hook' \(harness) \(kind)"
    }

    private func skerryHook(_ harness: String, _ kind: String) -> String {
        "'\(home.path)/.skerry/bin/skerry-hook' \(harness) \(kind)"
    }

    private func betaHook(_ harness: String, _ kind: String) -> String {
        "'\(home.path)/.atoll/bin/atoll-hook' \(harness) \(kind)"
    }

    private func makeInstaller(
        piVersionOutput: String = "pi-coding-agent 0.80.4",
        environment: [String: String] = [:],
        fileManager: FileManager = .default,
        codexRequirementsURL: URL = URL(fileURLWithPath: "/etc/codex/requirements.toml")
    ) -> LifecycleHookInstaller {
        LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            fileManager: fileManager,
            piVersionOutput: { piVersionOutput },
            environment: environment,
            codexRequirementsURL: codexRequirementsURL
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

private final class ConfigurationMutationFileManager: FileManager {
    private let configurationURL: URL
    private let replacement: Data
    private var didMutate = false

    init(configurationURL: URL, replacement: Data) {
        self.configurationURL = configurationURL
        self.replacement = replacement
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        if !didMutate, url.standardizedFileURL == configurationURL.deletingLastPathComponent().standardizedFileURL {
            didMutate = true
            try replacement.write(to: configurationURL, options: .atomic)
        }
    }
}

private final class ManagedFileMutationFileManager: FileManager {
    private let target: URL
    private let replacement: Data
    private var targetChecks = 0

    init(target: URL, replacement: Data) {
        self.target = target
        self.replacement = replacement
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if path == target.path {
            targetChecks += 1
            if targetChecks == 2 {
                try? replacement.write(to: target, options: .atomic)
            }
        }
        return super.fileExists(atPath: path)
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
