import Foundation

enum SessionClassifier {
    static let activeWindow: TimeInterval = 30 * 60

    static func classify(
        harness: AgentHarness,
        tailObjects: [Any],
        tailText: String,
        modifiedAt: Date,
        processes: [RunningProcess],
        lockPID: Int32? = nil
    ) -> (SessionState, SessionConfidence, Int32?) {
        let harnessProcesses = processes.filter { $0.matches(harness) }
        let processID = lockPID ?? harnessProcesses.first?.pid

        if let explicit = explicitState(harness: harness, tailObjects: tailObjects, tailText: tailText) {
            return (explicit, .live, processID)
        }

        return (.done, .historical, processID)
    }

    private static func explicitState(
        harness: AgentHarness,
        tailObjects: [Any],
        tailText: String
    ) -> SessionState? {
        var lifecycleState: SessionState?

        for object in tailObjects {
            guard let dictionary = object as? [String: Any] else {
                continue
            }

            let topType = topLevelString(dictionary["type"])
            let payload = dictionary["payload"] as? [String: Any]
            let payloadType = topLevelString(payload?["type"])
            let payloadName = topLevelString(payload?["name"])
            let functionName = topLevelString(dictionary["name"])
            let combined = [topType, payloadType, payloadName, functionName]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            if isPermissionWaitMarker(combined) {
                lifecycleState = .waitingForPermission
            } else if isInputWaitMarker(combined) {
                lifecycleState = .waitingForInput
            } else if isRunningMarker(combined) {
                lifecycleState = .running
            } else if isDoneMarker(combined) {
                lifecycleState = .done
            }
        }

        if let lifecycleState {
            return lifecycleState
        }

        let lower = tailText.lowercased()
        if harness == .claude, lower.contains("\"waitingfor\"") || lower.contains("\"waiting_for\"") {
            if lower.contains("permission") || lower.contains("approval") {
                return .waitingForPermission
            }
            if lower.contains("input") || lower.contains("question") || lower.contains("user") {
                return .waitingForInput
            }
        }

        return nil
    }

    private static func topLevelString(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func isPermissionWaitMarker(_ text: String) -> Bool {
        [
            "approval_requested",
            "approval-requested",
            "approval request",
            "permission.asked",
            "permission_asked",
            "permission requested",
            "permission_request",
            "request_permissions",
            "tool_approval"
        ].contains { text.contains($0) }
    }

    private static func isInputWaitMarker(_ text: String) -> Bool {
        [
            "request_user_input",
            "ask_user_question",
            "askuserquestion",
            "input_requested",
            "input-requested",
            "waiting_for_input"
        ].contains { text.contains($0) }
    }

    private static func isRunningMarker(_ text: String) -> Bool {
        [
            "task_started",
            "task-started",
            "turn_started",
            "turn-started",
            "agent_turn_started",
            "agent-turn-started",
            "session.status busy",
            "session_status busy"
        ].contains { text.contains($0) }
    }

    private static func isDoneMarker(_ text: String) -> Bool {
        [
            "task_complete",
            "task-complete",
            "agent_turn_complete",
            "agent-turn-complete",
            "turn_complete",
            "turn-complete",
            "session.idle",
            "session_status idle"
        ].contains { text.contains($0) }
    }
}
