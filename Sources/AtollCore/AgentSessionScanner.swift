import Darwin
import Foundation

public final class AgentSessionScanner: Sendable {
    private let homeDirectory: URL
    private let enableCLIProbes: Bool
    private let processProvider: @Sendable () -> [RunningProcess]
    private let maxSessionsPerHarness = 24
    private let openCodeTailEventsPerSession = 64

    private struct OpenCodeEventSignal {
        var state: SessionState
        var updatedAt: Date
        var confidence: SessionConfidence
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        enableCLIProbes: Bool = true,
        processProvider: @escaping @Sendable () -> [RunningProcess] = { ProcessSnapshot.capture() }
    ) {
        self.homeDirectory = homeDirectory
        self.enableCLIProbes = enableCLIProbes
        self.processProvider = processProvider
    }

    public func scan() -> [AgentSession] {
        let processes = processProvider()
        var sessions: [AgentSession] = []

        sessions += scanOpenCode(processes: processes)
        sessions += scanCodex(processes: processes)
        sessions += scanClaude(processes: processes)
        sessions += scanCopilot(processes: processes)
        sessions += scanPi(processes: processes)
        sessions += scanAtollFrames(processes: processes)

        return deduplicate(sessions)
            .sorted {
                if $0.state.sortRank != $1.state.sortRank {
                    return $0.state.sortRank < $1.state.sortRank
                }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(80)
            .map { $0 }
    }

    private func scanOpenCode(processes: [RunningProcess]) -> [AgentSession] {
        var sessions = scanOpenCodeDatabase(processes: processes)
        if !sessions.isEmpty {
            return Array(sessions.prefix(maxSessionsPerHarness))
        }

        let roots = [
            homeDirectory.appendingPathComponent(".local/share/opencode/storage/session"),
            homeDirectory.appendingPathComponent("Library/Application Support/opencode/storage/session")
        ]

        sessions = roots.flatMap {
            FileUtilities.recentFiles(
                under: $0,
                extensions: ["json"],
                maxFiles: maxSessionsPerHarness,
                scanCap: 1_000
            )
            .map { file in
                sessionFromFile(harness: .opencode, file: file, processes: processes, fallbackTitle: "OpenCode session")
            }
        }

        return Array(sessions.prefix(maxSessionsPerHarness))
    }

    private func scanOpenCodeDatabase(processes: [RunningProcess]) -> [AgentSession] {
        let database = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileUtilities.isRegularFile(database),
              let rows = sqliteRows(
                database: database,
                query: """
                select id, title, directory, path, time_updated, time_created, model, agent, permission
                from session
                where time_archived is null
                order by time_updated desc
                limit \(maxSessionsPerHarness)
                """
              ) else {
            return []
        }

        let dictionaries = rows.compactMap { $0 as? [String: Any] }
        let sessionIDs = dictionaries.compactMap {
            JSONHelpers.string(in: $0, keys: ["id"])
        }
        let eventSignals = openCodeEventSignals(database: database, sessionIDs: sessionIDs)

        return dictionaries.compactMap { dictionary in
            let id = JSONHelpers.string(in: dictionary, keys: ["id"]) ?? UUID().uuidString
            let title = TranscriptSummary.cleanTitle(
                JSONHelpers.string(in: dictionary, keys: ["title", "slug"])
            ) ?? "OpenCode session"
            let projectPath = JSONHelpers.string(in: dictionary, keys: ["directory", "path"])
            let databaseUpdatedAt = JSONHelpers.date(
                in: dictionary,
                keys: ["time_updated", "updatedAt", "updated_at"]
            ) ?? Date()
            let model = modelName(from: JSONHelpers.string(in: dictionary, keys: ["model"]))
            let text = JSONHelpers.flatten(dictionary)
            let fallback = SessionClassifier.classify(
                harness: .opencode,
                tailObjects: [dictionary],
                tailText: text,
                modifiedAt: databaseUpdatedAt,
                processes: processes
            )
            let eventSignal = eventSignals[id]
            let updatedAt = max(databaseUpdatedAt, eventSignal?.updatedAt ?? .distantPast)

            return AgentSession(
                id: "opencode-\(id)",
                harness: .opencode,
                title: title,
                detail: projectDetail(projectPath) ?? "OpenCode",
                projectPath: projectPath,
                model: model,
                state: eventSignal?.state ?? fallback.0,
                updatedAt: updatedAt,
                startedAt: JSONHelpers.date(in: dictionary, keys: ["time_created"]),
                sourcePath: database.path,
                processID: fallback.2,
                confidence: eventSignal?.confidence ?? fallback.1
            )
        }
    }

    private func openCodeEventSignals(database: URL, sessionIDs: [String]) -> [String: OpenCodeEventSignal] {
        let uniqueSessionIDs = Array(Set(sessionIDs)).sorted()
        guard !uniqueSessionIDs.isEmpty else {
            return [:]
        }

        let quotedIDs = uniqueSessionIDs
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        let query = """
        with ranked as (
            select aggregate_id, seq, type, data,
                   row_number() over (partition by aggregate_id order by seq desc) as row_number
            from event
            where aggregate_id in (\(quotedIDs))
        )
        select aggregate_id, seq, type, data
        from ranked
        where row_number <= \(openCodeTailEventsPerSession)
        order by aggregate_id asc, seq desc
        """

        guard let rows = sqliteRows(database: database, query: query) else {
            return [:]
        }

        var grouped: [String: [[String: Any]]] = [:]
        for object in rows {
            guard let row = object as? [String: Any],
                  let sessionID = JSONHelpers.string(in: row, keys: ["aggregate_id"]) else {
                continue
            }
            grouped[sessionID, default: []].append(row)
        }

        var result: [String: OpenCodeEventSignal] = [:]
        for (sessionID, rows) in grouped {
            if let signal = openCodeEventSignal(from: rows) {
                result[sessionID] = signal
            }
        }
        return result
    }

    private func openCodeEventSignal(from rows: [[String: Any]]) -> OpenCodeEventSignal? {
        let sortedRows = rows.sorted {
            JSONHelpers.string(in: $0, keys: ["seq"]).flatMap(Int.init) ?? 0 >
                JSONHelpers.string(in: $1, keys: ["seq"]).flatMap(Int.init) ?? 0
        }

        for row in sortedRows {
            let eventType = JSONHelpers.string(in: row, keys: ["type"])?.lowercased() ?? ""
            let dataText = JSONHelpers.string(in: row, keys: ["data"]) ?? ""
            let dataObject = JSONHelpers.object(from: dataText)
            let eventAt = openCodeEventDate(row: row, dataObject: dataObject)

            if let waitingState = openCodeWaitingState(eventType: eventType, dataText: dataText),
               let eventAt {
                return OpenCodeEventSignal(
                    state: waitingState,
                    updatedAt: eventAt,
                    confidence: .live
                )
            }

            guard eventType == "message.updated.1",
                  let dataDictionary = dataObject as? [String: Any],
                  let message = dataDictionary["info"] as? [String: Any],
                  JSONHelpers.string(in: message, keys: ["role"])?.lowercased() == "assistant" else {
                continue
            }

            let messageCompletedAt = JSONHelpers.date(in: message["time"], keys: ["completed"])
            if let messageCompletedAt {
                return OpenCodeEventSignal(
                    state: .done,
                    updatedAt: messageCompletedAt,
                    confidence: isFresh(messageCompletedAt, maxAge: 8) ? .live : .historical
                )
            }

            if let messageStartedAt = JSONHelpers.date(in: message["time"], keys: ["created"]) ?? eventAt {
                return OpenCodeEventSignal(
                    state: .running,
                    updatedAt: messageStartedAt,
                    confidence: .live
                )
            }
        }

        return nil
    }

    private func openCodeWaitingState(eventType: String, dataText: String) -> SessionState? {
        let lower = "\(eventType) \(dataText)".lowercased()
        let asksPermission = [
            "approval_requested",
            "approval-requested",
            "permission.requested",
            "permission_requested",
            "permission.request",
            "request_permission",
            "request_permissions",
            "tool_approval"
        ].contains { lower.contains($0) }
        if eventType.contains("permission") || asksPermission {
            return .waitingForPermission
        }

        let asksInput = [
            "request_user_input",
            "ask_user_question",
            "askuserquestion",
            "waiting_for_input",
            "input_requested",
            "input-requested"
        ].contains { lower.contains($0) }
        if eventType.contains("input") || asksInput {
            return .waitingForInput
        }

        return nil
    }

    private func openCodeEventDate(row: [String: Any], dataObject: Any?) -> Date? {
        if let dataDictionary = dataObject as? [String: Any] {
            if let date = DateParsing.date(from: dataDictionary["time"]) {
                return date
            }
            if let date = JSONHelpers.date(
                in: dataDictionary,
                keys: ["updated", "completed", "created", "end", "start"]
            ) {
                return date
            }
        }

        return JSONHelpers.date(in: row, keys: ["time", "time_updated", "updated_at", "created_at"])
    }

    private func newest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else {
            return rhs
        }
        guard let rhs else {
            return lhs
        }
        return max(lhs, rhs)
    }

