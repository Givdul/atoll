import Darwin
import Foundation

/// Installs the small native-hook bridge. Call this only from an explicit user action.
public struct LifecycleHookInstaller {
    public enum Readiness: Equatable {
        case notConfigured
        case configured
        case invalidConfiguration(String)
    }

    public struct Diagnostic: Equatable, Sendable {
        public enum Integration: Equatable, Sendable {
            case missing
            case current
            case outdated
            case invalid(String)
            case disabled(String)
            case unowned(String)
        }

        public enum Bridge: Equatable, Sendable {
            case missing
            case current
            case outdated
            case incorrectPermissions
        }

        public enum Shadowing: Equatable, Sendable {
            case notDetected
            case blocked(String)
        }

        public enum Health: Equatable, Sendable {
            case agentNotFound
            case integrationMissing
            case integrationOutdated
            case externalConfiguration(String)
            case shadowed(String)
            case bridgeUnavailable
            case socketUnavailable
            case runtimeUnverified
            case ready(Date)
        }

        public let agent: AgentHarness
        public let agentFound: Bool
        public let integration: Integration
        public let bridge: Bridge
        public let shadowing: Shadowing
        public let socketAvailable: Bool
        public let lastValidEventAt: Date?
        public let canRemove: Bool

        public init(
            agent: AgentHarness,
            agentFound: Bool,
            integration: Integration,
            bridge: Bridge,
            shadowing: Shadowing,
            socketAvailable: Bool,
            lastValidEventAt: Date?,
            canRemove: Bool = false
        ) {
            self.agent = agent
            self.agentFound = agentFound
            self.integration = integration
            self.bridge = bridge
            self.shadowing = shadowing
            self.socketAvailable = socketAvailable
            self.lastValidEventAt = lastValidEventAt
            self.canRemove = canRemove
        }

        public var health: Health {
            guard agentFound else { return .agentNotFound }
            if case .blocked(let detail) = shadowing { return .shadowed(detail) }
            switch integration {
            case .missing: return .integrationMissing
            case .outdated: return .integrationOutdated
            case .invalid(let detail), .disabled(let detail), .unowned(let detail):
                return .externalConfiguration(detail)
            case .current: break
            }
            guard bridge == .current else { return .bridgeUnavailable }
            guard socketAvailable else { return .socketUnavailable }
            guard let lastValidEventAt else { return .runtimeUnverified }
            return .ready(lastValidEventAt)
        }

        public var canRepair: Bool {
            guard agentFound, shadowing == .notDetected else { return false }
            switch integration {
            case .missing, .outdated:
                return true
            case .current:
                return bridge != .current
            case .invalid, .disabled, .unowned:
                return false
            }
        }
    }

    public enum RemovalOutcome: Equatable, Sendable {
        case removed
        case notInstalled
        case failed(String)
    }

