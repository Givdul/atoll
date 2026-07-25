import XCTest
@testable import AtollCore

final class LifecycleHookInstallerTests: XCTestCase {
    private var home: URL!
    private let executable = "/Applications/Atoll.app/Contents/MacOS/Atoll"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AtollHookInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testInstallsBridgeAndMergesAllNativeConfigsIdempotently() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        try write(["theme": "dark", "hooks": ["Stop": [["matcher": "existing", "hooks": [["type": "command", "command": "keep-me"]]]]]], to: claude)
        try writeHermesConfig(at: home.appendingPathComponent(".hermes/config.yaml"))
        try writeHermesConfig(at: home.appendingPathComponent(".hermes/profiles/work/config.yaml"))
        let legacyOpenCodePlugin = home.appendingPathComponent(".config/opencode/plugin/atoll.js")
        try FileManager.default.createDirectory(at: legacyOpenCodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// Atoll Live Status managed integration\n// stale".write(to: legacyOpenCodePlugin, atomically: true, encoding: .utf8)

        let installer = makeInstaller()
        try installer.install()
        let piExtension = try String(contentsOf: home.appendingPathComponent(".pi/agent/extensions/atoll.ts"))
        XCTAssertTrue(piExtension.contains("Atoll Live Status managed integration"), piExtension)
        let first = try Data(contentsOf: claude)
        try installer.install()
        XCTAssertEqual(first, try Data(contentsOf: claude))

        let bridge = try String(contentsOf: home.appendingPathComponent(".atoll/bin/atoll-hook"))
        XCTAssertTrue(bridge.contains("'\(executable)' --lifecycle-event \"$1\" \"$2\""))
        XCTAssertTrue(bridge.contains("printf '{}\\n'"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".atoll/bin/atoll-hook").path)[.posixPermissions] as? NSNumber, 0o700)

        let claudeJSON = try read(claude)
        XCTAssertEqual(claudeJSON["theme"] as? String, "dark")
        XCTAssertEqual(commands(in: claudeJSON, event: "UserPromptSubmit"), [hook("claude", "started")])
        XCTAssertTrue(commands(in: claudeJSON, event: "Stop").contains("keep-me"))
        XCTAssertTrue(commands(in: claudeJSON, event: "Stop").contains(hook("claude", "finished")))
        XCTAssertEqual(commands(in: claudeJSON, event: "StopFailure"), [hook("claude", "failed")])
        XCTAssertEqual(commands(in: claudeJSON, event: "Notification", matcher: "permission_prompt"), [hook("claude", "needsPermission")])
        XCTAssertEqual(commands(in: claudeJSON, event: "Notification", matcher: "elicitation_dialog"), [hook("claude", "needsInput")])
        XCTAssertEqual(commands(in: claudeJSON, event: "Notification", matcher: "agent_needs_input"), [hook("claude", "needsInput")])
        XCTAssertEqual(commands(in: claudeJSON, event: "Notification", matcher: "elicitation_complete"), [hook("claude", "started")])
        XCTAssertEqual(commands(in: claudeJSON, event: "PostToolUseFailure", matcher: "*"), [hook("claude", "started")])
        XCTAssertEqual(commands(in: claudeJSON, event: "PermissionDenied", matcher: "*"), [hook("claude", "started")])
        XCTAssertTrue(commands(in: claudeJSON, event: "SessionEnd").isEmpty)

        let codex = try read(home.appendingPathComponent(".codex/hooks.json"))
        XCTAssertEqual(commands(in: codex, event: "UserPromptSubmit"), [hook("codex", "started")])
        XCTAssertEqual(commands(in: codex, event: "Stop"), [hook("codex", "finished")])

        let gemini = try read(home.appendingPathComponent(".gemini/settings.json"))
        XCTAssertEqual(commands(in: gemini, event: "BeforeAgent"), [hook("gemini", "started")])
        XCTAssertEqual(commands(in: gemini, event: "AfterAgent"), [hook("gemini", "finished")])
        XCTAssertEqual(commands(in: gemini, event: "Notification", matcher: "ToolPermission"), [hook("gemini", "needsPermission")])
        XCTAssertEqual(commands(in: gemini, event: "AfterTool", matcher: "*"), [hook("gemini", "started")])
        XCTAssertTrue(commands(in: gemini, event: "SessionEnd").isEmpty)