    private func isFresh(_ date: Date, maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(date) <= maxAge
    }

    private func scanCodex(processes: [RunningProcess]) -> [AgentSession] {
        var sessions = scanCodexDatabase(processes: processes)
        var seenIDs = Set(sessions.map(\.id))

        for session in scanCodexIndex(processes: processes) where seenIDs.insert(session.id).inserted {
            sessions.append(session)
        }

        let roots = [
            homeDirectory.appendingPathComponent(".codex/sessions"),
            homeDirectory.appendingPathComponent(".codex/archived_sessions")
        ]

        let fileSessions = roots
            .flatMap {
                FileUtilities.recentFiles(
                    under: $0,
                    extensions: ["jsonl"],
                    maxFiles: maxSessionsPerHarness
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxSessionsPerHarness)
            .map { file in
                sessionFromFile(harness: .codex, file: file, processes: processes, fallbackTitle: "Codex session")
            }

        for session in fileSessions where seenIDs.insert(session.id).inserted {
            sessions.append(session)
        }

        return Array(sessions
            .sorted {
                if $0.state.sortRank != $1.state.sortRank {
                    return $0.state.sortRank < $1.state.sortRank
                }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(maxSessionsPerHarness))
    }

    private func scanCodexDatabase(processes: [RunningProcess]) -> [AgentSession] {
        let database = homeDirectory.appendingPathComponent(".codex/state_5.sqlite")
        guard FileUtilities.isRegularFile(database),
              let rows = sqliteRows(
                database: database,
                query: """
                select id, title, cwd, rollout_path, updated_at_ms, updated_at, created_at_ms, created_at, model, agent_role
                from threads
                where archived = 0
                order by coalesce(updated_at_ms, updated_at * 1000) desc
                limit \(maxSessionsPerHarness)
                """
              ) else {
            return []
        }

        return rows.compactMap { object in
            guard let dictionary = object as? [String: Any] else {
                return nil
            }

            let rolloutPath = JSONHelpers.string(in: dictionary, keys: ["rollout_path"])
            if let rolloutPath {
                let rolloutURL = URL(fileURLWithPath: rolloutPath)
                if FileUtilities.isRegularFile(rolloutURL) {
                    let fileUpdatedAt = FileUtilities.fileModificationDate(rolloutURL)
                    var session = transcriptSession(
                        harness: .codex,
                        file: RecentFile(url: rolloutURL, modifiedAt: fileUpdatedAt),
                        processes: processes,
                        fallbackTitle: "Codex session"
                    )
                    let databaseUpdatedAt = JSONHelpers.date(in: dictionary, keys: ["updated_at_ms", "updated_at"])
                    session.id = "codex-\(JSONHelpers.string(in: dictionary, keys: ["id"]) ?? session.id)"
                    session.title = TranscriptSummary.cleanTitle(JSONHelpers.string(in: dictionary, keys: ["title"])) ?? session.title
                    session.projectPath = JSONHelpers.string(in: dictionary, keys: ["cwd"]) ?? session.projectPath
                    session.detail = projectDetail(session.projectPath) ?? session.detail
                    session.model = JSONHelpers.string(in: dictionary, keys: ["model"]) ?? session.model
                    session.updatedAt = max(databaseUpdatedAt ?? .distantPast, fileUpdatedAt)
                    session.startedAt = JSONHelpers.date(in: dictionary, keys: ["created_at_ms", "created_at"]) ?? session.startedAt
                    return session
                }
            }

            return codexSessionFromIndexObject(dictionary, sourcePath: database.path, processes: processes)
        }
    }

    private func scanCodexIndex(processes: [RunningProcess]) -> [AgentSession] {
        let index = homeDirectory.appendingPathComponent(".codex/session_index.jsonl")
        guard FileUtilities.isRegularFile(index) else {
            return []
        }

        return FileUtilities.tailLines(from: index, maxBytes: 512_000, maxLines: maxSessionsPerHarness * 2)
            .compactMap(JSONHelpers.object)
            .compactMap { object in
                guard let dictionary = object as? [String: Any] else {
                    return nil
                }
                return codexSessionFromIndexObject(dictionary, sourcePath: index.path, processes: processes)
            }
    }

    private func codexSessionFromIndexObject(
        _ dictionary: [String: Any],
        sourcePath: String,
        processes: [RunningProcess]
    ) -> AgentSession {
        let id = JSONHelpers.string(in: dictionary, keys: ["id", "session_id", "sessionId"]) ?? UUID().uuidString
        let title = TranscriptSummary.cleanTitle(
            JSONHelpers.string(in: dictionary, keys: ["title", "thread_name", "name"])
        ) ?? "Codex session"
        let projectPath = JSONHelpers.string(in: dictionary, keys: ["cwd", "projectPath", "project_path"])
        let updatedAt = JSONHelpers.date(in: dictionary, keys: ["updated_at_ms", "updated_at", "timestamp"]) ?? Date()
        let (state, confidence, pid) = SessionClassifier.classify(
            harness: .codex,
            tailObjects: [dictionary],
            tailText: JSONHelpers.flatten(dictionary),
            modifiedAt: updatedAt,
            processes: processes
        )

        return AgentSession(
            id: "codex-\(id)",
            harness: .codex,
            title: title,
            detail: projectDetail(projectPath) ?? "Codex",
            projectPath: projectPath,
            model: JSONHelpers.string(in: dictionary, keys: ["model"]),
            state: state,
            updatedAt: updatedAt,
            sourcePath: sourcePath,
            processID: pid,
            confidence: confidence
        )
    }

    private func scanClaude(processes: [RunningProcess]) -> [AgentSession] {
        var sessions = enableCLIProbes ? scanClaudeAgentsCLI(processes: processes) : []
        let root = homeDirectory.appendingPathComponent(".claude/projects")
        sessions += FileUtilities.recentFiles(
            under: root,
            extensions: ["jsonl"],
            maxFiles: maxSessionsPerHarness
        )
        .map { file in
            sessionFromFile(harness: .claude, file: file, processes: processes, fallbackTitle: "Claude Code session")
        }

        return Array(sessions.prefix(maxSessionsPerHarness))
    }

    private func scanClaudeAgentsCLI(processes: [RunningProcess]) -> [AgentSession] {
        guard let executable = CommandRunner.firstExecutable(named: "claude") else {
            return []
        }

        guard let result = CommandRunner.run(
            executable,
            arguments: ["agents", "--json"],
            timeout: 4
        ), result.exitCode == 0 else {
            return []
        }

        guard let json = JSONHelpers.object(from: result.stdout) else {
            return []
        }

        let rows: [Any]
        if let array = json as? [Any] {
            rows = array
        } else if let dictionary = json as? [String: Any] {
            rows = (dictionary["agents"] as? [Any])
                ?? (dictionary["sessions"] as? [Any])
                ?? []
        } else {
            rows = []
        }

        return rows.compactMap { object in
            guard let dictionary = object as? [String: Any] else {
                return nil
            }

            let id = JSONHelpers.string(in: dictionary, keys: ["id", "sessionId", "session_id", "uuid"]) ?? UUID().uuidString
            let title = TranscriptSummary.cleanTitle(
                JSONHelpers.string(in: dictionary, keys: ["title", "summary", "name", "prompt"])
            ) ?? "Claude Code session"
            let projectPath = JSONHelpers.string(in: dictionary, keys: ["cwd", "projectPath", "project_path", "workspace"])
            let updatedAt = JSONHelpers.date(
                in: dictionary,
                keys: ["updatedAt", "updated_at", "lastUpdated", "timestamp", "time"]
            ) ?? Date()
            let rawState = JSONHelpers.string(in: dictionary, keys: ["state", "status"])
            let waitingFor = JSONHelpers.string(in: dictionary, keys: ["waitingFor", "waiting_for", "reason"])
            let state = claudeState(rawState: rawState, waitingFor: waitingFor)
            let processID = processes.first { $0.matches(.claude) }?.pid

            return AgentSession(
                id: "claude-\(id)",
                harness: .claude,
                title: title,
                detail: projectDetail(projectPath) ?? (waitingFor ?? "Claude Code"),
                projectPath: projectPath,
                model: JSONHelpers.string(in: dictionary, keys: ["model", "modelId"]),
                state: state,
                updatedAt: updatedAt,
                sourcePath: executable.path,
                processID: processID,
                confidence: .live
            )
        }
    }

    private func scanCopilot(processes: [RunningProcess]) -> [AgentSession] {
        let roots = [
            homeDirectory.appendingPathComponent(".copilot/session-state"),
            homeDirectory.appendingPathComponent(".copilot/history-session-state")
        ]

        var sessions: [AgentSession] = []
        for root in roots where FileUtilities.existingDirectory(root) {
            let sessionDirectories = FileUtilities.directoryChildren(root)
                .filter { url in
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    return values?.isDirectory == true
                }
                .sorted {
                    FileUtilities.fileModificationDate($0) > FileUtilities.fileModificationDate($1)
                }
                .prefix(maxSessionsPerHarness)

            for directory in sessionDirectories {
                sessions.append(copilotSession(directory: directory, processes: processes))
            }
        }

        return Array(sessions.prefix(maxSessionsPerHarness))
    }

    private func scanAtollFrames(processes: [RunningProcess]) -> [AgentSession] {
        let root = homeDirectory.appendingPathComponent(".atoll/sessions")
        return FileUtilities.recentFiles(
            under: root,
            extensions: ["json", "jsonl"],
            maxFiles: maxSessionsPerHarness
        )
        .compactMap { file in
            let lines = FileUtilities.tailLines(from: file.url, maxLines: 10)
            let object = lines.compactMap(JSONHelpers.object).last
                ?? (try? Data(contentsOf: file.url)).flatMap(JSONHelpers.object)
            guard let object else {
                return nil
            }

            let harnessRaw = JSONHelpers.string(in: object, keys: ["harness", "agent"]) ?? "atoll"
            let harness = AgentHarness(rawValue: harnessRaw.lowercased()) ?? .atoll
            let id = JSONHelpers.string(in: object, keys: ["id", "sessionId", "session_id"]) ?? file.url.deletingPathExtension().lastPathComponent
            let title = TranscriptSummary.cleanTitle(
                JSONHelpers.string(in: object, keys: ["title", "summary", "prompt"])
            ) ?? "\(harness.displayName) session"
            let updatedAt = JSONHelpers.date(in: object, keys: ["updatedAt", "updated_at", "timestamp"]) ?? file.modifiedAt
            let state = JSONHelpers.string(in: object, keys: ["state", "status"]).flatMap { SessionState(rawValue: $0) }
            let projectPath = JSONHelpers.string(in: object, keys: ["cwd", "projectPath", "project_path"])
            let (inferredState, confidence, pid) = SessionClassifier.classify(
                harness: harness,
                tailObjects: [object],
                tailText: JSONHelpers.flatten(object),
                modifiedAt: updatedAt,
                processes: processes
            )

            return AgentSession(
                id: "\(harness.rawValue)-\(id)",
                harness: harness,
                title: title,
                detail: projectDetail(projectPath) ?? harness.displayName,
                projectPath: projectPath,
                model: JSONHelpers.string(in: object, keys: ["model", "modelId"]),
                state: state ?? inferredState,
                updatedAt: updatedAt,
                sourcePath: file.url.path,
                processID: pid,
                confidence: state == nil ? confidence : .live
            )
        }
    }

    private func scanPi(processes: [RunningProcess]) -> [AgentSession] {
        let root = homeDirectory.appendingPathComponent(".pi/agent/sessions")
        return FileUtilities.recentFiles(
            under: root,
            extensions: ["jsonl"],
            maxFiles: maxSessionsPerHarness
        )
        .map { file in
            sessionFromFile(harness: .pi, file: file, processes: processes, fallbackTitle: "Pi session")
        }
    }

    private func sessionFromFile(
        harness: AgentHarness,
        file: RecentFile,
        processes: [RunningProcess],
        fallbackTitle: String
    ) -> AgentSession {
        if file.url.pathExtension.lowercased() == "json",
           let data = try? Data(contentsOf: file.url),
           data.count < 2_000_000,
           let object = JSONHelpers.object(from: data) {
            return structuredSession(
                harness: harness,
                object: object,
                file: file,
                processes: processes,
                fallbackTitle: fallbackTitle
            )
        }

        return transcriptSession(
            harness: harness,
            file: file,
            processes: processes,
            fallbackTitle: fallbackTitle
        )
    }

    private func structuredSession(
        harness: AgentHarness,
        object: Any,
        file: RecentFile,
        processes: [RunningProcess],
        fallbackTitle: String
    ) -> AgentSession {
        let id = JSONHelpers.string(
            in: object,
            keys: ["sessionId", "session_id", "id", "uuid"]
        ) ?? file.url.deletingPathExtension().lastPathComponent
        let title = TranscriptSummary.cleanTitle(
            JSONHelpers.string(in: object, keys: ["title", "summary", "name", "prompt"])
        ) ?? fallbackTitle
        let projectPath = JSONHelpers.string(
            in: object,
            keys: ["cwd", "projectPath", "project_path", "workspace", "path", "directory"]
        )
        let updatedAt = JSONHelpers.date(
            in: object,
            keys: ["updatedAt", "updated_at", "lastUpdated", "timestamp", "time"]
        ) ?? file.modifiedAt
        let text = JSONHelpers.flatten(object)
        let (state, confidence, pid) = SessionClassifier.classify(
            harness: harness,
            tailObjects: [object],
            tailText: text,
            modifiedAt: updatedAt,
            processes: processes
        )

        return AgentSession(
            id: "\(harness.rawValue)-\(id)",
            harness: harness,
            title: title,
            detail: projectDetail(projectPath) ?? harness.displayName,
            projectPath: projectPath,
            model: JSONHelpers.string(in: object, keys: ["model", "modelId", "model_id"]),
            state: state,
            updatedAt: updatedAt,
            sourcePath: file.url.path,
            processID: pid,
            confidence: confidence
        )
    }

    private func transcriptSession(
        harness: AgentHarness,
        file: RecentFile,
        processes: [RunningProcess],
        fallbackTitle: String
    ) -> AgentSession {
        let summary = TranscriptSummary.fromJSONLines(url: file.url, fallbackModifiedAt: file.modifiedAt)
        let id = summary.sessionID ?? file.url.deletingPathExtension().lastPathComponent
        let title = summary.title ?? fallbackTitle
        let projectPath = summary.projectPath ?? inferredProjectPath(for: harness, file: file.url)
        let (state, confidence, pid) = SessionClassifier.classify(
            harness: harness,
            tailObjects: summary.tailObjects,
            tailText: summary.tailText,
            modifiedAt: summary.updatedAt ?? file.modifiedAt,
            processes: processes
        )

        return AgentSession(
            id: "\(harness.rawValue)-\(id)",
            harness: harness,
            title: title,
            detail: projectDetail(projectPath) ?? harness.displayName,
            projectPath: projectPath,
            model: summary.model,
            state: state,
            updatedAt: summary.updatedAt ?? file.modifiedAt,
            startedAt: summary.startedAt,
            sourcePath: file.url.path,
            processID: pid,
            confidence: confidence
        )
    }

    private func copilotSession(directory: URL, processes: [RunningProcess]) -> AgentSession {
        let sessionID = directory.lastPathComponent
        let eventLog = directory.appendingPathComponent("events.jsonl")
        let file = RecentFile(
            url: eventLog,
            modifiedAt: FileUtilities.fileModificationDate(eventLog) != .distantPast
                ? FileUtilities.fileModificationDate(eventLog)
                : FileUtilities.fileModificationDate(directory)
        )
        let summary = FileUtilities.isRegularFile(eventLog)
            ? TranscriptSummary.fromJSONLines(url: eventLog, fallbackModifiedAt: file.modifiedAt)
            : TranscriptSummary(
                sessionID: sessionID,
                title: nil,
                projectPath: nil,
                model: nil,
                startedAt: nil,
                updatedAt: file.modifiedAt,
                tailObjects: [],
                tailText: ""
        )
        let workspace = workspaceMetadata(in: directory)
        let (state, confidence, pid) = SessionClassifier.classify(
            harness: .copilot,
            tailObjects: summary.tailObjects,
            tailText: summary.tailText + " " + workspace.rawText,
            modifiedAt: summary.updatedAt ?? file.modifiedAt,
            processes: processes
        )
        let title = summary.title ?? workspace.title ?? "Copilot session"
        let projectPath = summary.projectPath ?? workspace.projectPath

        return AgentSession(
            id: "copilot-\(summary.sessionID ?? sessionID)",
            harness: .copilot,
            title: title,
            detail: projectDetail(projectPath) ?? "GitHub Copilot",
            projectPath: projectPath,
            model: summary.model,
            state: state,
            updatedAt: summary.updatedAt ?? file.modifiedAt,
            startedAt: summary.startedAt,
            sourcePath: directory.path,
            processID: pid,
            confidence: confidence
        )
    }

    private func workspaceMetadata(in directory: URL) -> (title: String?, projectPath: String?, rawText: String) {
        let yaml = directory.appendingPathComponent("workspace.yaml")
        guard let data = try? Data(contentsOf: yaml), let text = String(data: data, encoding: .utf8) else {
            return (nil, nil, "")
        }

        var title: String?
        var projectPath: String?

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].lowercased()
            let value = parts[1]
            if ["name", "summary", "title", "repository"].contains(key), title == nil {
                title = TranscriptSummary.cleanTitle(value)
            }
            if ["cwd", "path", "workspace", "workspacefolder", "repositoryroot"].contains(key), projectPath == nil {
                projectPath = value
            }
        }

        return (title, projectPath, text)
    }

