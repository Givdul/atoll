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
        .pi, .opencode, .cursor, .droid, .qoder, .qwen,
        .hermes, .amp
    ]
    public enum Error: Swift.Error, LocalizedError {
        case invalidJSON(URL)
        case invalidHookConfiguration(URL)
        case managedFileConflict(URL)
        case commandUnavailable(String)
        case commandFailed(String)
        case unsupportedPiVersion(installed: String, minimum: String)
        case unreadablePiVersion(minimum: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let url): "Cannot merge hooks because \(url.path) is not a JSON object."
            case .invalidHookConfiguration(let url): "Cannot merge hooks because \(url.path) has an invalid hooks configuration."
            case .managedFileConflict(let url): "Cannot install Atoll's managed integration because \(url.path) already belongs to another extension or plugin."
            case .commandUnavailable(let command): "Cannot finish setup because \(command) is not available."
            case .commandFailed(let detail): "Cannot finish setup: \(detail)"
            case .unsupportedPiVersion(let installed, let minimum): "Pi \(minimum) or newer is required for Live Status; found \(installed)."
            case .unreadablePiVersion(let minimum, let detail): "Pi \(minimum) or newer is required for Live Status, but Atoll could not verify it: \(detail)"
            }
        }
    }

    public let homeDirectory: URL
    public let executablePath: String
    private let fileManager: FileManager
    private let piVersionOutput: (() throws -> String)?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String = "/Applications/Atoll.app/Contents/MacOS/Atoll",
        fileManager: FileManager = .default,
        piVersionOutput: (() throws -> String)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
        self.piVersionOutput = piVersionOutput
    }

    public func install() throws {
        try install(agents: Self.supportedAgents)
    }

    public func install(agents: [AgentHarness]) throws {
        if agents.contains(.pi) { try requireSupportedPiVersion() }
        try writeBridge()
        for agent in agents {
            switch agent {
            case .codex: try mergeCodexHooks()
            case .claude: try mergeClaudeHooks()
            case .gemini: try mergeGeminiHooks()
            case .copilot: try mergeCopilotHooks()
            case .pi: try writePiExtension()
            case .opencode: try writeOpenCodePlugin()
            case .cursor: try mergeFlatHooks(
                at: configurationURL(for: .cursor),
                agent: .cursor,
                events: [("beforeSubmitPrompt", "started"), ("stop", "finished")],
                removing: [("sessionEnd", "finished")]
            )
            case .droid: try mergeSettings(at: configurationURL(for: .droid)) { hooks in
                try removeCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "droid", kind: "finished"))
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "droid", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "droid", kind: "finished"), matcher: nil)
            }
            case .qoder: try mergeSettings(at: configurationURL(for: .qoder)) { hooks in
                try removeCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "qoder", kind: "finished"))
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "qoder", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "qoder", kind: "finished"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "StopFailure", command: hookCommand(harness: "qoder", kind: "failed"), matcher: nil)
            }
            case .qwen: try mergeSettings(at: configurationURL(for: .qwen)) { hooks in
                try removeCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "qwen", kind: "finished"))
                try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "qwen", kind: "started"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "qwen", kind: "finished"), matcher: nil)
                try addGroupedCommand(to: &hooks, event: "StopFailure", command: hookCommand(harness: "qwen", kind: "failed"), matcher: nil)
            }
            case .hermes: try installHermesPlugins()
            case .amp: try writeAmpPlugin()
            default: break
            }
        }
    }

    public func detectedAgents() -> [AgentHarness] {
        Self.supportedAgents.filter { configurationDirectory(for: $0).map { fileManager.fileExists(atPath: $0.path) } == true || commandNames(for: $0).contains(where: commandIsAvailable) }
    }

    public func readiness(for agent: AgentHarness) -> Readiness {
        guard Self.supportedAgents.contains(agent) else { return .notConfigured }
        if agent == .pi {
            do {
                try requireSupportedPiVersion()
                return readiness(requiring: managedFileMatches(piExtensionSource, at: piExtensionURL))
            } catch {
                return .invalidConfiguration(error.localizedDescription)
            }
        }
        if agent == .opencode { return readiness(requiring: managedFileMatches(openCodePluginSource, at: openCodePluginURL)) }
        if agent == .hermes { return readiness(requiring: hermesPluginsAreReady()) }
        if agent == .amp { return readiness(requiring: managedFileMatches(ampPluginSource, at: ampPluginURL)) }
        do {
            let url = configurationURL(for: agent)
            let root = try jsonObject(at: url)
            try validateHookConfiguration(root, at: url)
            return readiness(requiring: hasAllCommands(in: root, for: agent))
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
        case .droid: homeDirectory.appendingPathComponent(".factory/hooks.json")
        case .qoder: homeDirectory.appendingPathComponent(".qoder/settings.json")
        case .qwen: homeDirectory.appendingPathComponent(".qwen/settings.json")
        case .pi: piExtensionURL
        case .opencode: openCodePluginURL
        case .hermes: homeDirectory.appendingPathComponent(".hermes/config.yaml")
        case .amp: ampPluginURL
        default: homeDirectory
        }
    }

    private func configurationDirectory(for agent: AgentHarness) -> URL? {
        if agent == .amp { return homeDirectory.appendingPathComponent(".config/amp") }
        return configurationURL(for: agent).deletingLastPathComponent()
    }

    private func commandIsAvailable(_ command: String) -> Bool {
        executableURL(named: command) != nil
    }

    private func commandNames(for agent: AgentHarness) -> [String] {
        switch agent {
        case .cursor: ["cursor-agent", "cursor"]
        case .droid: ["droid"]
        case .qwen: ["qwen", "qwen-code"]
        default: [agent.rawValue]
        }
    }

    private func hasAllCommands(in root: [String: Any], for agent: AgentHarness) -> Bool {
        let commands: [(String, String)]
        switch agent {
        case .claude: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("StopFailure", "failed")]
        case .codex: commands = [("UserPromptSubmit", "started"), ("Stop", "finished")]
        case .gemini: commands = [("BeforeAgent", "started"), ("AfterAgent", "finished")]
        case .copilot: commands = [("userPromptSubmitted", "started"), ("agentStop", "finished"), ("sessionEnd", "finished")]
        case .cursor: commands = [("beforeSubmitPrompt", "started"), ("stop", "finished")]
        case .droid: commands = [("UserPromptSubmit", "started"), ("Stop", "finished")]
        case .qoder, .qwen: commands = [("UserPromptSubmit", "started"), ("Stop", "finished"), ("StopFailure", "failed")]
        default: return false
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        guard commands.allSatisfy({ event, kind in
            guard let entries = hooks[event] else { return false }
            return containsCommand(entries, command: hookCommand(harness: agent.rawValue, kind: kind))
        }) else { return false }

        guard let cleanupEvent = legacyCleanupEvent(for: agent) else { return true }
        return !containsCommand(
            hooks[cleanupEvent],
            command: hookCommand(harness: agent.rawValue, kind: "finished")
        )
    }

    private func legacyCleanupEvent(for agent: AgentHarness) -> String? {
        switch agent {
        case .cursor: "sessionEnd"
        case .claude, .gemini, .droid, .qoder, .qwen: "SessionEnd"
        default: nil
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
        try bridgeSource.write(to: bridgeURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridgeURL.path)
    }

    private var piExtensionURL: URL { homeDirectory.appendingPathComponent(".pi/agent/extensions/atoll.ts") }
    private var openCodePluginURL: URL { homeDirectory.appendingPathComponent(".config/opencode/plugins/atoll.js") }
    private var ampPluginURL: URL { homeDirectory.appendingPathComponent(".config/amp/plugins/atoll.ts") }
    private var managedMarker: String { "Atoll Live Status managed integration" }
    private static let minimumPiVersion = PiVersion(major: 0, minor: 80, patch: 4, isPrerelease: false)

    private struct PiVersion: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int
        let isPrerelease: Bool

        var description: String { "\(major).\(minor).\(patch)\(isPrerelease ? "-prerelease" : "")" }

        static func < (lhs: PiVersion, rhs: PiVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            return lhs.isPrerelease && !rhs.isPrerelease
        }

        static func parse(_ output: String) -> PiVersion? {
            let pattern = #"(?<![0-9])([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: output,
                    range: NSRange(output.startIndex..., in: output)
                  ),
                  let majorRange = Range(match.range(at: 1), in: output),
                  let minorRange = Range(match.range(at: 2), in: output),
                  let patchRange = Range(match.range(at: 3), in: output),
                  let major = Int(output[majorRange]),
                  let minor = Int(output[minorRange]),
                  let patch = Int(output[patchRange]) else {
                return nil
            }
            return PiVersion(
                major: major,
                minor: minor,
                patch: patch,
                isPrerelease: match.range(at: 4).location != NSNotFound
            )
        }
    }

    private var bridgeSource: String {
        """
        #!/bin/sh
        \(shellQuote(executablePath)) --lifecycle-event "$1" "$2" 2>/dev/null
        printf '{}\\n'
        exit 0
        """
    }

    private var piExtensionSource: String {
        """
        // \(managedMarker)
        import { spawn } from "node:child_process";

        const bridge = \(javaScriptString(bridgeURL.path));
        function emit(kind, ctx) {
          const child = spawn(bridge, ["pi", kind], { stdio: ["pipe", "ignore", "ignore"] });
          child.stdin.end(JSON.stringify({ session_id: ctx.sessionManager.getSessionId(), cwd: ctx.sessionManager.getCwd() }));
        }

        export default function (pi) {
          pi.on("agent_start", (_event, ctx) => emit("started", ctx));
          pi.on("agent_settled", (_event, ctx) => emit("finished", ctx));
        }
        """
    }

    private var openCodePluginSource: String {
        """
        // \(managedMarker)
        const bridge = \(javaScriptString(bridgeURL.path));
        export const AtollLiveStatus = async ({ directory }) => {
          const terminalSessions = new Set();
          const emit = (kind, sessionID) => {
            const child = Bun.spawn([bridge, "opencode", kind], { stdin: JSON.stringify({ session_id: sessionID, cwd: directory }), stdout: "ignore", stderr: "ignore" });
            child.unref();
          };

          return {
            event: async ({ event }) => {
              if (event.type === "session.error") {
                const { sessionID, error } = event.properties;
                if (!sessionID) return;
                terminalSessions.add(sessionID);
                const errorName = error?.name ?? error?.data?.name;
                emit(errorName === "MessageAbortedError" ? "cancelled" : "failed", sessionID);
                return;
              }
              if (event.type !== "session.status") return;
              const { sessionID, status } = event.properties;
              if (status.type === "busy" || status.type === "retry") {
                terminalSessions.delete(sessionID);
                emit("started", sessionID);
              }
              if (status.type === "idle" && !terminalSessions.has(sessionID)) emit("finished", sessionID);
            },
          };
        };
        """
    }

    private var ampPluginSource: String {
        """
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
    }

    private var hermesManifestSource: String {
        """
        # \(managedMarker)
        name: atoll-live-status
        kind: standalone
        version: "1.0.0"
        description: Reports Hermes agent activity to Atoll Live Status
        provides_hooks:
          - pre_llm_call
          - on_session_end
        """
    }

    private var hermesPluginSource: String {
        """
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
    }

    private struct HermesProfile {
        let name: String
        let home: URL
    }

    private func mergeFlatHooks(
        at url: URL,
        agent: AgentHarness,
        events: [(String, String)],
        removing removedEvents: [(String, String)] = []
    ) throws {
        var root = try jsonObject(at: url)
        let value = root["hooks"] ?? [String: Any]()
        guard var hooks = value as? [String: Any] else { throw Error.invalidHookConfiguration(url) }
        for (event, kind) in removedEvents {
            try removeCommand(from: &hooks, event: event, command: hookCommand(harness: agent.rawValue, kind: kind))
        }
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
        try writeManagedFile(piExtensionSource, to: piExtensionURL)
    }

    private func writeOpenCodePlugin() throws {
        try writeManagedFile(openCodePluginSource, to: openCodePluginURL)
    }

    private func writeAmpPlugin() throws {
        try writeManagedFile(ampPluginSource, to: ampPluginURL)
    }

    private func installHermesPlugins() throws {
        let profiles = hermesProfiles()
        for profile in profiles {
            let directory = profile.home.appendingPathComponent("plugins/atoll-live-status")
            try writeManagedFile(hermesManifestSource, to: directory.appendingPathComponent("plugin.yaml"))
            try writeManagedFile(hermesPluginSource, to: directory.appendingPathComponent("__init__.py"))

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
            return managedFileMatches(hermesManifestSource, at: directory.appendingPathComponent("plugin.yaml"))
                && managedFileMatches(hermesPluginSource, at: directory.appendingPathComponent("__init__.py"))
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

    private func requireSupportedPiVersion() throws {
        let minimum = Self.minimumPiVersion
        let output: String
        do {
            output = try installedPiVersionOutput(minimum: minimum.description)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.unreadablePiVersion(minimum: minimum.description, detail: error.localizedDescription)
        }

        guard let installed = PiVersion.parse(output) else {
            let reported = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reported.isEmpty ? "`pi --version` returned no version." : "`pi --version` returned \(reported.debugDescription)."
            throw Error.unreadablePiVersion(minimum: minimum.description, detail: detail)
        }
        guard installed >= minimum else {
            throw Error.unsupportedPiVersion(installed: installed.description, minimum: minimum.description)
        }
    }

    private func installedPiVersionOutput(minimum: String) throws -> String {
        if let piVersionOutput { return try piVersionOutput() }
        guard let executable = executableURL(named: "pi") else {
            throw Error.unreadablePiVersion(minimum: minimum, detail: "`pi` was not found on the executable search path.")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw Error.unreadablePiVersion(minimum: minimum, detail: "`pi --version` could not run: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.unreadablePiVersion(
                minimum: minimum,
                detail: detail.isEmpty ? "`pi --version` exited with status \(process.terminationStatus)." : "`pi --version` failed: \(detail)"
            )
        }
        return text
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

    private func readiness(requiring integrationIsCurrent: Bool) -> Readiness {
        integrationIsCurrent && bridgeIsReady ? .configured : .notConfigured
    }

    private var bridgeIsReady: Bool {
        guard managedFileMatches(bridgeSource, at: bridgeURL),
              let attributes = try? fileManager.attributesOfItem(atPath: bridgeURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue == 0o700
    }

    private func managedFileMatches(_ expected: String, at url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents == expected
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

    private func mergeClaudeHooks() throws {
        let url = homeDirectory.appendingPathComponent(".claude/settings.json")
        try mergeSettings(at: url) { hooks in
            try removeCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "claude", kind: "finished"))
            try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "claude", kind: "started"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "claude", kind: "finished"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "StopFailure", command: hookCommand(harness: "claude", kind: "failed"), matcher: nil)
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
            try removeCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "gemini", kind: "finished"))
            try addGroupedCommand(to: &hooks, event: "BeforeAgent", command: hookCommand(harness: "gemini", kind: "started"), matcher: "*")
            try addGroupedCommand(to: &hooks, event: "AfterAgent", command: hookCommand(harness: "gemini", kind: "finished"), matcher: "*")
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

    private func removeCommand(from hooks: inout [String: Any], event: String, command: String) throws {
        guard let value = hooks[event] else { return }
        guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        let remaining = entries.compactMap { removingCommand($0, matching: command) }
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
    }

    private func removingCommand(_ object: Any, matching command: String) -> Any? {
        if var dictionary = object as? [String: Any] {
            if dictionary["command"] as? String == command || dictionary["bash"] as? String == command {
                return nil
            }
            let hadNestedHooks = dictionary["hooks"] is [Any]
            for key in Array(dictionary.keys) {
                guard let currentValue = dictionary[key] else { continue }
                if let value = removingCommand(currentValue, matching: command) {
                    dictionary[key] = value
                } else {
                    dictionary.removeValue(forKey: key)
                }
            }
            if hadNestedHooks, (dictionary["hooks"] as? [Any])?.isEmpty != false { return nil }
            return dictionary
        }
        if let array = object as? [Any] {
            return array.compactMap { removingCommand($0, matching: command) }
        }
        return object
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