        let copilot = try read(home.appendingPathComponent(".copilot/hooks/atoll.json"))
        XCTAssertEqual(copilot["version"] as? Int, 1)
        XCTAssertEqual(commands(in: copilot, event: "userPromptSubmitted"), [hook("copilot", "started")])
        XCTAssertEqual(commands(in: copilot, event: "agentStop"), [hook("copilot", "finished")])
        XCTAssertEqual(commands(in: copilot, event: "sessionEnd"), [hook("copilot", "finished")])
        XCTAssertTrue(commands(in: copilot, event: "errorOccurred").isEmpty)
        XCTAssertEqual(commands(in: copilot, event: "notification", matcher: "permission_prompt"), [hook("copilot", "needsPermission")])
        XCTAssertEqual(commands(in: copilot, event: "notification", matcher: "elicitation_dialog"), [hook("copilot", "needsInput")])
        XCTAssertEqual(commands(in: copilot, event: "postToolUseFailure"), [hook("copilot", "started")])

        let pi = try String(contentsOf: home.appendingPathComponent(".pi/agent/extensions/atoll.ts"))
        XCTAssertTrue(pi.contains("agent_settled"))
        XCTAssertTrue(pi.contains("cwd: ctx.sessionManager.getCwd()"))
        XCTAssertTrue(pi.contains("child.on(\"error\", () => {})"))
        XCTAssertTrue(pi.contains("child.stdin.on(\"error\", () => {})"))
        XCTAssertTrue(pi.contains("} catch {}"))
        XCTAssertFalse(pi.contains("cwd: process.cwd()"))

        let openCode = try String(contentsOf: home.appendingPathComponent(".config/opencode/plugins/atoll.js"))
        XCTAssertTrue(openCode.contains("async ({ directory })"))
        XCTAssertTrue(openCode.contains("cwd: directory"))
        XCTAssertTrue(openCode.contains("stdin: \"pipe\""))
        XCTAssertTrue(openCode.contains("child.stdin.write(JSON.stringify"))
        XCTAssertTrue(openCode.contains("child.stdin.end()"))
        XCTAssertTrue(openCode.contains("status.type === \"busy\" || status.type === \"retry\""))
        XCTAssertTrue(openCode.contains("event.type === \"session.error\""))
        XCTAssertTrue(openCode.contains("event.type === \"permission.asked\" || event.type === \"permission.updated\""))
        XCTAssertTrue(openCode.contains("event.type === \"permission.replied\""))
        XCTAssertTrue(openCode.contains("event.type === \"question.asked\""))
        XCTAssertTrue(openCode.contains("event.type === \"question.replied\" || event.type === \"question.rejected\""))
        XCTAssertTrue(openCode.contains("emit(\"needsPermission\", sessionID)"))
        XCTAssertTrue(openCode.contains("emit(\"needsInput\", sessionID)"))
        XCTAssertTrue(openCode.contains("if (!sessionID) return;"))
        XCTAssertTrue(openCode.contains("MessageAbortedError"))
        XCTAssertTrue(openCode.contains("!terminalSessions.has(sessionID)"))
        XCTAssertTrue(openCode.contains("child.exited.catch(() => {})"))
        XCTAssertTrue(openCode.contains("} catch {}"))
        XCTAssertTrue(openCode.contains("""
          const finish = sessionID => {
            if (!sessionID || terminalSessions.has(sessionID)) return;
            terminalSessions.add(sessionID);
            emit("finished", sessionID);
        """))
        XCTAssertTrue(openCode.contains("""
              if (event.type === "session.idle") {
                finish(sessionID);
                return;
        """))
        XCTAssertTrue(openCode.contains("if (status.type === \"idle\") finish(sessionID);"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyOpenCodePlugin.path))

        let amp = try String(contentsOf: home.appendingPathComponent(".config/amp/plugins/atoll.ts"))
        XCTAssertTrue(amp.contains("agent.start"), amp)
        XCTAssertTrue(amp.contains("agent.end"), amp)
        XCTAssertTrue(amp.contains("thread.state.subscribe"), amp)
        XCTAssertTrue(amp.contains("if (state === previousState) return;"), amp)
        XCTAssertTrue(amp.contains("state === \"awaiting-approval\"") && amp.contains("emit(\"needsPermission\", thread.id)"), amp)
        XCTAssertTrue(amp.contains("state === \"running\"") && amp.contains("emit(\"started\", thread.id)"), amp)
        XCTAssertTrue(amp.contains("stateSubscriptions.get(event.thread.id)?.unsubscribe()"), amp)
        XCTAssertTrue(amp.contains("stateSubscriptions.delete(event.thread.id)"), amp)
        XCTAssertTrue(amp.contains("event.status === \"error\" ? \"failed\" : \"cancelled\""), amp)
        XCTAssertTrue(amp.contains("child.on(\"error\", () => {})"), amp)
        XCTAssertTrue(amp.contains("child.stdin.on(\"error\", () => {})"), amp)
        XCTAssertTrue(amp.contains("} catch {}"), amp)

