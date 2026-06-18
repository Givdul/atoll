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

    func testScansCodexRequestUserInputWait() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/11", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-input-wait.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-input-wait","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"question\\":\\"Which path should I take?\\"}"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .waitingForInput)
    }

    func testCodexToolMetadataDoesNotTriggerInputWait() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/11", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-tool-metadata.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-tool-metadata","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(now)"}
        {"type":"turn_context","tools":[{"name":"request_user_input","description":"Ask the user a question"}],"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .running)
    }

    func testCodexQuestionTextDoesNotTriggerInputWait() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/11", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-question-text.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-question-text","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(now)"}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":"I am checking the question path before continuing."},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .running)
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

    func testCodexTranscriptExtractsPromptAndLastToolCall() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-activity.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-activity","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"user_message","role":"user","content":"Make all harnesses visible","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"function_call","name":"exec_command"},"timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].prompt, "Make all harnesses visible")
        XCTAssertEqual(sessions[0].lastToolCall, "Shell")
    }

    func testCodexTurnAbortedDoesNotStayRunningOrUseSyntheticPrompt() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-aborted.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-aborted","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"user_message","role":"user","content":"Run the build","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"function_call","name":"exec_command"},"timestamp":"\(now)"}
        {"type":"response_item","payload":{"type":"message","role":"user","content":"<turn_aborted>"},"timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_aborted"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .done)
        XCTAssertEqual(sessions[0].prompt, "Run the build")
        XCTAssertEqual(sessions[0].lastToolCall, "Shell")
    }

    func testCodexStaleRunningTranscriptBecomesHistorical() throws {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-(SessionClassifier.activeWindow + 60)))
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-stale-running.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-stale","cwd":"/tmp/example","timestamp":"\(old)"}
        {"type":"user_message","role":"user","content":"Inspect the issue","timestamp":"\(old)"}
        {"type":"event_msg","payload":{"type":"function_call","name":"exec_command"},"timestamp":"\(old)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(old)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .historical)
    }

    func testCodexStaleRunningIndexRowBecomesHistorical() throws {
        let directory = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldMilliseconds = Int64(Date().addingTimeInterval(-(SessionClassifier.activeWindow + 60)).timeIntervalSince1970 * 1_000)
        let index = directory.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"codex-index-stale","title":"Old running index row","cwd":"/tmp/example","type":"turn_started","updated_at_ms":\(oldMilliseconds)}
        """.write(to: index, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .historical)
    }

    func testScansCopilotExplicitStartHookAsLive() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".copilot/session-state/copilot-1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"copilot-1","content":"Fix auth","timestamp":"\(now)"}
        {"type":"agent_turn_started","sessionId":"copilot-1","timestamp":"\(now)"}
        """.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .copilot)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .inferred)
    }

    func testStaleCopilotTranscriptDoesNotBecomeLiveFromGenericHarnessProcess() throws {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-(SessionClassifier.activeWindow + 60)))
        let directory = tempHome.appendingPathComponent(".copilot/session-state/copilot-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"copilot-stale","content":"Fix auth","timestamp":"\(old)"}
        {"type":"agent_turn_started","sessionId":"copilot-stale","timestamp":"\(old)"}
        """.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner(processes: [
            RunningProcess(pid: 42, command: "copilot", arguments: "copilot")
        ]).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .copilot)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .historical)
    }

    func testHookOnlyScanIgnoresCopilotHistoryQuestion() throws {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-99 * 60 * 60))
        let directory = tempHome.appendingPathComponent(".copilot/history-session-state/copilot-old-question", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"copilot-old-question","content":"Old task","timestamp":"\(old)"}
        {"type":"request_user_input","sessionId":"copilot-old-question","question":"Continue?","timestamp":"\(old)"}
        """.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner(scanMode: .hookEventsOnly).scan()

        XCTAssertTrue(sessions.isEmpty)
    }

    func testHookOnlyScanIncludesFreshCopilotSessionStateEvent() throws {
        let cutoff = Date().addingTimeInterval(-1)
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".copilot/session-state/copilot-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        {"type":"user","sessionId":"copilot-fresh","content":"Fix auth","timestamp":"\(now)"}
        {"type":"agent_turn_started","sessionId":"copilot-fresh","timestamp":"\(now)"}
        """.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner(scanMode: .hookEventsOnly, atollFrameNotBefore: cutoff).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "copilot-copilot-fresh")
        XCTAssertEqual(sessions[0].state, .running)
    }

    func testHookOnlyScanIncludesFreshCodexTranscriptEvent() throws {
        let cutoff = Date().addingTimeInterval(-1)
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-hook-only.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-hook-only","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner(scanMode: .hookEventsOnly, atollFrameNotBefore: cutoff).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "codex-codex-hook-only")
        XCTAssertEqual(sessions[0].state, .running)
    }

    func testFreshCodexTranscriptCanUseGenericHarnessProcessAsLiveEvidence() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".codex/sessions/2026/06/16", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-live-process.jsonl")
        try """
        {"type":"session_meta","session_id":"codex-live-process","cwd":"/tmp/example","timestamp":"\(now)"}
        {"type":"event_msg","payload":{"type":"turn_started"},"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner(processes: [
            RunningProcess(pid: 43, command: "codex", arguments: "codex")
        ]).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .codex)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .live)
    }

    func testScansRunningPiProcessWithoutSessionStore() throws {
        let sessions = testScanner(processes: [
            RunningProcess(pid: 42, command: "pi", arguments: "pi")
        ]).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].confidence, .live)
        XCTAssertEqual(sessions[0].processID, 42)
    }

    func testPiProcessMatchingDoesNotTreatPipAsPi() throws {
        let sessions = testScanner(processes: [
            RunningProcess(pid: 43, command: "pip", arguments: "pip install package")
        ]).scan()

        XCTAssertTrue(sessions.isEmpty)
    }

    func testPiTranscriptExtractsPromptToolAndRunningState() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".pi/agent/sessions/--tmp-example--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-activity.jsonl")
        try """
        {"type":"session","version":3,"id":"pi-activity","timestamp":"\(now)","cwd":"/tmp/example"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"\(now)","message":{"role":"user","content":"Inspect the Pi store","timestamp":\(millisecondsSinceEpoch(offset: -2))}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"\(now)","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"ls"}}],"provider":"anthropic","model":"claude-sonnet-4-5","stopReason":"toolUse","timestamp":\(millisecondsSinceEpoch(offset: -1))}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].prompt, "Inspect the Pi store")
        XCTAssertEqual(sessions[0].lastToolCall, "Shell")
        XCTAssertEqual(sessions[0].detail, "example")
        XCTAssertEqual(sessions[0].model, "claude-sonnet-4-5")
    }

    func testPiStartedAtTracksLatestPromptInsteadOfOriginalSessionStart() throws {
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-39 * 60))
        let directory = tempHome.appendingPathComponent(".pi/agent/sessions/--tmp-example-latest-work--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-latest-work.jsonl")
        let latestUserPromptAt = millisecondsSinceEpoch(offset: -3)
        let latestToolStartAt = millisecondsSinceEpoch(offset: -1)
        try """
        {"type":"session","version":3,"id":"pi-latest-work","timestamp":"\(old)","cwd":"/tmp/example"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"\(old)","message":{"role":"user","content":"Old request","timestamp":"\(millisecondsSinceEpoch(offset: -39 * 60))"}}
        {"type":"message","id":"u2","parentId":"a1","timestamp":"\(Date().ISO8601Format())","message":{"role":"user","content":"Do the next step","timestamp":\(latestUserPromptAt)}}
        {"type":"message","id":"a2","parentId":"u2","timestamp":"\(Date().ISO8601Format())","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-2","name":"bash","arguments":{"command":"ls"}}],"provider":"anthropic","model":"claude-sonnet-4-5","stopReason":"toolUse","timestamp":\(latestToolStartAt)}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertNotNil(sessions[0].startedAt)
        XCTAssertGreaterThanOrEqual(sessions[0].startedAt!, Date().addingTimeInterval(-10))
    }

    func testPiCompletedTranscriptDoesNotFallBackToProcessRunning() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".pi/agent/sessions/--tmp-example--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-complete.jsonl")
        try """
        {"type":"session","version":3,"id":"pi-complete","timestamp":"\(now)","cwd":"/tmp/example"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"\(now)","message":{"role":"user","content":"Finish the change","timestamp":\(millisecondsSinceEpoch(offset: -2))}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"\(now)","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"provider":"anthropic","model":"claude-sonnet-4-5","stopReason":"stop","timestamp":\(millisecondsSinceEpoch(offset: -1))}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner(processes: [
            RunningProcess(pid: 42, command: "pi", arguments: "pi")
        ]).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .done)
        XCTAssertEqual(sessions[0].processID, 42)
        XCTAssertTrue(sessions[0].sourcePath.hasSuffix("/.pi/agent/sessions/--tmp-example--/pi-complete.jsonl"))
    }

    func testPiAgentEndHookOverridesPriorToolCall() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".atoll/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-hook-agent-end.jsonl")
        try """
        {"harness":"pi","sessionId":"pi-hook-agent-end","type":"prompt","message":"Fix the Pi done hook","timestamp":"\(now)"}
        {"harness":"pi","sessionId":"pi-hook-agent-end","type":"tool_call","toolName":"bash","input":{"command":"swift test"},"timestamp":"\(now)"}
        {"harness":"pi","sessionId":"pi-hook-agent-end","type":"agent_end","messages":[],"timestamp":"\(now)"}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .done)
        XCTAssertEqual(sessions[0].prompt, "Fix the Pi done hook")
        XCTAssertEqual(sessions[0].lastToolCall, "Shell")
    }

    func testPiWaitingForQuestionFromInstalledAskPackage() throws {
        let package = "npm:@pi/ask-user@1.2.3"
        try writePiPackage(
            packagePath: package,
            extensionPaths: ["dist/ask.js": "pi.registerTool({ name: 'ask_user_question', title: 'Ask user' })"]
        )
        try writePiSettings(packages: [["id": package]])

        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".pi/agent/sessions/--tmp-example-question--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-question.jsonl")
        try """
        {"type":"session","version":3,"id":"pi-question","timestamp":"\(now)","cwd":"/tmp/example"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"\(now)","message":{"role":"user","content":"Need help choosing a path","timestamp":\(millisecondsSinceEpoch(offset: -2))}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"\(now)","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc1","name":"ask_user_question","arguments":{"question":"Which branch?"}}],"provider":"anthropic","model":"claude-sonnet-4-5","stopReason":"toolUse","timestamp":\(millisecondsSinceEpoch(offset: -1))}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .waitingForInput)
    }

    func testPiWaitingForPermissionFromGuardrailsPlugin() throws {
        let package = "npm:@pi/guardrails@3.0.0"
        try writePiPackage(
            packagePath: package,
            extensionPaths: ["lib/guardrail.js": "pi.registerTool({ name: 'guardrails:action:prompted', description: 'ask permission' })"]
        )
        try writePiSettings(packages: [["id": package]])

        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".pi/agent/sessions/--tmp-example-permission--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pi-permission.jsonl")
        try """
        {"type":"session","version":3,"id":"pi-permission","timestamp":"\(now)","cwd":"/tmp/example"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"\(now)","message":{"role":"user","content":"Run this risky command","timestamp":\(millisecondsSinceEpoch(offset: -2))}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"\(now)","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc1","name":"guardrails:action:prompted","arguments":{"permission":"run_risky_command"}}],"provider":"anthropic","model":"claude-sonnet-4-5","stopReason":"toolUse","timestamp":\(millisecondsSinceEpoch(offset: -1))}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .pi)
        XCTAssertEqual(sessions[0].state, .waitingForPermission)
    }

    func testAtollFramesSupportKnownHarnessesWithPromptAndToolCall() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let directory = tempHome.appendingPathComponent(".atoll/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harnesses: [(String, AgentHarness)] = [
            ("claude-code", .claude),
            ("codex-cli", .codex),
            ("gemini-cli", .gemini),
            ("cursor-agent", .cursor),
            ("opencode", .opencode),
            ("factory-droid", .droid),
            ("qoder", .qoder),
            ("qwen", .qwen),
            ("kimi-code", .kimi),
            ("deepseek", .deepseek),
            ("copilot", .copilot),
            ("codebuddy", .codebuddy),
            ("kiro", .kiro),
            ("hermes", .hermes),
            ("amp", .amp),
            ("pi", .pi)
        ]

        for (rawHarness, _) in harnesses {
            let file = directory.appendingPathComponent("\(rawHarness).jsonl")
            try """
            {"harness":"\(rawHarness)","sessionId":"\(rawHarness)-1","prompt":"Fix \(rawHarness) support","state":"running","timestamp":"\(now)"}
            {"harness":"\(rawHarness)","sessionId":"\(rawHarness)-1","type":"beforeShellExecution","command":"swift test","timestamp":"\(now)"}
            """.write(to: file, atomically: true, encoding: .utf8)
        }

        let sessions = testScanner().scan()
        let byHarness = Dictionary(uniqueKeysWithValues: sessions.map { ($0.harness, $0) })

        XCTAssertEqual(sessions.count, harnesses.count)
        for (rawHarness, harness) in harnesses {
            let session = try XCTUnwrap(byHarness[harness])
            XCTAssertEqual(session.state, .running, rawHarness)
            XCTAssertEqual(session.prompt, "Fix \(rawHarness) support", rawHarness)
            XCTAssertEqual(session.lastToolCall, "Shell", rawHarness)
        }
    }

    func testAtollFramesCanIgnoreEventsBeforeLaunchCutoff() throws {
        let formatter = ISO8601DateFormatter()
        let cutoff = Date()
        let old = formatter.string(from: cutoff.addingTimeInterval(-10))
        let fresh = formatter.string(from: cutoff.addingTimeInterval(10))
        let directory = tempHome.appendingPathComponent(".atoll/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try """
        {"harness":"codex","sessionId":"old","prompt":"Old hook event","state":"running","timestamp":"\(old)"}
        """.write(to: directory.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"harness":"codex","sessionId":"fresh","prompt":"Fresh hook event","state":"running","timestamp":"\(fresh)"}
        """.write(to: directory.appendingPathComponent("fresh.jsonl"), atomically: true, encoding: .utf8)

        let sessions = testScanner(atollFrameNotBefore: cutoff).scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "codex-fresh")
        XCTAssertEqual(sessions[0].prompt, "Fresh hook event")
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

    func testOpenCodeRunningSessionShowsLastToolAndPrompt() throws {
        try makeOpenCodeDatabase(
            sessionID: "ses-activity",
            title: "OpenCode activity",
            events: [
                openCodeEvent(
                    sessionID: "ses-activity",
                    seq: 1,
                    type: "message.updated.1",
                    data: """
                    {"sessionID":"ses-activity","info":{"id":"msg-user","sessionID":"ses-activity","role":"user","content":"Inspect the workspace","time":{"created":\(millisecondsSinceEpoch(offset: -3))}}}
                    """
                ),
                openCodeEvent(
                    sessionID: "ses-activity",
                    seq: 2,
                    type: "message.updated.1",
                    data: """
                    {"sessionID":"ses-activity","info":{"id":"msg-assistant","sessionID":"ses-activity","role":"assistant","time":{"created":\(millisecondsSinceEpoch(offset: -2))},"modelID":"qwen3.7-plus","providerID":"opencode-go"}}
                    """
                ),
                openCodeEvent(
                    sessionID: "ses-activity",
                    seq: 3,
                    type: "message.part.updated.1",
                    data: """
                    {"sessionID":"ses-activity","part":{"id":"prt-1","sessionID":"ses-activity","messageID":"msg-assistant","type":"tool","tool":"read","state":{"status":"running","input":{"filePath":"Package.swift"},"time":{"start":\(millisecondsSinceEpoch(offset: -1))}}},"time":\(millisecondsSinceEpoch(offset: -1))}
                    """
                )
            ]
        )

        let sessions = testScanner().scan()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].harness, .opencode)
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[0].prompt, "Inspect the workspace")
        XCTAssertEqual(sessions[0].lastToolCall, "Read")
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

    private func writePiSettings(packages: [Any]) throws {
        let directory = tempHome.appendingPathComponent(".pi/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = ["packages": packages]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: directory.appendingPathComponent("settings.json"))
    }

    private func writePiPackage(packagePath: String, extensionPaths: [String: String]) throws {
        let packageDirectory = tempHome
            .appendingPathComponent(".pi/agent/npm/node_modules")
            .appendingPathComponent(normalizedPiPackagePath(from: packagePath))
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        let extensions = extensionPaths.keys
            .sorted()
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        let packageJSON = """
        {
            "name": "\(packagePath)",
            "pi": {
                "extensions": [\(extensions)]
            }
        }
        """
        try packageJSON.data(using: .utf8)!.write(to: packageDirectory.appendingPathComponent("package.json"))

        for (path, content) in extensionPaths {
            let file = packageDirectory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func normalizedPiPackagePath(from packagePath: String) -> String {
        let packageID = packagePath.hasPrefix("npm:") ? String(packagePath.dropFirst(4)) : packagePath
        if !packageID.hasPrefix("@") {
            return packageID
        }
        let components = packageID.split(separator: "@", omittingEmptySubsequences: false)
        if components.count > 2 {
            return components.dropLast().joined(separator: "@")
        }
        return packageID
    }

    private func testScanner(
        processes: [RunningProcess] = [],
        scanMode: AgentSessionScanMode = .allSources,
        atollFrameNotBefore: Date? = nil
    ) -> AgentSessionScanner {
        AgentSessionScanner(
            homeDirectory: tempHome,
            enableCLIProbes: false,
            scanMode: scanMode,
            atollFrameNotBefore: atollFrameNotBefore,
            processProvider: { processes }
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
