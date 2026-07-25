import Darwin
import Foundation

/// Installs the small native-hook bridge. Call this only from an explicit user action.
public struct LifecycleHookInstaller {
    public enum Readiness: Equatable {
        case notConfigured
        case configured
        case invalidConfiguration(String)
    }

    public static let supportedAgents: [AgentHarness] = [
        .codex, .claude, .cursor, .opencode, .pi
    ]
    public enum Error: Swift.Error, LocalizedError {
        case invalidJSON(URL)
        case invalidHookConfiguration(URL)
        case hooksDisabled(URL, setting: String)
        case managedFileConflict(URL)
        case commandFailed(String)
        case unsupportedPiVersion(installed: String, minimum: String)
        case unreadablePiVersion(minimum: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let url): "Cannot merge hooks because \(url.path) is not a JSON object."
            case .invalidHookConfiguration(let url): "Cannot merge hooks because \(url.path) has an invalid hooks configuration."
            case .hooksDisabled(let url, let setting): "Live Status hooks are disabled by \(setting) in \(url.path)."
            case .managedFileConflict(let url): "Cannot install Atoll's managed integration because \(url.path) already belongs to another extension or plugin."
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
    private let environment: [String: String]
    private let commandTimeout: TimeInterval

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String = "/Applications/Atoll.app/Contents/MacOS/Atoll",
        fileManager: FileManager = .default,
        piVersionOutput: (() throws -> String)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandTimeout: TimeInterval = 10
    ) {
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
        self.piVersionOutput = piVersionOutput
        self.environment = environment
        self.commandTimeout = max(0.01, commandTimeout)
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
            case .pi: try writePiExtension()
            case .opencode: try writeOpenCodePlugin()
            case .cursor: try mergeFlatHooks(
                at: configurationURL(for: .cursor),
                agent: .cursor,
                events: [("beforeSubmitPrompt", "started"), ("stop", "finished")],
                removing: [("sessionStart", "started"), ("sessionEnd", "finished")]
            )
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
        if agent == .opencode {
            return readiness(requiring:
                managedFileMatches(openCodePluginSource, at: openCodePluginURL)
                    && !fileManager.fileExists(atPath: legacyOpenCodePluginURL.path)
            )
        }
        do {
            if agent == .codex { try validateCodexHooksEnabled() }
            let url = configurationURL(for: agent)
            let root = try jsonObject(at: url)
            try validateHookConfiguration(root, for: agent, at: url)
            return readiness(requiring: hasAllCommands(in: root, for: agent))
        } catch {
            return .invalidConfiguration(error.localizedDescription)
        }
    }

    private var bridgeURL: URL { homeDirectory.appendingPathComponent(".atoll/bin/atoll-hook") }

    private func configurationURL(for agent: AgentHarness) -> URL {
        switch agent {
        case .claude: claudeConfigurationDirectory.appendingPathComponent("settings.json")
        case .codex: codexConfigurationDirectory.appendingPathComponent("hooks.json")
        case .cursor: homeDirectory.appendingPathComponent(".cursor/hooks.json")
        case .pi: piExtensionURL
        case .opencode: openCodePluginURL
        default: homeDirectory
        }
    }

    private func configurationDirectory(for agent: AgentHarness) -> URL? {
        if agent == .pi { return piConfigurationDirectory }
        if agent == .opencode { return openCodeConfigurationDirectory }
        return configurationURL(for: agent).deletingLastPathComponent()
    }

    private var claudeConfigurationDirectory: URL {
        customDirectory(environmentVariable: "CLAUDE_CONFIG_DIR")
            ?? homeDirectory.appendingPathComponent(".claude")
    }

    private var codexConfigurationDirectory: URL {
        customDirectory(environmentVariable: "CODEX_HOME")
            ?? homeDirectory.appendingPathComponent(".codex")
    }