    private func copilotLockPID(in directory: URL, processes: [RunningProcess]) -> Int32? {
        for url in FileUtilities.directoryChildren(directory) {
            let name = url.lastPathComponent
            guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else {
                continue
            }

            let trimmed = name
                .replacingOccurrences(of: "inuse.", with: "")
                .replacingOccurrences(of: ".lock", with: "")
            guard let pid = Int32(trimmed) else {
                continue
            }

            let lockIsFresh = Date().timeIntervalSince(FileUtilities.fileModificationDate(url)) < SessionClassifier.activeWindow
            let pidIsAlive = processes.contains { $0.pid == pid }
            if lockIsFresh || pidIsAlive {
                return pid
            }
        }

        return nil
    }

    private func copilotPlanState(in directory: URL) -> (waitingForReview: Bool, text: String) {
        let plan = directory.appendingPathComponent("plan.md")
        guard FileUtilities.isRegularFile(plan),
              let data = try? Data(contentsOf: plan),
              let text = String(data: Data(data.prefix(64_000)), encoding: .utf8) else {
            return (false, "")
        }

        let isRecent = Date().timeIntervalSince(FileUtilities.fileModificationDate(plan)) < SessionClassifier.activeWindow
        return (isRecent, text)
    }

    private func sqliteRows(database: URL, query: String) -> [Any]? {
        guard let sqlite = CommandRunner.firstExecutable(named: "sqlite3") else {
            return nil
        }

        guard let result = CommandRunner.run(
            sqlite,
            arguments: ["-readonly", "-json", database.path, query],
            timeout: 2
        ), result.exitCode == 0 else {
            return nil
        }

        return JSONHelpers.object(from: result.stdout) as? [Any]
    }