    public struct RemovalResult: Equatable, Sendable {
        public let agent: AgentHarness
        public let outcome: RemovalOutcome
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
        case unsupportedAgent(AgentHarness)
        case configurationChanged(URL)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let url): "Cannot merge hooks because \(url.path) is not a JSON object."
            case .invalidHookConfiguration(let url): "Cannot merge hooks because \(url.path) has an invalid hooks configuration."
            case .hooksDisabled(let url, let setting): "Live Status hooks are disabled by \(setting) in \(url.path)."
            case .managedFileConflict(let url): "Cannot install Topside's managed integration because \(url.path) already belongs to another extension or plugin."
            case .commandFailed(let detail): "Cannot finish setup: \(detail)"
            case .unsupportedPiVersion(let installed, let minimum): "Pi \(minimum) or newer is required for Live Status; found \(installed)."
            case .unreadablePiVersion(let minimum, let detail): "Pi \(minimum) or newer is required for Live Status, but Topside could not verify it: \(detail)"
            case .unsupportedAgent(let agent): "\(agent.displayName) is not a supported Live Status integration."
            case .configurationChanged(let url): "\(url.path) changed during setup. Topside left it untouched; try again."
            }
        }
    }

    public let homeDirectory: URL
    public let executablePath: String
    private let fileManager: FileManager
    private let piVersionOutput: (() throws -> String)?
    private let environment: [String: String]
    private let commandTimeout: TimeInterval
    private let codexRequirementsURL: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String = "/Applications/Topside.app/Contents/MacOS/Topside",
        fileManager: FileManager = .default,
        piVersionOutput: (() throws -> String)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandTimeout: TimeInterval = 10,
        codexRequirementsURL: URL = URL(fileURLWithPath: "/etc/codex/requirements.toml")
    ) {
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.fileManager = fileManager
        self.piVersionOutput = piVersionOutput
        self.environment = environment
        self.commandTimeout = max(0.01, commandTimeout)
        self.codexRequirementsURL = codexRequirementsURL
    }

    public func install(agents: [AgentHarness]) throws {
        if agents.contains(.pi) { try requireSupportedPiVersion() }
        try writeBridge()
        for agent in agents {
            switch agent {
            case .claude, .codex, .cursor:
                try mergeConfiguredHooks(for: agent)
            case .pi:
                try writePiExtension()
            case .opencode:
                try writeOpenCodePlugin()
            default:
                break
            }
        }
    }

    public func uninstall(agents: [AgentHarness]) -> [RemovalResult] {
        var results = agents.map { agent in
            do {
                return RemovalResult(
                    agent: agent,
                    outcome: try removeIntegration(for: agent) ? .removed : .notInstalled
                )
            } catch {
                return RemovalResult(agent: agent, outcome: .failed(error.localizedDescription))
            }
        }

        if !supportedIntegrationReferencesBridge(), fileManager.fileExists(atPath: bridgeURL.path) {
            do {
                try fileManager.removeItem(at: bridgeURL)
            } catch {
                if let index = results.indices.last,
                   case .failed = results[index].outcome {
                    // Keep the provider-specific failure, which is more actionable.
                } else if let index = results.indices.last {
                    results[index] = RemovalResult(
                        agent: results[index].agent,
                        outcome: .failed("The integration was removed, but Topside could not remove its unused bridge: \(error.localizedDescription)")
                    )
                }
            }
        }
        return results
    }

    public func hasIntegration(for agent: AgentHarness) -> Bool {
        switch agent {
        case .pi:
            return ([piExtensionURL] + legacyPiExtensionURLs).contains(where: managedFileIsOurs)
        case .opencode:
            return ([openCodePluginURL, legacyOpenCodePluginURL] + legacyOpenCodePluginURLs)
                .contains(where: managedFileIsOurs)
        case .claude, .codex, .cursor:
            let url = configurationURL(for: agent)
            guard let root = try? jsonObject(at: url),
                  let hooks = root["hooks"] as? [String: Any] else {
                return fileReferencesBridge(url)
            }
            return hookMap(hooks, containsAny: ownedCommands(for: agent), grouped: agent != .cursor)
                || fileReferencesBridge(url)
        default:
            return false
        }
    }

    public func canUninstall(for agent: AgentHarness) -> Bool {
        if hasIntegration(for: agent) { return true }
        switch agent {
        case .pi:
            return fileManager.fileExists(atPath: piExtensionURL.path)
        case .opencode:
            return [openCodePluginURL, legacyOpenCodePluginURL]
                .contains { fileManager.fileExists(atPath: $0.path) }
        case .claude, .codex, .cursor:
            let url = configurationURL(for: agent)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            return (try? jsonObject(at: url)) == nil
        default:
            return false
        }
    }

    public func detectedAgents() -> [AgentHarness] {
        Self.supportedAgents.filter { configurationDirectory(for: $0).map { fileManager.fileExists(atPath: $0.path) } == true || commandNames(for: $0).contains(where: commandIsAvailable) }
    }

    public func readiness(for agent: AgentHarness) -> Readiness {
        switch integrationState(for: agent) {
        case .current:
            return bridgeIsReady ? .configured : .notConfigured
        case .invalid(let detail), .disabled(let detail), .unowned(let detail):
            return .invalidConfiguration(detail)
        case .missing, .outdated:
            return .notConfigured
        }
    }

    public func diagnostic(
        for agent: AgentHarness,
        socketAvailable: Bool,
        lastValidEventAt: Date?
    ) -> Diagnostic {
        Diagnostic(
            agent: agent,
            agentFound: detectedAgents().contains(agent),
            integration: integrationState(for: agent),
            bridge: bridgeState,
            shadowing: shadowingState(for: agent),
            socketAvailable: socketAvailable,
            lastValidEventAt: lastValidEventAt,
            canRemove: hasIntegration(for: agent)
        )
    }

    private var bridgeURL: URL { homeDirectory.appendingPathComponent(".topside/bin/topside-hook") }
    private var legacyBridgeURLs: [URL] {
        [
            homeDirectory.appendingPathComponent(".skerry/bin/skerry-hook"),
            homeDirectory.appendingPathComponent(".atoll/bin/atoll-hook")
        ]
    }

    private struct JSONConfigurationSnapshot {
        let root: [String: Any]
        let contents: Data?
        let destinationURL: URL
    }

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

    private struct HookContract {
        enum Style: Equatable {
            case grouped
            case flat
        }

        let style: Style
        let requirements: [HookRequirement]
        let obsolete: [HookRequirement]
    }

    private func hookContract(for agent: AgentHarness) -> HookContract? {
        switch agent {
        case .claude:
            HookContract(
                style: .grouped,
                requirements: [
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
                ],
                obsolete: [HookRequirement("SessionEnd", "finished")]
            )
        case .codex:
            HookContract(
                style: .grouped,
                requirements: [
                    HookRequirement("UserPromptSubmit", "started"),
                    HookRequirement("Stop", "finished")
                ],
                obsolete: []
            )
        case .cursor:
            HookContract(
                style: .flat,
                requirements: [
                    HookRequirement("beforeSubmitPrompt", "started"),
                    HookRequirement("stop", "finished")
                ],
                obsolete: [
                    HookRequirement("sessionStart", "started"),
                    HookRequirement("sessionEnd", "finished")
                ]
            )
        default:
            nil
        }
    }

    private func hasAllCommands(in root: [String: Any], for agent: AgentHarness) -> Bool {
        guard let contract = hookContract(for: agent),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        let hasRequiredHooks = contract.requirements.allSatisfy { requirement in
            let command = hookCommand(harness: agent.rawValue, kind: requirement.kind)
            switch contract.style {
            case .flat:
                return containsFlatCommand(hooks[requirement.event], command: command)
            case .grouped:
                return containsGroupedCommand(
                    hooks[requirement.event],
                    command: command,
                    matcher: requirement.matcher
                )
            }
        }
        guard hasRequiredHooks else { return false }
        return !contract.obsolete.contains { requirement in
            let command = hookCommand(harness: agent.rawValue, kind: requirement.kind)
            switch contract.style {
            case .flat:
                return containsFlatCommand(hooks[requirement.event], command: command)
            case .grouped:
                return containsGroupedCommand(
                    hooks[requirement.event],
                    command: command,
                    matcher: requirement.matcher,
                    matchingAnyMatcher: true
                )
            }
        }
    }

    private func validateHookConfiguration(
        _ root: [String: Any],
        for agent: AgentHarness,
        at url: URL,
        allowDisabled: Bool = false
    ) throws {
        if agent == .claude, root["disableAllHooks"] != nil {
            guard let disabled = root["disableAllHooks"] as? Bool else {
                throw Error.invalidHookConfiguration(url)
            }
            if disabled && !allowDisabled { throw Error.hooksDisabled(url, setting: "disableAllHooks") }
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

    private var piExtensionURL: URL { piConfigurationDirectory.appendingPathComponent("extensions/topside.ts") }
    private var openCodePluginURL: URL { openCodeConfigurationDirectory.appendingPathComponent("plugins/topside.js") }
    private var legacyOpenCodePluginURL: URL { openCodeConfigurationDirectory.appendingPathComponent("plugin/topside.js") }
    private var legacyPiExtensionURLs: [URL] {
        [
            piConfigurationDirectory.appendingPathComponent("extensions/skerry.ts"),
            piConfigurationDirectory.appendingPathComponent("extensions/atoll.ts")
        ]
    }
    private var legacyOpenCodePluginURLs: [URL] {
        [
            openCodeConfigurationDirectory.appendingPathComponent("plugins/skerry.js"),
            openCodeConfigurationDirectory.appendingPathComponent("plugin/skerry.js"),
            openCodeConfigurationDirectory.appendingPathComponent("plugins/atoll.js"),
            openCodeConfigurationDirectory.appendingPathComponent("plugin/atoll.js")
        ]
    }
    private var managedMarker: String { "Topside Live Status managed integration" }
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
        export const TopsideLiveStatus = async ({ directory }) => {
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

    private func mergeConfiguredHooks(for agent: AgentHarness) throws {
        guard let contract = hookContract(for: agent) else {
            throw Error.unsupportedAgent(agent)
        }
        if agent == .codex { try validateCodexHooksEnabled() }
        let url = configurationURL(for: agent)
        let snapshot = try jsonConfiguration(at: url)
        var root = snapshot.root
        try validateHookConfiguration(root, for: agent, at: url)
        let value = root["hooks"] ?? [String: Any]()
        guard var hooks = value as? [String: Any] else {
            throw Error.invalidHookConfiguration(url)
        }
        for event in Array(hooks.keys) {
            for command in ownedCommands(for: agent) {
                switch contract.style {
                case .flat:
                    try removeFlatCommand(from: &hooks, event: event, command: command)
                case .grouped:
                    try removeGroupedCommand(from: &hooks, event: event, command: command)
                }
            }
        }
        for requirement in contract.requirements {
            let command = hookCommand(harness: agent.rawValue, kind: requirement.kind)
            switch contract.style {
            case .flat:
                let value = hooks[requirement.event] ?? []
                guard var entries = value as? [Any] else {
                    throw Error.invalidHookConfiguration(url)
                }
                if !containsFlatCommand(entries, command: command) {
                    entries.append(["command": command])
                    hooks[requirement.event] = entries
                }
            case .grouped:
                try addGroupedCommand(
                    to: &hooks,
                    event: requirement.event,
                    command: command,
                    matcher: requirement.matcher
                )
            }
        }
        if contract.style == .flat {
            root["version"] = root["version"] ?? 1
        }
        root["hooks"] = hooks
        try write(root, snapshot: snapshot, at: url)
    }

    private func writePiExtension() throws {
        let legacySnapshots = try ownedManagedFileSnapshots(at: legacyPiExtensionURLs)
        try writeManagedFile(piExtensionSource, to: piExtensionURL)
        try removeUnchangedManagedFiles(legacySnapshots)
    }

    private func writeOpenCodePlugin() throws {
        let obsoleteSnapshots = try ownedManagedFileSnapshots(
            at: [legacyOpenCodePluginURL] + legacyOpenCodePluginURLs
        )
        try writeManagedFile(openCodePluginSource, to: openCodePluginURL)
        try removeUnchangedManagedFiles(obsoleteSnapshots)
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
            .appendingPathComponent("TopsideLifecycleCommand-\(UUID().uuidString)")
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

    private func integrationState(for agent: AgentHarness) -> Diagnostic.Integration {
        guard Self.supportedAgents.contains(agent) else { return .missing }
        do {
            switch agent {
            case .pi:
                try requireSupportedPiVersion()
                if legacyPiExtensionURLs.contains(where: managedFileIsOurs) {
                    return .outdated
                }
                return managedIntegrationState(expected: piExtensionSource, at: piExtensionURL)
            case .opencode:
                if fileManager.fileExists(atPath: openCodePluginURL.path) {
                    guard managedFileIsOurs(at: openCodePluginURL) else {
                        return .unowned("The OpenCode plugin path belongs to another file. Topside left it untouched.")
                    }
                    if ([legacyOpenCodePluginURL] + legacyOpenCodePluginURLs)
                        .contains(where: managedFileIsOurs) {
                        return .outdated
                    }
                    return managedFileMatches(openCodePluginSource, at: openCodePluginURL) ? .current : .outdated
                }
                if ([legacyOpenCodePluginURL] + legacyOpenCodePluginURLs)
                    .contains(where: managedFileIsOurs) {
                    return .outdated
                }
                return .missing
            case .claude, .codex, .cursor:
                if agent == .codex { try validateCodexHooksEnabled() }
                if agent == .claude, managedClaudeSetting("disableAllHooks") == true {
                    return .disabled("Managed Claude Code settings disable hooks. Ask your administrator to enable them.")
                }
                let url = configurationURL(for: agent)
                let root = try jsonObject(at: url)
                try validateHookConfiguration(root, for: agent, at: url)
                if hasAllCommands(in: root, for: agent) { return .current }
                return hasIntegration(for: agent) ? .outdated : .missing
            default:
                return .missing
            }
        } catch let error as Error {
            if case .hooksDisabled = error { return .disabled(error.localizedDescription) }
            return .invalid(error.localizedDescription)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private func managedIntegrationState(expected: String, at url: URL) -> Diagnostic.Integration {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        guard managedFileIsOurs(at: url) else {
            return .unowned("\(url.path) belongs to another extension. Topside left it untouched.")
        }
        return managedFileMatches(expected, at: url) ? .current : .outdated
    }

    private var bridgeState: Diagnostic.Bridge {
        guard fileManager.fileExists(atPath: bridgeURL.path) else { return .missing }
        guard managedFileMatches(bridgeSource, at: bridgeURL) else { return .outdated }
        guard let attributes = try? fileManager.attributesOfItem(atPath: bridgeURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700 else {
            return .incorrectPermissions
        }
        return .current
    }

    private func shadowingState(for agent: AgentHarness) -> Diagnostic.Shadowing {
        if agent == .claude, managedClaudeSetting("allowManagedHooksOnly") == true {
            return .blocked("Managed Claude Code policy allows only administrator hooks, so it blocks Topside's user hook.")
        }
        if agent == .codex,
           let source = try? String(contentsOf: codexRequirementsURL, encoding: .utf8),
           managedCodexHooksOnly(in: source) {
            return .blocked("Managed Codex policy allows only administrator hooks, so it blocks Topside's user hook.")
        }
        return .notDetected
    }

    private func managedClaudeSetting(_ key: String) -> Bool? {
        for url in managedClaudeSettingsURLs().reversed() {
            guard let value = (try? jsonObject(at: url))?[key] as? Bool else { continue }
            return value
        }
        return nil
    }

    private func managedClaudeSettingsURLs() -> [URL] {
        let directory = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true)
        let dropIns = directory.appendingPathComponent("managed-settings.d", isDirectory: true)
        let files = fileManager.fileExists(atPath: dropIns.path)
            ? (try? fileManager.contentsOfDirectory(
                at: dropIns,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            : []
        return [directory.appendingPathComponent("managed-settings.json")] + files
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
        let destination = url.resolvingSymlinksInPath().standardizedFileURL
        let existing = try currentContents(at: url)
        if let existing, !managedFileIsOurs(existing) {
            throw Error.managedFileConflict(url)
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(source.utf8).write(to: temporaryURL)
        guard url.resolvingSymlinksInPath().standardizedFileURL == destination,
              try currentContents(at: url) == existing else {
            throw Error.configurationChanged(url)
        }
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeIntegration(for agent: AgentHarness) throws -> Bool {
        guard Self.supportedAgents.contains(agent) else { throw Error.unsupportedAgent(agent) }
        switch agent {
        case .pi:
            return try removeManagedFiles(
                at: [piExtensionURL] + legacyPiExtensionURLs,
                requiringOwnershipAt: [piExtensionURL]
            )
        case .opencode:
            return try removeManagedFiles(
                at: [openCodePluginURL, legacyOpenCodePluginURL] + legacyOpenCodePluginURLs,
                requiringOwnershipAt: [openCodePluginURL]
            )
        case .claude, .codex, .cursor:
            return try removeOwnedHooks(for: agent)
        default:
            return false
        }
    }

    private func removeOwnedHooks(for agent: AgentHarness) throws -> Bool {
        let url = configurationURL(for: agent)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let snapshot = try jsonConfiguration(at: url)
        var root = snapshot.root
        try validateHookConfiguration(root, for: agent, at: url, allowDisabled: true)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }

        var removed = false
        for event in Array(hooks.keys) {
            for command in ownedCommands(for: agent) {
                if agent == .cursor {
                    if try removeFlatCommand(from: &hooks, event: event, command: command) {
                        removed = true
                    }
                } else if try removeGroupedCommand(from: &hooks, event: event, command: command) {
                    removed = true
                }
            }
        }
        guard removed else { return false }
        root["hooks"] = hooks
        try write(root, snapshot: snapshot, at: url)
        return true
    }

    private func removeManagedFiles(
        at urls: [URL],
        requiringOwnershipAt protectedURLs: [URL]
    ) throws -> Bool {
        let allSnapshots = try urls.compactMap { url -> ManagedFileSnapshot? in
            guard let contents = try currentContents(at: url) else { return nil }
            return (url, url.resolvingSymlinksInPath().standardizedFileURL, contents)
        }
        for snapshot in allSnapshots
        where protectedURLs.contains(snapshot.url) && !managedFileIsOurs(snapshot.contents) {
            throw Error.managedFileConflict(snapshot.url)
        }
        let snapshots = allSnapshots.filter { managedFileIsOurs($0.contents) }
        guard !snapshots.isEmpty else { return false }
        try removeUnchangedManagedFiles(snapshots)
        return true
    }

    private typealias ManagedFileSnapshot = (url: URL, destination: URL, contents: Data)

    private func ownedManagedFileSnapshots(at urls: [URL]) throws -> [ManagedFileSnapshot] {
        try urls.compactMap { url in
            guard let contents = try currentContents(at: url),
                  managedFileIsOurs(contents) else { return nil }
            return (url, url.resolvingSymlinksInPath().standardizedFileURL, contents)
        }
    }

    private func removeUnchangedManagedFiles(_ snapshots: [ManagedFileSnapshot]) throws {
        for snapshot in snapshots {
            guard snapshot.url.resolvingSymlinksInPath().standardizedFileURL == snapshot.destination,
                  try currentContents(at: snapshot.url) == snapshot.contents else {
                throw Error.configurationChanged(snapshot.url)
            }
        }
        for snapshot in snapshots {
            try fileManager.removeItem(at: snapshot.url)
        }
    }

    private func managedFileIsOurs(at url: URL) -> Bool {
        guard let contents = try? Data(contentsOf: url) else { return false }
        return managedFileIsOurs(contents)
    }

    private func managedFileIsOurs(_ contents: Data) -> Bool {
        guard let source = String(data: contents, encoding: .utf8),
              let firstLine = source
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first else { return false }

        let expectedBridge: URL
        switch String(firstLine) {
        case "// \(managedMarker)":
            expectedBridge = bridgeURL
        case "// Skerry Live Status managed integration":
            expectedBridge = legacyBridgeURLs[0]
        case "// Atoll Live Status managed integration":
            expectedBridge = legacyBridgeURLs[1]
        default:
            return false
        }
        return source.contains(expectedBridge.path)
            || source.contains(expectedBridge.path.replacingOccurrences(of: "/", with: #"\/"#))
    }

    private func ownedCommands(for agent: AgentHarness) -> Set<String> {
        let currentKinds = hookContract(for: agent)?.requirements.map(\.kind) ?? []
        let historicalKinds = LifecycleEventKind.allCases.map(\.rawValue)
        return Set((currentKinds + historicalKinds).flatMap { kind in
            [hookCommand(harness: agent.rawValue, kind: kind)]
                + legacyHookCommands(harness: agent.rawValue, kind: kind)
        })
    }

    private func hookMap(_ hooks: [String: Any], containsAny commands: Set<String>, grouped: Bool) -> Bool {
        hooks.values.contains { value in
            if grouped {
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.contains { group in
                    guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                    return handlers.contains {
                        $0["type"] as? String == "command"
                            && ($0["command"] as? String).map(commands.contains) == true
                    }
                }
            }
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { ($0["command"] as? String).map(commands.contains) == true }
        }
    }

    private func supportedIntegrationReferencesBridge() -> Bool {
        Self.supportedAgents.contains { agent in
            switch agent {
            case .opencode:
                return fileReferencesBridge(openCodePluginURL)
                    || fileReferencesBridge(legacyOpenCodePluginURL)
                    || legacyOpenCodePluginURLs.contains(where: fileReferencesBridge)
            case .pi:
                return fileReferencesBridge(piExtensionURL)
                    || legacyPiExtensionURLs.contains(where: fileReferencesBridge)
            default:
                return fileReferencesBridge(configurationURL(for: agent))
            }
        }
    }

    private func fileReferencesBridge(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { return true }
        if let object = try? JSONSerialization.jsonObject(with: data),
           jsonValueReferencesBridge(object) {
            return true
        }
        guard let source = String(data: data, encoding: .utf8) else { return true }
        return ([bridgeURL] + legacyBridgeURLs).map(\.path).contains {
            source.contains($0)
                || source.contains($0.replacingOccurrences(of: "/", with: #"\/"#))
        }
    }

    private func jsonValueReferencesBridge(_ value: Any) -> Bool {
        if let string = value as? String {
            return ([bridgeURL] + legacyBridgeURLs).contains { string.contains($0.path) }
        }
        if let array = value as? [Any] { return array.contains(where: jsonValueReferencesBridge) }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: jsonValueReferencesBridge)
        }
        return false
    }

    private func javaScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\\\", with: "\\\\\\\\").replacingOccurrences(of: "\"", with: "\\\\\""))\""
    }

    private func validateCodexHooksEnabled() throws {
        let userConfigurationURL = codexConfigurationDirectory.appendingPathComponent("config.toml")
        var managedHooksEnabled = false
        if fileManager.fileExists(atPath: codexRequirementsURL.path) {
            let source = try String(contentsOf: codexRequirementsURL, encoding: .utf8)
            if let setting = codexHooksSetting(in: source) {
                guard setting.enabled else {
                    throw Error.hooksDisabled(codexRequirementsURL, setting: setting.name)
                }
                managedHooksEnabled = true
            }
            if managedCodexHooksOnly(in: source) {
                throw Error.hooksDisabled(codexRequirementsURL, setting: "allow_managed_hooks_only")
            }
        }
        guard !managedHooksEnabled, fileManager.fileExists(atPath: userConfigurationURL.path) else { return }
        let source = try String(contentsOf: userConfigurationURL, encoding: .utf8)
        if let setting = codexHooksSetting(in: source), !setting.enabled {
            throw Error.hooksDisabled(userConfigurationURL, setting: setting.name)
        }
    }

    private func managedCodexHooksOnly(in source: String) -> Bool {
        var isRoot = true
        for rawLine in source.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let compact = uncommented.filter { !$0.isWhitespace }
            if compact.hasPrefix("[") {
                isRoot = false
            } else if isRoot, compact == "allow_managed_hooks_only=true" {
                return true
            }
        }
        return false
    }

    /// Recognizes only the documented feature assignments. It intentionally does not rewrite TOML.
    private func codexHooksSetting(in source: String) -> (name: String, enabled: Bool)? {
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
            let assignments: [(prefix: String, name: String)]
            switch section {
            case .root:
                assignments = [
                    ("features.hooks=", "features.hooks"),
                    ("features.codex_hooks=", "features.codex_hooks"),
                    ("codex_hooks=", "codex_hooks")
                ]
            case .features:
                assignments = [
                    ("hooks=", "features.hooks"),
                    ("codex_hooks=", "features.codex_hooks")
                ]
            case .other:
                assignments = []
            }
            for assignment in assignments where compact.hasPrefix(assignment.prefix) {
                switch compact.dropFirst(assignment.prefix.count) {
                case "true": return (assignment.name, true)
                case "false": return (assignment.name, false)
                default: break
                }
            }
        }
        return nil
    }

    private func jsonConfiguration(at url: URL) throws -> JSONConfigurationSnapshot {
        let destinationURL = url.resolvingSymlinksInPath().standardizedFileURL
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil,
           !fileManager.fileExists(atPath: destinationURL.path) {
            throw Error.invalidHookConfiguration(url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return JSONConfigurationSnapshot(root: [:], contents: nil, destinationURL: destinationURL)
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { throw Error.invalidJSON(url) }
        return JSONConfigurationSnapshot(root: dictionary, contents: data, destinationURL: destinationURL)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try jsonConfiguration(at: url).root
    }

    private func write(
        _ object: [String: Any],
        snapshot: JSONConfigurationSnapshot,
        at url: URL
    ) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL == snapshot.destinationURL,
              try currentContents(at: url) == snapshot.contents else {
            throw Error.configurationChanged(url)
        }

        let destination = snapshot.destinationURL
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL)

        if let permissions = try? fileManager.attributesOfItem(atPath: destination.path)[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
        }

        guard url.resolvingSymlinksInPath().standardizedFileURL == destination,
              try currentContents(at: url) == snapshot.contents else {
            throw Error.configurationChanged(url)
        }
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func currentContents(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
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

    @discardableResult
    private func removeGroupedCommand(from hooks: inout [String: Any], event: String, command: String) throws -> Bool {
        guard let value = hooks[event] else { return false }
        guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        var removed = false
        let remaining = entries.compactMap { object -> Any? in
            guard var group = object as? [String: Any], let handlers = group["hooks"] as? [Any] else {
                return object
            }
            let retained = handlers.filter { handler in
                guard let dictionary = handler as? [String: Any] else { return true }
                let isOwned = dictionary["type"] as? String == "command"
                    && dictionary["command"] as? String == command
                if isOwned { removed = true }
                return !isOwned
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
        return removed
    }

    @discardableResult
    private func removeFlatCommand(from hooks: inout [String: Any], event: String, command: String) throws -> Bool {
        guard let value = hooks[event] else { return false }
        guard let entries = value as? [Any] else { throw Error.invalidHookConfiguration(homeDirectory) }
        let remaining = entries.filter {
            ($0 as? [String: Any])?["command"] as? String != command
        }
        let removed = remaining.count != entries.count
        if remaining.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = remaining
        }
        return removed
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

    private func legacyHookCommands(harness: String, kind: String) -> [String] {
        legacyBridgeURLs.map { "\(shellQuote($0.path)) \(harness) \(kind)" }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