        for profile in [".hermes", ".hermes/profiles/work"] {
            let pluginRoot = home.appendingPathComponent(profile).appendingPathComponent("plugins/atoll-live-status")
            let manifest = try String(contentsOf: pluginRoot.appendingPathComponent("plugin.yaml"))
            let plugin = try String(contentsOf: pluginRoot.appendingPathComponent("__init__.py"))
            XCTAssertTrue(manifest.contains("pre_approval_request"))
            XCTAssertTrue(manifest.contains("post_approval_response"))
            XCTAssertTrue(manifest.contains("on_session_end"))
            XCTAssertTrue(plugin.contains("pre_llm_call"))
            XCTAssertTrue(plugin.contains("ctx.register_hook(\"pre_approval_request\", _on_approval_request)"))
            XCTAssertTrue(plugin.contains("ctx.register_hook(\"post_approval_response\", _on_approval_response)"))
            XCTAssertEqual(plugin.components(separatedBy: "if surface == \"smart\":").count - 1, 2)
            XCTAssertTrue(plugin.contains("session_id=session_id or session_key, prompt=description"))
            XCTAssertTrue(plugin.contains("_emit(\"started\", session_id=session_id or session_key, platform=surface)"))
        }

        let cursor = try read(home.appendingPathComponent(".cursor/hooks.json"))
        XCTAssertEqual(commands(in: cursor, event: "beforeSubmitPrompt"), [hook("cursor", "started")])
        XCTAssertTrue(commands(in: cursor, event: "sessionStart").isEmpty)
        XCTAssertEqual(commands(in: cursor, event: "stop"), [hook("cursor", "finished")])
        XCTAssertTrue(commands(in: cursor, event: "sessionEnd").isEmpty)