    private func modelName(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else {
            return nil
        }

        if let object = JSONHelpers.object(from: raw) {
            return JSONHelpers.string(in: object, keys: ["id", "model", "name"]) ?? raw
        }

        return raw
    }

    private func claudeState(rawState: String?, waitingFor: String?) -> SessionState {
        let state = (rawState ?? "").lowercased()
        let waiting = (waitingFor ?? "").lowercased()

        if waiting.contains("permission") || waiting.contains("approval") || waiting.contains("tool") {
            return .waitingForPermission
        }
        if waiting.contains("input") || waiting.contains("question") || waiting.contains("user") {
            return .waitingForInput
        }
        if state.contains("blocked") || state.contains("waiting") {
            return waiting.isEmpty ? .waitingForInput : .waitingForPermission
        }
        if state.contains("working") || state.contains("running") || state.contains("busy") {
            return .running
        }
        if state.contains("done") || state.contains("stopped") || state.contains("failed") {
            return .done
        }
        return .unknown
    }

    private func inferredProjectPath(for harness: AgentHarness, file: URL) -> String? {
        switch harness {
        case .claude:
            let project = file.deletingLastPathComponent().lastPathComponent
            let decoded = project.replacingOccurrences(of: "-", with: "/")
            return decoded.hasPrefix("/") ? decoded : nil
        default:
            return nil
        }
    }

    private func projectDetail(_ projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: projectPath)
        if !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return projectPath
    }

    private func deduplicate(_ sessions: [AgentSession]) -> [AgentSession] {
        var seen: Set<String> = []
        var result: [AgentSession] = []

        for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let key = "\(session.harness.rawValue)-\(session.id)"
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(session)
        }

        return result
    }
}
