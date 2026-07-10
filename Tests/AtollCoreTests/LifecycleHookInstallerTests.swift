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

        let installer = LifecycleHookInstaller(homeDirectory: home, executablePath: executable)
        try installer.install()
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
    }

    func testDoesNotOverwriteInvalidConfiguration() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try LifecycleHookInstaller(homeDirectory: home, executablePath: executable).install())
        XCTAssertEqual(try String(contentsOf: settings), "not json")
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