        let droid = try read(home.appendingPathComponent(".factory/hooks.json"))
        XCTAssertEqual(commands(in: droid, event: "UserPromptSubmit"), [hook("droid", "started")])
        XCTAssertEqual(commands(in: droid, event: "Stop"), [hook("droid", "finished")])
        XCTAssertTrue(commands(in: droid, event: "SessionEnd").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".factory/settings.json").path))

        for agent in ["qoder", "qwen"] {
            let settings = try read(home.appendingPathComponent(".\(agent)/settings.json"))
            XCTAssertEqual(commands(in: settings, event: "UserPromptSubmit"), [hook(agent, "started")])
            XCTAssertEqual(commands(in: settings, event: "Stop"), [hook(agent, "finished")])
            XCTAssertEqual(commands(in: settings, event: "StopFailure"), [hook(agent, "failed")])
            XCTAssertEqual(commands(in: settings, event: "Notification", matcher: "permission_prompt"), [hook(agent, "needsPermission")])
            XCTAssertEqual(commands(in: settings, event: "PostToolUseFailure", matcher: "*"), [hook(agent, "started")])
            XCTAssertTrue(commands(in: settings, event: "SessionEnd").isEmpty)
        }
        let qoder = try read(home.appendingPathComponent(".qoder/settings.json"))
        XCTAssertEqual(commands(in: qoder, event: "Notification", matcher: "elicitation_dialog"), [hook("qoder", "needsInput")])

        for agent in LifecycleHookInstaller.supportedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .configured, "Expected \(agent.rawValue) to be configured")
        }
    }

    func testEveryVisibleAgentHasNativeLifecycleSupport() {
        let expected: Set<AgentHarness> = [
            .codex, .claude, .gemini, .copilot,
            .pi, .opencode, .cursor, .droid, .qoder, .qwen,
            .hermes, .amp
        ]
        XCTAssertEqual(
            Set(LifecycleHookInstaller.supportedAgents),
            expected
        )
        XCTAssertEqual(Set(AgentHarness.allCases), expected.union([.atoll]))
        XCTAssertNil(AgentHarness.parse("kimi"))
        XCTAssertNil(AgentHarness.parse("kiro"))
        XCTAssertNil(AgentHarness.parse("codebuddy"))
    }

    func testManagedPluginCollisionIsNotOverwritten() throws {
        for (agent, path) in [
            (AgentHarness.amp, ".config/amp/plugins/atoll.ts"),
            (.opencode, ".config/opencode/plugin/atoll.js")
        ] {
            let plugin = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// another plugin".write(to: plugin, atomically: true, encoding: .utf8)

            XCTAssertThrowsError(try makeInstaller().install(agents: [agent]))
            XCTAssertEqual(try String(contentsOf: plugin), "// another plugin")
        }
    }

    func testDoesNotOverwriteInvalidConfiguration() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try makeInstaller().install())
        XCTAssertEqual(try String(contentsOf: settings), "not json")
    }

    func testDetectsOnlyInstalledAgentsAndReportsReadiness() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let installer = makeInstaller()

        XCTAssertTrue(installer.detectedAgents().contains(.codex))
        XCTAssertTrue(installer.detectedAgents().contains(.claude))
        XCTAssertEqual(installer.readiness(for: .codex), .notConfigured)

        try installer.install(agents: [.codex])
        XCTAssertEqual(installer.readiness(for: .codex), .configured)
        XCTAssertEqual(installer.readiness(for: .claude), .notConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    func testReportsInvalidExistingConfigurationWithoutOverwritingIt() throws {
        let copilot = home.appendingPathComponent(".copilot/hooks/atoll.json")
        try write(["hooks": ["agentStop": "not-an-array"]], to: copilot)
        let installer = makeInstaller()

        guard case .invalidConfiguration = installer.readiness(for: .copilot) else {
            return XCTFail("Expected invalid Copilot configuration")
        }
        XCTAssertThrowsError(try installer.install(agents: [.copilot]))
        XCTAssertEqual((try read(copilot)["hooks"] as? [String: Any])?["agentStop"] as? String, "not-an-array")
    }

    func testRejectsMalformedNestedHookShapeWithoutOverwritingIt() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try write([
            "hooks": [
                "UserPromptSubmit": [[
                    "hooks": [
                        "nested": [["type": "command", "command": hook("claude", "started")]]
                    ]
                ]]
            ]
        ], to: settings)
        let original = try Data(contentsOf: settings)
        let installer = makeInstaller()

        guard case .invalidConfiguration = installer.readiness(for: .claude) else {
            return XCTFail("Expected malformed grouped hook shape to be rejected")
        }
        XCTAssertThrowsError(try installer.install(agents: [.claude]))
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testCopilotReadinessAcceptsDocumentedCommandFallbackShape() throws {
        let installer = makeInstaller()
        try installer.install(agents: [])
        let command: (String) -> [String: Any] = { kind in
            ["command": self.hook("copilot", kind)]
        }
        try write([
            "version": 1,
            "hooks": [
                "userPromptSubmitted": [command("started")],
                "agentStop": [command("finished")],
                "sessionEnd": [command("finished")],
                "notification": [
                    ["command": hook("copilot", "needsPermission"), "matcher": "permission_prompt"],
                    ["command": hook("copilot", "needsInput"), "matcher": "elicitation_dialog"]
                ],
                "postToolUse": [command("started")],
                "postToolUseFailure": [command("started")]
            ]
        ], to: home.appendingPathComponent(".copilot/hooks/atoll.json"))

        XCTAssertEqual(installer.readiness(for: .copilot), .configured)
    }

    func testReportsDocumentedHookDisableSettingsWithoutChangingThem() throws {
        let configurations: [(AgentHarness, String, [String: Any])] = [
            (.claude, ".claude/settings.json", ["disableAllHooks": true, "hooks": [:]]),
            (.gemini, ".gemini/settings.json", ["hooksConfig": ["enabled": false], "hooks": [:]]),
            (.copilot, ".copilot/hooks/atoll.json", ["version": 1, "disableAllHooks": true, "hooks": [:]]),
            (.qwen, ".qwen/settings.json", ["disableAllHooks": true, "hooks": [:]])
        ]
        let installer = makeInstaller()

        for (agent, path, object) in configurations {
            let url = home.appendingPathComponent(path)
            try write(object, to: url)
            let original = try Data(contentsOf: url)
            guard case .invalidConfiguration = installer.readiness(for: agent) else {
                return XCTFail("Expected disabled \(agent.rawValue) hooks to require user action")
            }
            XCTAssertThrowsError(try installer.install(agents: [agent]))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testUsesDocumentedCustomUserConfigurationHomes() throws {
        let codex = home.appendingPathComponent("custom-codex")
        let claude = home.appendingPathComponent("custom-claude")
        let copilot = home.appendingPathComponent("custom-copilot")
        let geminiRoot = home.appendingPathComponent("custom-gemini-root")
        let qwen = home.appendingPathComponent("custom-qwen")
        let pi = home.appendingPathComponent("custom-pi-agent")
        let openCode = home.appendingPathComponent("custom-opencode")
        let hermes = home.appendingPathComponent("custom-hermes")
        try FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCode, withIntermediateDirectories: true)
        try writeHermesConfig(at: hermes.appendingPathComponent("config.yaml"))
        try writeHermesConfig(at: hermes.appendingPathComponent("profiles/work/config.yaml"))
        let installer = makeInstaller(environment: [
            "CODEX_HOME": codex.path,
            "CLAUDE_CONFIG_DIR": claude.path,
            "COPILOT_HOME": copilot.path,
            "GEMINI_CLI_HOME": geminiRoot.path,
            "QWEN_HOME": qwen.path,
            "PI_CODING_AGENT_DIR": pi.path,
            "OPENCODE_CONFIG_DIR": openCode.path,
            "HERMES_HOME": hermes.path
        ])

        let agents: [AgentHarness] = [
            .codex, .claude, .copilot, .gemini, .qwen, .pi, .opencode, .hermes
        ]
        XCTAssertTrue(
            Set([AgentHarness.pi, .opencode, .hermes])
                .isSubset(of: Set(installer.detectedAgents()))
        )
        try installer.install(agents: agents)

        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("hooks.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copilot.appendingPathComponent("hooks/atoll.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: geminiRoot.appendingPathComponent(".gemini/settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: qwen.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pi.appendingPathComponent("extensions/atoll.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: openCode.appendingPathComponent("plugins/atoll.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hermes.appendingPathComponent("plugins/atoll-live-status/plugin.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hermes.appendingPathComponent("profiles/work/plugins/atoll-live-status/plugin.yaml").path))
        for agent in agents {
            XCTAssertEqual(installer.readiness(for: agent), .configured)
        }
    }

    func testHermesInheritedHomeActivatesThatProfileWithoutTouchingDefault() throws {
        let root = home.appendingPathComponent(".hermes")
        let defaultConfig = root.appendingPathComponent("config.yaml")
        let activeHome = root.appendingPathComponent("profiles/work")
        let activeConfig = activeHome.appendingPathComponent("config.yaml")
        let disabledConfig = "plugins:\n  enabled:\n"
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        try disabledConfig.write(to: defaultConfig, atomically: true, encoding: .utf8)
        try disabledConfig.write(to: activeConfig, atomically: true, encoding: .utf8)

        let bin = home.appendingPathComponent("bin")
        let hermes = bin.appendingPathComponent("hermes")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        if [ "$1" = "-p" ]; then
          printf 'unexpected profile redirect\n' >&2
          exit 9
        fi
        printf 'plugins:\n  enabled:\n    - atoll-live-status\n' > "$HERMES_HOME/config.yaml"
        """.write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hermes.path)

        let installer = LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            environment: [
                "PATH": bin.path,
                "HERMES_HOME": activeHome.path
            ],
            commandTimeout: 5
        )

        try installer.install(agents: [.hermes])

        XCTAssertEqual(try String(contentsOf: defaultConfig, encoding: .utf8), disabledConfig)
        XCTAssertTrue(try String(contentsOf: activeConfig, encoding: .utf8).contains("atoll-live-status"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeHome.appendingPathComponent("plugins/atoll-live-status/plugin.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins/atoll-live-status/plugin.yaml").path))
        XCTAssertEqual(installer.readiness(for: .hermes), .configured)
    }

    func testHermesDefaultRootSkipsInvalidProfileDirectories() throws {
        let root = home.appendingPathComponent(".hermes")
        try writeHermesConfig(at: root.appendingPathComponent("config.yaml"))
        try writeHermesConfig(at: root.appendingPathComponent("profiles/work/config.yaml"))
        let invalidNames = [
            "default", "hermes", "test", "tmp", "root", "sudo",
            "Uppercase", ".cache", "bad name", String(repeating: "a", count: 65)
        ]
        for name in invalidNames {
            try writeHermesConfig(at: root.appendingPathComponent("profiles/\(name)/config.yaml"))
        }
        let unrelatedDirectory = home.appendingPathComponent("unrelated-hermes-directory")
        try writeHermesConfig(at: unrelatedDirectory.appendingPathComponent("config.yaml"))
        let linkedProfile = root.appendingPathComponent("profiles/linked")
        try FileManager.default.createSymbolicLink(at: linkedProfile, withDestinationURL: unrelatedDirectory)

        let installer = makeInstaller()
        try installer.install(agents: [.hermes])

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins/atoll-live-status/plugin.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles/work/plugins/atoll-live-status/plugin.yaml").path))
        for name in invalidNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("profiles/\(name)/plugins/atoll-live-status/plugin.yaml").path
                ),
                "Unexpected Hermes plugin write for invalid profile directory \(name)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: unrelatedDirectory.appendingPathComponent("plugins/atoll-live-status/plugin.yaml").path
            ),
            "A profile-directory symlink must not redirect Atoll writes outside the Hermes profile root"
        )
    }

    func testPreservesDocumentedCodexHookDisableSettings() throws {
        let configurations = [
            "[features]\nhooks = false # explicitly disabled\n",
            "[features]\ncodex_hooks = false\n",
            "features.hooks = false\n",
            "features.codex_hooks = false\n",
            "codex_hooks = false\n"
        ]
        let config = home.appendingPathComponent(".codex/config.toml")
        let hooks = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)

        for source in configurations {
            try? FileManager.default.removeItem(at: hooks)
            try source.write(to: config, atomically: true, encoding: .utf8)
            let installer = makeInstaller()

            guard case .invalidConfiguration(let detail) = installer.readiness(for: .codex) else {
                return XCTFail("Expected disabled Codex hooks to require user action for \(source)")
            }
            XCTAssertTrue(detail.contains("hooks are disabled"), detail)
            XCTAssertThrowsError(try installer.install(agents: [.codex]))
            XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
        }
    }

    func testCodexHomeExpandsUserRelativePath() throws {
        let installer = makeInstaller(environment: ["CODEX_HOME": "~/alternate-codex"])

        try installer.install(agents: [.codex])

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("alternate-codex/hooks.json").path
            )
        )
        XCTAssertEqual(installer.readiness(for: .codex), .configured)
    }

    func testCodexDisableDetectionIgnoresCommentsAndOtherTables() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = """
        # features.hooks = false
        [other]
        features.hooks = false
        [features]
        hooks = true
        """
        try source.write(to: config, atomically: true, encoding: .utf8)
        let installer = makeInstaller()

        try installer.install(agents: [.codex])

        XCTAssertEqual(installer.readiness(for: .codex), .configured)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), source)
    }

    func testFailureHooksAreRequiredForReadiness() throws {
        let installer = makeInstaller()
        try installer.install(agents: [])

        for (agent, path) in [
            (AgentHarness.claude, ".claude/settings.json"),
            (.qoder, ".qoder/settings.json"),
            (.qwen, ".qwen/settings.json")
        ] {
            let harness = agent.rawValue
            try write([
                "hooks": [
                    "UserPromptSubmit": [["hooks": [["type": "command", "command": hook(harness, "started")]]]],
                    "Stop": [["hooks": [["type": "command", "command": hook(harness, "finished")]]]],
                    "SessionEnd": [["hooks": [["type": "command", "command": hook(harness, "finished")]]]]
                ]
            ], to: home.appendingPathComponent(path))

            XCTAssertEqual(installer.readiness(for: agent), .notConfigured, "Expected \(harness) to require StopFailure")
            try installer.install(agents: [agent])
            XCTAssertEqual(installer.readiness(for: agent), .configured)
        }
    }

    func testDroidUsesCanonicalHooksFileForReadiness() throws {
        let legacySettings = home.appendingPathComponent(".factory/settings.json")
        let hooks: [String: Any] = [
            "UserPromptSubmit": [["hooks": [["type": "command", "command": hook("droid", "started")]]]],
            "Stop": [["hooks": [["type": "command", "command": hook("droid", "finished")]]]],
            "SessionEnd": [["hooks": [["type": "command", "command": hook("droid", "finished")]]]]
        ]
        try write(["hooks": hooks], to: legacySettings)
        let installer = makeInstaller()
        try installer.install(agents: [])

        XCTAssertEqual(installer.readiness(for: .droid), .notConfigured)
        try installer.install(agents: [.droid])
        XCTAssertEqual(installer.readiness(for: .droid), .configured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".factory/hooks.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacySettings.path))
    }

    func testInstallRemovesOnlyLegacyHooks() throws {
        let installer = makeInstaller()
        try installer.install(agents: [])
        let groupedAgents: [(AgentHarness, String, String)] = [
            (.claude, ".claude/settings.json", "SessionEnd"),
            (.gemini, ".gemini/settings.json", "SessionEnd"),
            (.droid, ".factory/hooks.json", "SessionEnd"),
            (.qoder, ".qoder/settings.json", "SessionEnd"),
            (.qwen, ".qwen/settings.json", "SessionEnd")
        ]

        for (agent, path, event) in groupedAgents {
            try write([
                "hooks": [
                    event: [[
                        "hooks": [
                            ["type": "command", "command": hook(agent.rawValue, "finished")],
                            ["type": "command", "command": "keep-me"]
                        ]
                    ]]
                ]
            ], to: home.appendingPathComponent(path))
        }
        try write([
            "hooks": [
                "sessionStart": [
                    ["command": hook("cursor", "started")],
                    ["command": "keep-session-start"]
                ],
                "sessionEnd": [
                    ["command": hook("cursor", "finished")],
                    ["command": "keep-me"]
                ]
            ]
        ], to: home.appendingPathComponent(".cursor/hooks.json"))
        try write([
            "version": 1,
            "hooks": [
                "errorOccurred": [
                    ["type": "command", "bash": hook("copilot", "failed")],
                    ["type": "command", "bash": "keep-error-hook"]
                ]
            ]
        ], to: home.appendingPathComponent(".copilot/hooks/atoll.json"))

        for (agent, _, _) in groupedAgents {
            XCTAssertEqual(installer.readiness(for: agent), .notConfigured)
        }
        XCTAssertEqual(installer.readiness(for: .cursor), .notConfigured)
        XCTAssertEqual(installer.readiness(for: .copilot), .notConfigured)

        try installer.install(agents: groupedAgents.map { $0.0 } + [.cursor, .copilot])

        for (agent, path, event) in groupedAgents {
            XCTAssertEqual(commands(in: try read(home.appendingPathComponent(path)), event: event), ["keep-me"])
            XCTAssertEqual(installer.readiness(for: agent), .configured)
        }
        XCTAssertEqual(commands(in: try read(home.appendingPathComponent(".cursor/hooks.json")), event: "sessionEnd"), ["keep-me"])
        XCTAssertEqual(commands(in: try read(home.appendingPathComponent(".cursor/hooks.json")), event: "sessionStart"), ["keep-session-start"])
        XCTAssertEqual(installer.readiness(for: .cursor), .configured)
        XCTAssertEqual(commands(in: try read(home.appendingPathComponent(".copilot/hooks/atoll.json")), event: "errorOccurred"), ["keep-error-hook"])
        XCTAssertEqual(installer.readiness(for: .copilot), .configured)
    }

    func testPiRequiresVersionWithLifecycleContextSupport() throws {
        let supported = makeInstaller(piVersionOutput: "pi-coding-agent 0.80.4")
        try supported.install(agents: [.pi])
        XCTAssertEqual(supported.readiness(for: .pi), .configured)

        let old = makeInstaller(piVersionOutput: "pi-coding-agent 0.80.3")
        XCTAssertTrue(old.detectedAgents().contains(.pi))
        XCTAssertEqual(
            old.readiness(for: .pi),
            .invalidConfiguration("Pi 0.80.4 or newer is required for Live Status; found 0.80.3.")
        )
        XCTAssertThrowsError(try old.install(agents: [.pi])) { error in
            XCTAssertEqual(error.localizedDescription, "Pi 0.80.4 or newer is required for Live Status; found 0.80.3.")
        }

        let prerelease = makeInstaller(piVersionOutput: "0.80.4-beta.1")
        XCTAssertEqual(
            prerelease.readiness(for: .pi),
            .invalidConfiguration("Pi 0.80.4 or newer is required for Live Status; found 0.80.4-prerelease.")
        )

        let unverifiable = makeInstaller(piVersionOutput: "not a version")
        XCTAssertEqual(
            unverifiable.readiness(for: .pi),
            .invalidConfiguration("Pi 0.80.4 or newer is required for Live Status, but Atoll could not verify it: `pi --version` returned \"not a version\".")
        )
    }

    func testManagedIntegrationsRequireCurrentContentAndCanBeRepaired() throws {
        try writeHermesConfig(at: home.appendingPathComponent(".hermes/config.yaml"))
        let installer = makeInstaller()
        let agents: [AgentHarness] = [.pi, .opencode, .amp, .hermes]
        try installer.install(agents: agents)

        let managedFiles: [(AgentHarness, String, String)] = [
            (.pi, ".pi/agent/extensions/atoll.ts", "// Atoll Live Status managed integration\n// stale"),
            (.opencode, ".config/opencode/plugins/atoll.js", "// Atoll Live Status managed integration\n// stale"),
            (.amp, ".config/amp/plugins/atoll.ts", "// Atoll Live Status managed integration\n// stale"),
            (.hermes, ".hermes/plugins/atoll-live-status/__init__.py", "# Atoll Live Status managed integration\n# stale")
        ]

        for (agent, path, staleSource) in managedFiles {
            let url = home.appendingPathComponent(path)
            try staleSource.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(installer.readiness(for: agent), .notConfigured, "Expected stale \(agent.rawValue) content to need repair")

            try installer.install(agents: [agent])
            XCTAssertEqual(installer.readiness(for: agent), .configured, "Expected \(agent.rawValue) repair to restore readiness")
            XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), staleSource)
        }
    }

    func testEveryIntegrationRequiresTheCurrentExecutableBridge() throws {
        let installer = makeInstaller()
        let bridge = home.appendingPathComponent(".atoll/bin/atoll-hook")
        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)

        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)

        try "#!/bin/sh\nexit 0\n".write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)

        try installer.install(agents: [.pi])
        try FileManager.default.removeItem(at: bridge)
        XCTAssertEqual(installer.readiness(for: .pi), .notConfigured)

        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)
    }

    func testDetectionUsesFallbackExecutableDirectories() throws {
        let executable = home.appendingPathComponent(".local/bin/pi")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let detected = makeInstaller().detectedAgents()
        XCTAssertTrue(detected.contains(.pi))
    }

    func testPiVersionCommandDrainsLargeOutputWithoutDeadlocking() throws {
        let bin = home.appendingPathComponent("bin")
        let pi = bin.appendingPathComponent("pi")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf 'pi-coding-agent 0.80.4\\n'
        index=0
        while [ "$index" -lt 3072 ]; do
          printf '0123456789abcdef0123456789abcdef\\n'
          index=$((index + 1))
        done
        """.write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pi.path)

        let installer = LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            environment: ["PATH": bin.path],
            commandTimeout: 5
        )

        try installer.install(agents: [.pi])
        XCTAssertEqual(installer.readiness(for: .pi), .configured)
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

    func testHermesEnableFailureCapturesStandardError() throws {
        let bin = home.appendingPathComponent("bin")
        let hermes = bin.appendingPathComponent("hermes")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf 'Hermes rejected the plugin activation\\n' >&2
        exit 9
        """.write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hermes.path)
        let config = home.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plugins:\n  enabled:\n".write(to: config, atomically: true, encoding: .utf8)
        let installer = LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            environment: ["PATH": bin.path],
            commandTimeout: 5
        )

        XCTAssertThrowsError(try installer.install(agents: [.hermes])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Hermes rejected the plugin activation"), error.localizedDescription)
        }
    }

    private func hook(_ harness: String, _ kind: String) -> String { "'\(home.path)/.atoll/bin/atoll-hook' \(harness) \(kind)" }

    private func makeInstaller(
        piVersionOutput: String = "pi-coding-agent 0.80.4",
        environment: [String: String] = [:]
    ) -> LifecycleHookInstaller {
        LifecycleHookInstaller(
            homeDirectory: home,
            executablePath: executable,
            piVersionOutput: { piVersionOutput },
            environment: environment
        )
    }

    private func writeHermesConfig(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plugins:\n  enabled:\n    - atoll-live-status\n".write(to: url, atomically: true, encoding: .utf8)
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
            return ([dictionary["command"] as? String, dictionary["bash"] as? String].compactMap { $0 }) + dictionary.values.flatMap(collectCommands)
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
