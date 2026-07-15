import Foundation

/// Installs the small native-hook bridge. Call this only from an explicit user action.
public struct LifecycleHookInstaller {
    public enum Readiness: Equatable {
        case notConfigured
        case configured
        case invalidConfiguration(String)
    }

    public static let supportedAgents: [AgentHarness] = [
        .codex, .claude, .gemini, .copilot,
        .pi, .opencode, .cursor, .droid, .qoder, .qwen, .kimi, .kiro,
        .hermes, .amp, .codebuddy
    ]
    public enum Error: Swift.Error, LocalizedError {
        case invalidJSON(URL)
        case invalidHookConfiguration(URL)
        case managedFileConflict(URL)
        case noKiroAgentConfigurations(URL)
        case commandUnavailable(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let url): "Cannot merge hooks because \(url.path) is not a JSON object."
            case .invalidHookConfiguration(let url): "Cannot merge hooks because \(url.path) has an invalid hooks configuration."
            case .managedFileConflict(let url): "Cannot install Atoll's managed integration because \(url.path) already belongs to another extension or plugin."
            case .noKiroAgentConfigurations(let url): "Create a Kiro CLI custom agent in \(url.path) first, then run Live Status Setup again."
            case .commandUnavailable(let command): "Cannot finish setup because \(command) is not available."
            case .commandFailed(let detail): "Cannot finish setup: \(detail)"
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
            case .pi: try writePiExtension()
            case .opencode: try writeOpenCodePlugin()
            case .cursor: try mergeFlatHooks(at: configurationURL(for: .cursor), agent: .cursor, events: [("sessionStart", "started"), ("stop", "finished"), ("sessionEnd", "finished")])
            case .droid: try mergeSettings(at: configurationURL(for: .droid)) { hooks in
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "droid", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "droid", kind: "finished"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "SessionEnd", command: hookCommand(harness: "droid", kind: "finished"), matcher: nil)
            }
            case .qoder: try mergeSettings(at: configurationURL(for: .qoder)) { hooks in
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "qoder", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "qoder", kind: "finished"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "SessionEnd", command: hookCommand(harness: "qoder", kind: "finished"), matcher: nil)
            }
            case .qwen: try mergeSettings(at: configurationURL(for: .qwen)) { hooks in
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "qwen", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "qwen", kind: "finished"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "SessionEnd", command: hookCommand(harness: "qwen", kind: "finished"), matcher: nil)
            }
            case .kimi: try mergeKimiHooks()
            case .kiro: try mergeKiroHooks()
            case .hermes: try installHermesPlugins()
            case .amp: try writeAmpPlugin()
            case .codebuddy: try mergeCodeBuddyHooks()
            default: break
            }
        }
    }

    public func detectedAgents() -> [AgentHarness] {
        Self.supportedAgents.filter { configurationDirectory(for: $0).map { fileManager.fileExists(atPath: $0.path) } == true || commandNames(for: $0).contains(where: commandIsAvailable) }
    }

    public func readiness(for agent: AgentHarness) -> Readiness {
        guard Self.supportedAgents.contains(agent) else { return .notConfigured }
        if agent == .pi { return managedFileIsPresent(piExtensionURL) ? .configured : .notConfigured }
        if agent == .opencode { return managedFileIsPresent(openCodePluginURL) ? .configured : .notConfigured }
        if agent == .kimi { return kimiHooksArePresent() ? .configured : .notConfigured }
        if agent == .kiro { return kiroHooksArePresent() ? .configured : .notConfigured }
        if agent == .hermes { return hermesPluginsAreReady() ? .configured : .notConfigured }
        if agent == .amp { return managedFileIsPresent(ampPluginURL) ? .configured : .notConfigured }
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
        case .cursor: homeDirectory.appendingPathComponent(".cursor/hooks.json")
        case .droid: homeDirectory.appendingPathComponent(".factory/settings.json")
        case .qoder: homeDirectory.appendingPathComponent(".qoder/settings.json")
        case .qwen: homeDirectory.appendingPathComponent(".qwen/settings.json")
        case .kimi: homeDirectory.appendingPathComponent(".kimi-code/config.toml")
        case .pi: piExtensionURL
        case .opencode: openCodePluginURL
        case .kiro: homeDirectory.appendingPathComponent(".kiro/agents")
        case .hermes: homeDirectory.appendingPathComponent(".hermes/config.yaml")
        case .amp: ampPluginURL
        case .codebuddy: homeDirectory.appendingPathComponent(".codebuddy/settings.json")
        default: homeDirectory
        }
    }

    private func configurationDirectory(for agent: AgentHarness) -> URL? {
        if agent == .kiro { return configurationURL(for: agent) }
        if agent == .amp { return homeDirectory.appendingPathComponent(".config/amp") }
        return configurationURL(for: agent).deletingLastPathComponent()
    }

    private func commandIsAvailable(_ command: String) -> Bool {
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        return paths.contains { fileManager.isExecutableFile(atPath: URL(fileURLWithPath: String($0)).appendingPathComponent(command).path) }
    }

    private func commandNames(for agent: AgentHarness) -> [String] {
        switch agent {
        case .cursor: ["cursor-agent", "cursor"]
        case .droid: ["droid"]
        case .qwen: ["qwen", "qwen-code"]
        case .kimi: ["kimi", "kimi-code"]
        case .kiro: ["kiro-cli", "kiro"]
        case .codebuddy: ["codebuddy"]
        default: [agent.rawValue]
        }
    }

    private func readinessCommand(agent: AgentHarness, kind: String) -> String {
        let command = hookCommand(harness: agent.rawValue, kind: kind)
        return agent == .codebuddy ? "\(command) >/dev/null 2>&1" : command
    }

    private func hasAllCommands(in root: [String: Any], for agent: AgentHarness) -> Bool {
        let commands: [(String, String)]
        switch agent {
        case .claude: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("SessionEnd", "finished")]
        case .codex: commands = [("UserPromptSubmit", "started"), ("Stop", "finished")]
        case .gemini: commands = [("BeforeAgent", "started"), ("AfterAgent", "finished"), ("SessionEnd", "finished")]
        case .copilot: commands = [("userPromptSubmitted", "started"), ("agentStop", "finished"), ("sessionEnd", "finished"), ("errorOccurred", "failed")]
        case .cursor: commands = [("sessionStart", "started"), ("stop", "finished"), ("sessionEnd", "finished")]
        case .droid, .qoder, .qwen: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("SessionEnd", "finished")]
        case .codebuddy: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("StopFailure", "failed"), ("SessionEnd", "finished")]
        default: return false
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return commands.allSatisfy { event, kind in
            guard let entries = hooks[event] else { return false }
            return containsCommand(entries, command: readinessCommand(agent: agent, kind: kind))
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

    private var piExtensionURL: URL { homeDirectory.appendingPathComponent(".pi/agent/extensions/atoll.ts") }
    private var openCodePluginURL: URL { homeDirectory.appendingPathComponent(".config/opencode/plugin/atoll.js") }
    private var ampPluginURL: URL { homeDirectory.appendingPathComponent(".config/amp/plugins/atoll.ts") }
    private var managedMarker: String { "Atoll Live Status managed integration" }

    private struct HermesProfile {
        let name: String
        let home: URL
    }

    private func mergeFlatHooks(at url: URL, agent: AgentHarness, events: [(String, String)]) throws {
        var root = try jsonObject(at: url)
        let value = root["hooks"] ?? [String: Any]()
        guard var hooks = value as? [String: Any] else { throw Error.invalidHookConfiguration(url) }
        for (event, kind) in events {
            let command = hookCommand(harness: agent.rawValue, kind: kind)
            let value = hooks[event] ?? []
            guard var entries = value as? [Any] else { throw Error.invalidHookConfiguration(url) }
            if !containsCommand(entries, command: command) {
                entries.append(["command": command])
                hooks[event] = entries
            }
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private func writePiExtension() throws {
        let source = """
        // \(managedMarker)
        import { spawn } from "node:child_process";

        const bridge = \(javaScriptString(bridgeURL.path));
        function emit(kind, ctx) {
          const child = spawn(bridge, ["pi", kind], { stdio: ["pipe", "ignore", "ignore"] });
          child.stdin.end(JSON.stringify({ session_id: ctx.sessionManager.getSessionId(), cwd: process.cwd() }));
        }

        export default function (pi) {
          pi.on("agent_start", (_event, ctx) => emit("started", ctx));
          pi.on("agent_settled", (_event, ctx) => emit("finished", ctx));
        }
        """
        try writeManagedFile(source, to: piExtensionURL)
    }

    private func writeOpenCodePlugin() throws {
        let source = """
        // \(managedMarker)
        const bridge = \(javaScriptString(bridgeURL.path));
        const emit = (kind, sessionID) => {
          const child = Bun.spawn([bridge, "opencode", kind], { stdin: JSON.stringify({ session_id: sessionID, cwd: process.cwd() }), stdout: "ignore", stderr: "ignore" });
          child.unref();
        };

        export const AtollLiveStatus = async () => ({
          event: async ({ event }) => {
            if (event.type !== "session.status") return;
            const { sessionID, status } = event.properties;
            if (status.type === "busy") emit("started", sessionID);
            if (status.type === "idle") emit("finished", sessionID);
          },
        });
        """
        try writeManagedFile(source, to: openCodePluginURL)
    }

    private func writeAmpPlugin() throws {
        let source = """
        // \(managedMarker)
        import { spawn } from "node:child_process";

        const bridge = \(javaScriptString(bridgeURL.path));
        function emit(kind, event) {
          const child = spawn(bridge, ["amp", kind], { stdio: ["pipe", "ignore", "ignore"] });
          child.stdin.end(JSON.stringify({ session_id: event.thread.id, cwd: process.cwd(), prompt: event.message }));
        }

        export default function (amp) {
          amp.on("agent.start", event => emit("started", event));
          amp.on("agent.end", event => {
            const kind = event.status === "done" ? "finished" : event.status === "error" ? "failed" : "cancelled";
            emit(kind, event);
          });
        }
        """
        try writeManagedFile(source, to: ampPluginURL)
    }

    private func mergeCodeBuddyHooks() throws {
        let url = configurationURL(for: .codebuddy)
        try mergeSettings(at: url) { hooks in
            for (event, kind) in [("UserPromptSubmit", "started"), ("Stop", "finished"), ("StopFailure", "failed"), ("SessionEnd", "finished")] {
                try addGroupedCommand(
                    to: &hooks,
                    event: event,
                    command: readinessCommand(agent: .codebuddy, kind: kind),
                    matcher: nil
                )
            }
        }
    }

    private func installHermesPlugins() throws {
        let profiles = hermesProfiles()
        for profile in profiles {
            let directory = profile.home.appendingPathComponent("plugins/atoll-live-status")
            let manifest = """
            # \(managedMarker)
            name: atoll-live-status
            kind: standalone
            version: "1.0.0"
            description: Reports Hermes agent activity to Atoll Live Status
            provides_hooks:
              - pre_llm_call
              - on_session_end
            """
            let plugin = """
            # \(managedMarker)
            import json
            import os
            import subprocess

            BRIDGE = \(javaScriptString(bridgeURL.path))

            def _emit(kind, *, session_id, prompt="", model="", platform=""):
                if not session_id:
                    return
                payload = {
                    "session_id": session_id,
                    "cwd": os.environ.get("TERMINAL_CWD") or os.getcwd(),
                    "prompt": prompt,
                    "model": model,
                    "platform": platform,
                }
                try:
                    subprocess.run(
                        [BRIDGE, "hermes", kind],
                        input=json.dumps(payload).encode("utf-8"),
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=2,
                        check=False,
                    )
                except (OSError, subprocess.SubprocessError):
                    pass

            def _on_turn_start(session_id="", user_message="", model="", platform="", **kwargs):
                _emit("started", session_id=session_id, prompt=user_message, model=model, platform=platform)

            def _on_turn_end(session_id="", completed=False, interrupted=False, model="", platform="", **kwargs):
                kind = "cancelled" if interrupted else "finished" if completed else "failed"
                _emit(kind, session_id=session_id, model=model, platform=platform)

            def register(ctx):
                ctx.register_hook("pre_llm_call", _on_turn_start)
                ctx.register_hook("on_session_end", _on_turn_end)
            """
            try writeManagedFile(manifest, to: directory.appendingPathComponent("plugin.yaml"))
            try writeManagedFile(plugin, to: directory.appendingPathComponent("__init__.py"))

            guard !hermesPluginEnabled(in: profile) else { continue }
            try enableHermesPlugin(profile: profile)
        }
    }

    private func hermesProfiles() -> [HermesProfile] {
        let root = homeDirectory.appendingPathComponent(".hermes")
        var profiles = [HermesProfile(name: "default", home: root)]
        let profilesRoot = root.appendingPathComponent("profiles")
        let urls = (try? fileManager.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        profiles += urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { HermesProfile(name: $0.lastPathComponent, home: $0) }
        return profiles
    }

    private func hermesPluginEnabled(in profile: HermesProfile) -> Bool {
        let url = profile.home.appendingPathComponent("config.yaml")
        guard let config = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return yamlList(config, section: "plugins", key: "enabled", contains: "atoll-live-status")
            && !yamlList(config, section: "plugins", key: "disabled", contains: "atoll-live-status")
    }

    private func hermesPluginsAreReady() -> Bool {
        hermesProfiles().allSatisfy { profile in
            let directory = profile.home.appendingPathComponent("plugins/atoll-live-status")
            return managedFileIsPresent(directory.appendingPathComponent("plugin.yaml"))
                && managedFileIsPresent(directory.appendingPathComponent("__init__.py"))
                && hermesPluginEnabled(in: profile)
        }
    }

    private func enableHermesPlugin(profile: HermesProfile) throws {
        guard let executable = executableURL(named: "hermes") else { throw Error.commandUnavailable("hermes") }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-p", profile.name, "plugins", "enable", "atoll-live-status"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.commandFailed(detail?.isEmpty == false ? detail! : "Hermes could not enable the Atoll plugin for profile \(profile.name).")
        }
    }

    private func executableURL(named command: String) -> URL? {
        var directories = (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        directories += [homeDirectory.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func yamlList(_ source: String, section: String, key: String, contains value: String) -> Bool {
        var inSection = false
        var inList = false
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inSection = trimmed == "\(section):"
                inList = false
                continue
            }
            guard inSection else { continue }
            if indent == 2 {
                inList = false
                guard trimmed.hasPrefix("\(key):") else { continue }
                let inline = String(trimmed.dropFirst(key.count + 1))
                if inline.split(whereSeparator: { "[], ".contains($0) }).contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'") ) == value }) {
                    return true
                }
                inList = inline.trimmingCharacters(in: .whitespaces).isEmpty
                continue
            }
            if inList && indent >= 4 && trimmed.hasPrefix("-") {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if item == value { return true }
            }
        }
        return false
    }

    private func mergeKimiHooks() throws {
        let url = configurationURL(for: .kimi)
        let existing = fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        guard !existing.contains(managedMarker) else { return }
        let commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("SessionEnd", "finished")]
        let rules = commands.map { event, kind in
            """
            [[hooks]]
            event = "\(event)"
            command = \(tomlString(hookCommand(harness: "kimi", kind: kind)))
            """
        }.joined(separator: "\n\n")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + "\n# \(managedMarker)\n\(rules)\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func mergeKiroHooks() throws {
        let directory = configurationURL(for: .kiro)
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        guard !urls.isEmpty else { throw Error.noKiroAgentConfigurations(directory) }
        for url in urls {
            try mergeFlatHooks(at: url, agent: .kiro, events: [("agentSpawn", "started"), ("stop", "finished")])
        }
    }

    private func managedFileIsPresent(_ url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains(managedMarker)
    }

    private func kimiHooksArePresent() -> Bool {
        let url = configurationURL(for: .kimi)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains(managedMarker)
    }

    private func kiroHooksArePresent() -> Bool {
        let directory = configurationURL(for: .kiro)
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        return !urls.isEmpty && urls.allSatisfy { url in
            guard let root = try? jsonObject(at: url), let hooks = root["hooks"] as? [String: Any] else { return false }
            return containsCommand(hooks["agentSpawn"], command: hookCommand(harness: "kiro", kind: "started"))
                && containsCommand(hooks["stop"], command: hookCommand(harness: "kiro", kind: "finished"))
        }
    }

    private func writeManagedFile(_ source: String, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            let firstLine = existing.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            guard firstLine?.contains(managedMarker) == true else { throw Error.managedFileConflict(url) }
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    private func javaScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\\\""))\""
    }

    private func tomlString(_ value: String) -> String { javaScriptString(value) }

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

    private func containsCommand(_ object: Any?, command: String) -> Bool {
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
