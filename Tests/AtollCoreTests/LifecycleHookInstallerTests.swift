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
        try write(["name": "Personal"], to: home.appendingPathComponent(".kiro/agents/personal.json"))

        let installer = LifecycleHookInstaller(homeDirectory: home, executablePath: executable)
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
        XCTAssertEqual(commands(in: claudeJSON, event: "SessionEnd"), [hook("claude", "finished")])

        let codex = try read(home.appendingPathComponent(".codex/hooks.json"))
        XCTAssertEqual(commands(in: codex, event: "UserPromptSubmit"), [hook("codex", "started")])
        XCTAssertEqual(commands(in: codex, event: "Stop"), [hook("codex", "finished")])

        let gemini = try read(home.appendingPathComponent(".gemini/settings.json"))
        XCTAssertEqual(commands(in: gemini, event: "BeforeAgent"), [hook("gemini", "started")])
        XCTAssertEqual(commands(in: gemini, event: "AfterAgent"), [hook("gemini", "finished")])
        XCTAssertEqual(commands(in: gemini, event: "SessionEnd"), [hook("gemini", "finished")])

        let copilot = try read(home.appendingPathComponent(".copilot/hooks/atoll.json"))
        XCTAssertEqual(copilot["version"] as? Int, 1)
        XCTAssertEqual(commands(in: copilot, event: "userPromptSubmitted"), [hook("copilot", "started")])
        XCTAssertEqual(commands(in: copilot, event: "agentStop"), [hook("copilot", "finished")])
        XCTAssertEqual(commands(in: copilot, event: "sessionEnd"), [hook("copilot", "finished")])
        XCTAssertEqual(commands(in: copilot, event: "errorOccurred"), [hook("copilot", "failed")])

        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".pi/agent/extensions/atoll.ts")).contains("agent_settled"))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".config/opencode/plugin/atoll.js")).contains("session.status"))
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".kimi-code/config.toml")).contains("Atoll Live Status managed integration"))

        let cursor = try read(home.appendingPathComponent(".cursor/hooks.json"))
        XCTAssertEqual(commands(in: cursor, event: "sessionStart"), [hook("cursor", "started")])
        XCTAssertEqual(commands(in: cursor, event: "stop"), [hook("cursor", "finished")])
        XCTAssertEqual(commands(in: cursor, event: "sessionEnd"), [hook("cursor", "finished")])

        for agent in ["droid", "qoder", "qwen"] {
            let settings = try read(home.appendingPathComponent(".\(agent == "droid" ? "factory" : agent)/settings.json"))
            XCTAssertEqual(commands(in: settings, event: "UserPromptSubmit"), [hook(agent, "started")])
            XCTAssertEqual(commands(in: settings, event: "Stop"), [hook(agent, "finished")])
            XCTAssertEqual(commands(in: settings, event: "SessionEnd"), [hook(agent, "finished")])
        }

        let kiro = try read(home.appendingPathComponent(".kiro/agents/personal.json"))
        XCTAssertEqual(commands(in: kiro, event: "agentSpawn"), [hook("kiro", "started")])
        XCTAssertEqual(commands(in: kiro, event: "stop"), [hook("kiro", "finished")])
    }

    func testDoesNotOverwriteInvalidConfiguration() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try LifecycleHookInstaller(homeDirectory: home, executablePath: executable).install())
        XCTAssertEqual(try String(contentsOf: settings), "not json")
    }

    func testDetectsOnlyInstalledAgentsAndReportsReadiness() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let installer = LifecycleHookInstaller(homeDirectory: home, executablePath: executable)

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
        let installer = LifecycleHookInstaller(homeDirectory: home, executablePath: executable)

        guard case .invalidConfiguration = installer.readiness(for: .copilot) else {
            return XCTFail("Expected invalid Copilot configuration")
        }
        XCTAssertThrowsError(try installer.install(agents: [.copilot]))
        XCTAssertEqual((try read(copilot)["hooks"] as? [String: Any])?["agentStop"] as? String, "not-an-array")
    }

    func testKiroRequiresAnExistingCustomAgent() throws {
        let installer = LifecycleHookInstaller(homeDirectory: home, executablePath: executable)
        XCTAssertThrowsError(try installer.install(agents: [.kiro])) { error in
            XCTAssertEqual(error.localizedDescription, "Create a Kiro CLI custom agent in \(self.home.appendingPathComponent(".kiro/agents").path) first, then run Live Status Setup again.")
        }
    }

    private func hook(_ harness: String, _ kind: String) -> String { "'\(home.path)/.atoll/bin/atoll-hook' \(harness) \(kind)" }

    private func commands(in root: [String: Any], event: String) -> [String] {
        let hooks = root["hooks"] as? [String: Any]
        return collectCommands(hooks?[event]).sorted()
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
