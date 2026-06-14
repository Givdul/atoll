import XCTest
@testable import AtollCore

final class AgentSessionScannerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtollTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    func testScansCodexPermissionWait() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/11", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-test.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-1","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"approval_requested","reason":"run tests"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .waitingForPermission)
    }

    func testScansClaudeQuestionWait() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".claude/projects/-tmp-example", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("claude-1.jsonl")
        try """
        {"type":"user","sessionId":"claude-1","cwd":"/tmp/example","message":{"role":"user","content":"Build the app"},"timestamp":"\(now)"}
        {"type":"event","payload":{"type":"request_user_input","question":"Which option should I use?"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .claude)
        XCTAssertEqual(sessions[0].state, .waitingForInput)
    }

    func testScansCopilotExplicitStartHookAsLive() throws {
        let directory = tempHome.appendingPathComponent(".copilot/session-state/copilot-1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"copilot-1","content":"Fix auth","timestamp":"2026-06-11T10:00:00Z"}
        {"type":"agent_turn_started","sessionId":"copilot-1","timestamp":"2026-06-11T10:00:01Z"}
        """.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .copilot)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .live)
    }

    func testScansOpenCodeAssistantStartHook() throws {
        try makeOpenCodeDatabase(
            sessionID: "ses-running",
            title: "Explore codebase structure (@explore subagent)",
            events: [
                openCodeEvent(
                    sessionID: "ses-running",
                    seq: 1,
                    type: "message.updated.1",
                    data: """
                    {"sessionID":"ses-running","info":{"id":"msg-1","sessionID":"ses-running","role":"assistant","time":{"created":\(millisecondsSinceEpoch())},"modelID":"qwen3.7-plus","providerID":"opencode-go"}}
                    """
                )
            ]
        )

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .opencode)
        XCTAssertEqual(sessions[0].title, "Explore codebase structure (@explore subagent)")
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .live)
    }

    func testOpenCodeToolPartAloneDoesNotStartSession() throws {
        try makeOpenCodeDatabase(
            sessionID: "ses-tool-part",
            title: "Tool part only",
            events: [
                openCodeEvent(
                    sessionID: "ses-tool-part",
                    seq: 1,
                    type: "message.part.updated.1",
                    data: """
                    {"sessionID":"ses-tool-part","part":{"id":"prt-1","sessionID":"ses-tool-part","messageID":"msg-1","type":"tool","tool":"read","state":{"status":"running","input":{},"time":{"start":\(millisecondsSinceEpoch())}}},"time":\(millisecondsSinceEpoch())}
                    """
                )
            ]
        )

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .opencode)
        XCTAssertEqual(sessions[0].state, .done)
        XCTAssertEqual(sessions[0].confidence, .historical)
    }

    func testOpenCodeCompletedPartDoesNotStayRunning() throws {
        let completedAt = millisecondsSinceEpoch(offset: -20)
        try makeOpenCodeDatabase(
            sessionID: "ses-complete",
            title: "Completed OpenCode session",
            updatedAt: completedAt,
            events: [
                openCodeEvent(
                    sessionID: "ses-complete",
                    seq: 1,
                    type: "message.updated.1",
                    data: """
                    {"sessionID":"ses-complete","info":{"id":"msg-1","sessionID":"ses-complete","role":"assistant","time":{"created":\(millisecondsSinceEpoch(offset: -25)),"completed":\(completedAt)},"modelID":"qwen3.7-plus","providerID":"opencode-go"}}
                    """
                )
            ]
        )

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .opencode)
        XCTAssertEqual(sessions[0].state, .done)
        XCTAssertEqual(sessions[0].confidence, .historical)
    }

    func testSettingsDecodeDefaultsTestModeForExistingConfigs() throws {
        let data = """
        {"enabled":false,"includeCompleted":true,"screenMode":"primary"}
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AtollSettings.self, from: data)

        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.testMode)
    }

    private func testScanner() -> AgentSessionScanner {
        AgentSessionScanner(
            homeDirectory: tempHome,
            enableCLIProbes: false,
            processProvider: { [] }
        )
    }

    private func makeOpenCodeDatabase(
        sessionID: String,
        title: String,
        updatedAt: Int64? = nil,
        events: [String]
    ) throws {
        guard let sqlite = CommandRunner.firstExecutable(named: "sqlite3") else {
            throw XCTSkip("sqlite3 is unavailable")
        }

        let directory = tempHome.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("opencode.db")
        let timestamp = updatedAt ?? millisecondsSinceEpoch()
        let sql = """
        create table session (
            id text primary key,
            title text,
            directory text,
            path text,
            time_updated integer,
            time_created integer,
            time_archived integer,
            model text,
            agent text,
            permission text
        );
        create table event (
            id text primary key,
            aggregate_id text not null,
            seq integer not null,
            type text not null,
            data text not null
        );
        insert into session (id, title, directory, path, time_updated, time_created, time_archived, model, agent, permission)
        values ('\(sessionID)', '\(title)', '/tmp/example', '', \(timestamp), \(timestamp), null, '{"id":"qwen3.7-plus","providerID":"opencode-go"}', 'explore', '[]');
        \(events.joined(separator: "\n"))
        """

        let result = CommandRunner.run(sqlite, arguments: [database.path, sql], timeout: 2)
        XCTAssertEqual(result?.exitCode, 0, result?.stderr ?? "")
    }

    private func openCodeEvent(sessionID: String, seq: Int, type: String, data: String) -> String {
        let escapedData = data.replacingOccurrences(of: "'", with: "''")
        return """
        insert into event (id, aggregate_id, seq, type, data)
        values ('evt-\(seq)', '\(sessionID)', \(seq), '\(type)', '\(escapedData)');
        """
    }

    private func millisecondsSinceEpoch(offset: TimeInterval = 0) -> Int64 {
        Int64(Date().addingTimeInterval(offset).timeIntervalSince1970 * 1_000)
    }
}