    private var piConfigurationDirectory: URL {
        customDirectory(environmentVariable: "PI_CODING_AGENT_DIR")
            ?? homeDirectory.appendingPathComponent(".pi/agent")
    }

    private var openCodeConfigurationDirectory: URL {
        customDirectory(environmentVariable: "OPENCODE_CONFIG_DIR")
            ?? homeDirectory.appendingPathComponent(".config/opencode")
    }

    private func customDirectory(environmentVariable name: String) -> URL? {
        guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw == "~" { return homeDirectory }
        if raw.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(raw.dropFirst(2)))
        }
        guard raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func commandIsAvailable(_ command: String) -> Bool {
        executableURL(named: command) != nil
    }

    private func commandNames(for agent: AgentHarness) -> [String] {
        switch agent {
        case .cursor: ["cursor-agent", "cursor"]
        default: [agent.rawValue]
        }
    }

    private struct HookRequirement {
        let event: String
        let kind: String
        let matcher: String?

        init(_ event: String, _ kind: String, matcher: String? = nil) {
            self.event = event
            self.kind = kind
            self.matcher = matcher
        }
    }

    private func requiredHooks(for agent: AgentHarness) -> [HookRequirement] {
        switch agent {
        case .claude:
            [
                HookRequirement("UserPromptSubmit", "started"),
                HookRequirement("Stop", "finished"),
                HookRequirement("StopFailure", "failed"),
                HookRequirement("Notification", "needsPermission", matcher: "permission_prompt"),
                HookRequirement("Notification", "needsInput", matcher: "elicitation_dialog"),
                HookRequirement("Notification", "needsInput", matcher: "agent_needs_input"),
                HookRequirement("Notification", "started", matcher: "elicitation_complete"),
                HookRequirement("Notification", "started", matcher: "elicitation_response"),
                HookRequirement("PostToolUse", "started", matcher: "*"),
                HookRequirement("PostToolUseFailure", "started", matcher: "*"),
                HookRequirement("PermissionDenied", "started", matcher: "*")
            ]
        case .codex:
            [HookRequirement("UserPromptSubmit", "started"), HookRequirement("Stop", "finished")]
        case .cursor:
            [HookRequirement("beforeSubmitPrompt", "started"), HookRequirement("stop", "finished")]
        default:
            []
        }
    }

    private func hasAllCommands(in root: [String: Any], for agent: AgentHarness) -> Bool {
        let requirements = requiredHooks(for: agent)
        guard !requirements.isEmpty else { return false }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        let hasRequiredHooks = requirements.allSatisfy { requirement in
            let command = hookCommand(harness: agent.rawValue, kind: requirement.kind)
            switch agent {
            case .cursor:
                return containsFlatCommand(hooks[requirement.event], command: command)
            default:
                return containsGroupedCommand(
                    hooks[requirement.event],
                    command: command,
                    matcher: requirement.matcher
                )
            }
        }
        guard hasRequiredHooks else { return false }

        if let cleanupEvent = legacyCleanupEvent(for: agent) {
            let command = hookCommand(harness: agent.rawValue, kind: "finished")
            let containsCleanup = agent == .cursor
                ? containsFlatCommand(hooks[cleanupEvent], command: command)
                : containsGroupedCommand(hooks[cleanupEvent], command: command, matcher: nil, matchingAnyMatcher: true)
            if containsCleanup { return false }
        }

        if agent == .cursor {
            return !containsFlatCommand(
                hooks["sessionStart"],
                command: hookCommand(harness: "cursor", kind: "started")
            )
        }
        return true
    }

    private func legacyCleanupEvent(for agent: AgentHarness) -> String? {
        switch agent {
        case .cursor: "sessionEnd"
        case .claude: "SessionEnd"
        default: nil
        }
    }

    private func validateHookConfiguration(_ root: [String: Any], for agent: AgentHarness, at url: URL) throws {
        if agent == .claude, root["disableAllHooks"] != nil {
            guard let disabled = root["disableAllHooks"] as? Bool else {
                throw Error.invalidHookConfiguration(url)
            }
            if disabled { throw Error.hooksDisabled(url, setting: "disableAllHooks") }
        }
        if agent == .cursor, let version = root["version"], version as? Int != 1 {
            throw Error.invalidHookConfiguration(url)
        }
        guard let hooks = root["hooks"] else { return }
        guard let map = hooks as? [String: Any] else {
            throw Error.invalidHookConfiguration(url)
        }
        for value in map.values {
            guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(url) }
            let valid: Bool
            switch agent {
            case .cursor:
                valid = entries.allSatisfy(isValidFlatHook)
            default:
                valid = entries.allSatisfy(isValidGroupedHook)
            }
            guard valid else { throw Error.invalidHookConfiguration(url) }
        }
    }

    private func writeBridge() throws {
        try fileManager.createDirectory(at: bridgeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bridgeSource.write(to: bridgeURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridgeURL.path)
    }

    private var piExtensionURL: URL { piConfigurationDirectory.appendingPathComponent("extensions/atoll.ts") }
    private var openCodePluginURL: URL { openCodeConfigurationDirectory.appendingPathComponent("plugins/atoll.js") }
    private var legacyOpenCodePluginURL: URL { openCodeConfigurationDirectory.appendingPathComponent("plugin/atoll.js") }
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
          try {
            const child = spawn(bridge, ["pi", kind], { stdio: ["pipe", "ignore", "ignore"] });
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ session_id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd }));
          } catch {}
        }

        export default function (pi) {
          let outcome = "finished";
          pi.on("agent_start", (_event, ctx) => {
            outcome = "finished";
            emit("started", ctx);
          });
          pi.on("agent_end", event => {
            const stopReason = event.messages.findLast(message => message.role === "assistant")?.stopReason;
            if (stopReason === "error" || stopReason === "length") outcome = "failed";
            else if (stopReason === "aborted") outcome = "cancelled";
            else outcome = "finished";
          });
          pi.on("agent_settled", (_event, ctx) => emit(outcome, ctx));
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
            try {
              const child = Bun.spawn([bridge, "opencode", kind], { stdin: "pipe", stdout: "ignore", stderr: "ignore" });
              child.stdin.write(JSON.stringify({ session_id: sessionID, cwd: directory }));
              child.stdin.end();
              child.exited.catch(() => {});
              child.unref();
            } catch {}
          };
          const finish = sessionID => {
            if (!sessionID || terminalSessions.has(sessionID)) return;
            terminalSessions.add(sessionID);
            emit("finished", sessionID);
          };

          return {
            event: async ({ event }) => {
              const sessionID = event.properties?.sessionID ?? event.properties?.session_id;
              if (event.type === "permission.asked" || event.type === "permission.updated") {
                if (sessionID && !terminalSessions.has(sessionID)) emit("needsPermission", sessionID);
                return;
              }
              if (event.type === "permission.replied") {
                if (sessionID && !terminalSessions.has(sessionID)) emit("started", sessionID);
                return;
              }
              if (event.type === "question.asked") {
                if (sessionID && !terminalSessions.has(sessionID)) emit("needsInput", sessionID);
                return;
              }
              if (event.type === "question.replied" || event.type === "question.rejected") {
                if (sessionID && !terminalSessions.has(sessionID)) emit("started", sessionID);
                return;
              }
              if (event.type === "session.error") {
                const { error } = event.properties;
                if (!sessionID) return;
                terminalSessions.add(sessionID);
                const errorName = error?.name ?? error?.data?.name;
                emit(errorName === "MessageAbortedError" ? "cancelled" : "failed", sessionID);
                return;
              }
              if (event.type === "session.idle") {
                finish(sessionID);
                return;
              }
              if (event.type !== "session.status") return;
              const { status } = event.properties;
              if (!sessionID) return;
              if (status.type === "busy" || status.type === "retry") {
                terminalSessions.delete(sessionID);
                emit("started", sessionID);
              }
              if (status.type === "idle") finish(sessionID);
            },
          };
        };
        """
    }

    private struct CommandResult {
        let terminationStatus: Int32
        let output: String
    }

    private enum CommandExecutionError: Swift.Error {
        case timedOut(output: String)
    }

    private func mergeFlatHooks(
        at url: URL,
        agent: AgentHarness,
        events: [(String, String)],
        removing removedEvents: [(String, String)] = []
    ) throws {
        var root = try jsonObject(at: url)
        try validateHookConfiguration(root, for: agent, at: url)
        let value = root["hooks"] ?? [String: Any]()
        guard var hooks = value as? [String: Any] else { throw Error.invalidHookConfiguration(url) }
        for (event, kind) in removedEvents {
            try removeFlatCommand(from: &hooks, event: event, command: hookCommand(harness: agent.rawValue, kind: kind))
        }
        for (event, kind) in events {
            let command = hookCommand(harness: agent.rawValue, kind: kind)
            let value = hooks[event] ?? []
            guard var entries = value as? [Any] else { throw Error.invalidHookConfiguration(url) }
            if !containsFlatCommand(entries, command: command) {
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
        if fileManager.fileExists(atPath: legacyOpenCodePluginURL.path) {
            let existing = try String(contentsOf: legacyOpenCodePluginURL, encoding: .utf8)
            let firstLine = existing.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            guard firstLine?.contains(managedMarker) == true else {
                throw Error.managedFileConflict(legacyOpenCodePluginURL)
            }
        }
        try writeManagedFile(openCodePluginSource, to: openCodePluginURL)
        if fileManager.fileExists(atPath: legacyOpenCodePluginURL.path) {
            try fileManager.removeItem(at: legacyOpenCodePluginURL)
        }
    }

    private func executableURL(named command: String) -> URL? {
        let searchPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
        var directories = (searchPath?.split(separator: ":").map(String.init) ?? [])
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

        let result: CommandResult
        do {
            result = try runCommand(executable: executable, arguments: ["--version"])
        } catch CommandExecutionError.timedOut(let output) {
            throw Error.unreadablePiVersion(
                minimum: minimum,
                detail: commandTimeoutDetail(
                    command: "pi --version",
                    output: output,
                    fallback: "`pi --version` did not finish."
                )
            )
        } catch {
            throw Error.unreadablePiVersion(minimum: minimum, detail: "`pi --version` could not run: \(error.localizedDescription)")
        }
        guard result.terminationStatus == 0 else {
            let detail = diagnosticOutput(result.output)
            throw Error.unreadablePiVersion(
                minimum: minimum,
                detail: detail.isEmpty ? "`pi --version` exited with status \(result.terminationStatus)." : "`pi --version` failed: \(detail)"
            )
        }
        return result.output
    }

    /// Captures output in a regular file so a verbose child cannot fill a pipe and block before it exits.
    private func runCommand(executable: URL, arguments: [String]) throws -> CommandResult {
        let outputRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AtollLifecycleCommand-\(UUID().uuidString)")
        let standardOutputURL = outputRoot.appendingPathExtension("stdout")
        let standardErrorURL = outputRoot.appendingPathExtension("stderr")
        defer {
            try? fileManager.removeItem(at: standardOutputURL)
            try? fileManager.removeItem(at: standardErrorURL)
        }
        _ = fileManager.createFile(
            atPath: standardOutputURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        _ = fileManager.createFile(
            atPath: standardErrorURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
        defer { try? standardOutputHandle.close() }
        let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
        defer { try? standardErrorHandle.close() }

        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, override in override }
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        guard completion.wait(timeout: .now() + commandTimeout) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + 0.5) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.5)
            }
            try? standardOutputHandle.synchronize()
            try? standardErrorHandle.synchronize()
            throw CommandExecutionError.timedOut(
                output: capturedOutput(at: [standardOutputURL, standardErrorURL])
            )
        }

        try? standardOutputHandle.synchronize()
        try? standardErrorHandle.synchronize()
        return CommandResult(
            terminationStatus: process.terminationStatus,
            output: capturedOutput(at: [standardOutputURL, standardErrorURL])
        )
    }

    private func capturedOutput(at urls: [URL]) -> String {
        urls.compactMap { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 32 * 1024)) ?? nil
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func commandTimeoutDetail(command: String, output: String, fallback: String) -> String {
        let timeout = commandTimeout < 1
            ? String(format: "%.2f", commandTimeout)
            : String(format: "%.0f", commandTimeout)
        let detail = diagnosticOutput(output)
        if detail.isEmpty {
            return "\(fallback) `\(command)` timed out after \(timeout) seconds."
        }
        return "`\(command)` timed out after \(timeout) seconds: \(detail)"
    }

    private func diagnosticOutput(_ output: String) -> String {
        let trimmed = output
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1_000 else { return trimmed }
        return String(trimmed.prefix(1_000)) + "…"
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
        let url = configurationURL(for: .claude)
        try mergeSettings(at: url, agent: .claude) { hooks in
            try removeGroupedCommand(from: &hooks, event: "SessionEnd", command: hookCommand(harness: "claude", kind: "finished"))
            try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "claude", kind: "started"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "claude", kind: "finished"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "StopFailure", command: hookCommand(harness: "claude", kind: "failed"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Notification", command: hookCommand(harness: "claude", kind: "needsPermission"), matcher: "permission_prompt")
            try addGroupedCommand(to: &hooks, event: "Notification", command: hookCommand(harness: "claude", kind: "needsInput"), matcher: "elicitation_dialog")
            try addGroupedCommand(to: &hooks, event: "Notification", command: hookCommand(harness: "claude", kind: "needsInput"), matcher: "agent_needs_input")
            try addGroupedCommand(to: &hooks, event: "Notification", command: hookCommand(harness: "claude", kind: "started"), matcher: "elicitation_complete")
            try addGroupedCommand(to: &hooks, event: "Notification", command: hookCommand(harness: "claude", kind: "started"), matcher: "elicitation_response")
            try addGroupedCommand(to: &hooks, event: "PostToolUse", command: hookCommand(harness: "claude", kind: "started"), matcher: "*")
            try addGroupedCommand(to: &hooks, event: "PostToolUseFailure", command: hookCommand(harness: "claude", kind: "started"), matcher: "*")
            try addGroupedCommand(to: &hooks, event: "PermissionDenied", command: hookCommand(harness: "claude", kind: "started"), matcher: "*")
        }
    }

    private func mergeCodexHooks() throws {
        try validateCodexHooksEnabled()
        let url = configurationURL(for: .codex)
        try mergeSettings(at: url, agent: .codex) { hooks in
            try addGroupedCommand(to: &hooks, event: "UserPromptSubmit", command: hookCommand(harness: "codex", kind: "started"), matcher: nil)
            try addGroupedCommand(to: &hooks, event: "Stop", command: hookCommand(harness: "codex", kind: "finished"), matcher: nil)
        }
    }

    private func validateCodexHooksEnabled() throws {
        let url = codexConfigurationDirectory.appendingPathComponent("config.toml")
        guard fileManager.fileExists(atPath: url.path) else { return }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let setting = disabledCodexHooksSetting(in: source) else { return }
        throw Error.hooksDisabled(url, setting: setting)
    }

    /// Recognizes only the documented feature assignments. It intentionally does not rewrite TOML.
    private func disabledCodexHooksSetting(in source: String) -> String? {
        enum Section {
            case root
            case features
            case other
        }
        var section = Section.root
        for rawLine in source.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let compact = uncommented.filter { !$0.isWhitespace }
            guard !compact.isEmpty else { continue }

            if compact.hasPrefix("[") {
                section = compact == "[features]" ? .features : .other
                continue
            }
            if section == .root, compact == "features.hooks=false" {
                return "features.hooks"
            }
            if section == .root, compact == "features.codex_hooks=false" {
                return "features.codex_hooks"
            }
            if section == .features, compact == "hooks=false" {
                return "features.hooks"
            }
            if section == .features, compact == "codex_hooks=false" {
                return "features.codex_hooks"
            }
            if section == .root, compact == "codex_hooks=false" {
                return "codex_hooks"
            }
        }
        return nil
    }

    private func mergeSettings(at url: URL, agent: AgentHarness, update: (inout [String: Any]) throws -> Void) throws {
        var root = try jsonObject(at: url)
        try validateHookConfiguration(root, for: agent, at: url)
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
        guard !containsGroupedCommand(entries, command: command, matcher: matcher) else { return }
        let hook: [String: Any] = ["type": "command", "command": command]
        var entry: [String: Any] = ["hooks": [hook]]
        if let matcher { entry["matcher"] = matcher }
        entries.append(entry)
        hooks[event] = entries
    }

    private func removeGroupedCommand(from hooks: inout [String: Any], event: String, command: String) throws {
        guard let value = hooks[event] else { return }
        guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        let remaining = entries.compactMap { object -> Any? in
            guard var group = object as? [String: Any], let handlers = group["hooks"] as? [Any] else {
                return object
            }
            let retained = handlers.filter { handler in
                guard let dictionary = handler as? [String: Any] else { return true }
                return dictionary["type"] as? String != "command"
                    || dictionary["command"] as? String != command
            }
            guard !retained.isEmpty else { return nil }
            group["hooks"] = retained
            return group
        }
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
    }

    private func removeFlatCommand(from hooks: inout [String: Any], event: String, command: String) throws {
        guard let value = hooks[event] else { return }
        guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        let remaining = entries.filter { ($0 as? [String: Any])?["command"] as? String != command }
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
    }

    private func containsGroupedCommand(
        _ object: Any?,
        command: String,
        matcher: String?,
        matchingAnyMatcher: Bool = false
    ) -> Bool {
        guard let groups = object as? [Any] else { return false }
        return groups.contains { object in
            guard let group = object as? [String: Any],
                  matchingAnyMatcher || matcherMatches(group["matcher"], expected: matcher),
                  let handlers = group["hooks"] as? [Any] else {
                return false
            }
            return handlers.contains { handler in
                guard let dictionary = handler as? [String: Any] else { return false }
                return dictionary["type"] as? String == "command"
                    && dictionary["command"] as? String == command
            }
        }
    }

    private func containsFlatCommand(_ object: Any?, command: String) -> Bool {
        guard let entries = object as? [Any] else { return false }
        return entries.contains { ($0 as? [String: Any])?["command"] as? String == command }
    }

    private func matcherMatches(_ value: Any?, expected: String?) -> Bool {
        guard let actual = value as? String else { return value == nil && (expected == nil || expected == "*") }
        if expected == nil || expected == "*" { return actual.isEmpty || actual == "*" }
        return actual == expected
    }

    private func isValidGroupedHook(_ object: Any) -> Bool {
        guard let group = object as? [String: Any],
              group["matcher"] == nil || group["matcher"] is String,
              let handlers = group["hooks"] as? [Any] else {
            return false
        }
        return handlers.allSatisfy { object in
            guard let handler = object as? [String: Any], let type = handler["type"] as? String else {
                return false
            }
            switch type {
            case "command": return handler["command"] is String
            case "http": return handler["url"] is String
            case "prompt", "agent": return handler["prompt"] is String
            default: return true
            }
        }
    }

    private func isValidFlatHook(_ object: Any) -> Bool {
        guard let hook = object as? [String: Any] else { return false }
        return hook["command"] is String
    }

    private func hookCommand(harness: String, kind: String) -> String {
        "\(shellQuote(bridgeURL.path)) \(harness) \(kind)"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
