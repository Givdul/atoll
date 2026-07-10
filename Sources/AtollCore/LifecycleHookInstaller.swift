import Foundation

/// Installs the small native-hook bridge. Call this only from an explicit user action.
public struct LifecycleHookInstaller {
    public enum Readiness: Equatable {
        case notConfigured
        case configured
        case invalidConfiguration(String)
    }

    public static let supportedAgents: [AgentHarness] = [.codex, .claude, .gemini, .copilot]
    public enum Error: Swift.Error, LocalizedError {
        case invalidJSON(URL)
        case invalidHookConfiguration(URL)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let url): "Cannot merge hooks because \(url.path) is not a JSON object."
            case .invalidHookConfiguration(let url): "Cannot merge hooks because \(url.path) has an invalid hooks configuration."
            }
        }
    }

    public let homeDirectory: URL
    public let executablePath: String
    private let fileManager: FileManager

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String = "/Applications/Atoll.app/Contents/MacOS/Atoll",
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
    }

    public func install() throws {
        try install(agents: Self.supportedAgents)
    }

    public func install(agents: [AgentHarness]) throws {
        try writeBridge()
        for agent in agents {
            switch agent {
            case .codex: try mergeCodexHooks()
            case .claude: try mergeClaudeHooks()
            case .gemini: try mergeGeminiHooks()
            case .copilot: try mergeCopilotHooks()
            default: break
            }
        }
    }

    public func detectedAgents() -> [AgentHarness] {
        Self.supportedAgents.filter { configurationDirectory(for: $0).map { fileManager.fileExists(atPath: $0.path) } == true || commandIsAvailable($0.rawValue) }
    }

    public func readiness(for agent: AgentHarness) -> Readiness {
        guard Self.supportedAgents.contains(agent) else { return .notConfigured }
        do {
            let url = configurationURL(for: agent)
            let root = try jsonObject(at: url)
            try validateHookConfiguration(root, at: url)
            return hasAllCommands(in: root, for: agent) ? .configured : .notConfigured
        } catch {
            return .invalidConfiguration(error.localizedDescription)
        }
    }

    private var bridgeURL: URL { homeDirectory.appendingPathComponent(".atoll/bin/atoll-hook") }

    private func configurationURL(for agent: AgentHarness) -> URL {
        switch agent {
        case .claude: homeDirectory.appendingPathComponent(".claude/settings.json")
        case .codex: homeDirectory.appendingPathComponent(".codex/hooks.json")
        case .gemini: homeDirectory.appendingPathComponent(".gemini/settings.json")
        case .copilot: homeDirectory.appendingPathComponent(".copilot/hooks/atoll.json")
        default: homeDirectory
        }
    }

    private func configurationDirectory(for agent: AgentHarness) -> URL? {
        configurationURL(for: agent).deletingLastPathComponent()
    }

    private func commandIsAvailable(_ command: String) -> Bool {
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        return paths.contains { fileManager.isExecutableFile(atPath: URL(fileURLWithPath: String($0)).appendingPathComponent(command).path) }
    }

    private func hasAllCommands(in root: [String: Any], for agent: AgentHarness) -> Bool {
        let commands: [(String, String)]
        switch agent {
        case .claude: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("SessionEnd", "finished")]
        case .codex: commands = [("UserPromptSubmit", "started"), ("Stop", "finished")]
        case .gemini: commands = [("BeforeAgent", "started"), ("AfterAgent", "finished"), ("SessionEnd", "finished")]
        case .copilot: commands = [("userPromptSubmitted", "started"), ("agentStop", "finished"), ("sessionEnd", "finished"), ("errorOccurred", "failed")]
        default: return false
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return commands.allSatisfy { event, kind in
            guard let entries = hooks[event] else { return false }
            return containsCommand(entries, command: hookCommand(harness: agent.rawValue, kind: kind))
        }
    }

    private func validateHookConfiguration(_ root: [String: Any], at url: URL) throws {
        guard let hooks = root["hooks"] else { return }
        guard let map = hooks as? [String: Any], map.values.allSatisfy({ $0 is [Any] }) else {
            throw Error.invalidHookConfiguration(url)
        }
    }

    private func writeBridge() throws {
        try fileManager.createDirectory(at: bridgeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        \(shellQuote(executablePath)) --lifecycle-event "$1" "$2" 2>/dev/null
        printf '{}\\n'
        exit 0
        """
        try script.write(to: bridgeURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridgeURL.path)
    }

    private func mergeClaudeHooks() throws {
        let url = homeDirectory.appendingPathComponent(".claude/settings.json")
        try mergeSettings(at: url) { hooks in
            try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "claude", kind: "started"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "claude", kind: "finished"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "SessionEnd", command: hookCommand(harness: "claude", kind: "finished"), matcher: nil)
        }
    }

    private func mergeCodexHooks() throws {
        let url = homeDirectory.appendingPathComponent(".codex/hooks.json")
        try mergeSettings(at: url) { hooks in
            try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "codex", kind: "started"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "codex", kind: "finished"), matcher: nil)
        }
    }

    private func mergeGeminiHooks() throws {
        let url = homeDirectory.appendingPathComponent(".gemini/settings.json")
        try mergeSettings(at: url) { hooks in
            try addGroupedCommand(to: &hooks, event: "BeforeAgent", command: hookCommand(harness: "gemini", kind: "started"), matcher: "*")
            try addGroupedCommand(to: &hooks, event: "AfterAgent", command: hookCommand(harness: "gemini", kind: "finished"), matcher: "*")
            try addGroupedCommand(to: &hooks, event: "SessionEnd", command: hookCommand(harness: "gemini", kind: "finished"), matcher: "*")
        }
    }

    private func mergeCopilotHooks() throws {
        let url = homeDirectory.appendingPathComponent(".copilot/hooks/atoll.json")
        var root = try jsonObject(at: url)
        let hooks = root["hooks"] ?? [String: Any]()
        guard var hookMap = hooks as? [String: Any] else { throw Error.invalidHookConfiguration(url) }

        try addCopilotCommand(to: &hookMap, event: "userPromptSubmitted", command: hookCommand(harness: "copilot", kind: "started"), url: url)
        try addCopilotCommand(to: &hookMap, event: "agentStop", command: hookCommand(harness: "copilot", kind: "finished"), url: url)
        try addCopilotCommand(to: &hookMap, event: "sessionEnd", command: hookCommand(harness: "copilot", kind: "finished"), url: url)
        try addCopilotCommand(to: &hookMap, event: "errorOccurred", command: hookCommand(harness: "copilot", kind: "failed"), url: url)
        root["version"] = root["version"] ?? 1
        root["hooks"] = hookMap
        try write(root, to: url)
    }

    private func mergeSettings(at url: URL, update: (inout [String: Any]) throws -> Void) throws {
        var root = try jsonObject(at: url)
        let value = root["hooks"] ?? [String: Any]()
        guard var hooks = value as? [String: Any] else { throw Error.invalidHookConfiguration(url) }
        try update(&hooks)
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { throw Error.invalidJSON(url) }
        return dictionary
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func addGroupedCommand(to hooks: inout [String: Any], event: String, command: String, matcher: String?) throws {
        let value = hooks[event] ?? []
        guard var entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        guard !containsCommand(entries, command: command) else { return }
        var hook: [String: Any] = ["type": "command", "command": command]
        if let matcher { hook["matcher"] = matcher }
        var entry: [String: Any] = ["hooks": [hook]]
        if let matcher { entry["matcher"] = matcher }
        entries.append(entry)
        hooks[event] = entries
    }

    private func addCopilotCommand(to hooks: inout [String: Any], event: String, command: String, url: URL) throws {
        let value = hooks[event] ?? []
        guard var entries = value as? [Any] else { throw Error.invalidHookConfiguration(url) }
        guard !containsCommand(entries, command: command) else { return }
        entries.append(["type": "command", "bash": command])
        hooks[event] = entries
    }

    private func containsCommand(_ object: Any, command: String) -> Bool {
        if let dictionary = object as? [String: Any] {
            if dictionary["command"] as? String == command || dictionary["bash"] as? String == command { return true }
            return dictionary.values.contains { containsCommand($0, command: command) }
        }
        return (object as? [Any])?.contains { containsCommand($0, command: command) } ?? false
    }

    private func hookCommand(harness: String, kind: String) -> String {
        "\(shellQuote(bridgeURL.path)) \(harness) \(kind)"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
