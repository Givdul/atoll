import Foundation

enum SessionClassifier {
    static let activeWindow: TimeInterval = 30 * 60

    static func classify(
        harness: AgentHarness,
        tailObjects: [Any],
        tailText: String,
        modifiedAt: Date,
        processes: [RunningProcess],
        lockPID: Int32? = nil,
        piQuestionToolNames: Set<String> = [],
        piPermissionToolNames: Set<String> = []
    ) -> (SessionState, SessionConfidence, Int32?) {
        let harnessProcesses = processes.filter { $0.matches(harness) }
        let processID = lockPID ?? harnessProcesses.first?.pid

        if let explicit = explicitState(
            harness: harness,
            tailObjects: tailObjects,
            tailText: tailText,
            piQuestionToolNames: piQuestionToolNames,
            piPermissionToolNames: piPermissionToolNames
        ) {
            return (
                explicit,
                confidence(
                    for: explicit,
                    modifiedAt: modifiedAt,
                    processID: processID,
                    hasSpecificProcessEvidence: lockPID != nil
                ),
                processID
            )
        }

        return (.done, .historical, processID)
    }

    private static func confidence(
        for state: SessionState,
        modifiedAt: Date,
        processID: Int32?,
        hasSpecificProcessEvidence: Bool
    ) -> SessionConfidence {
        switch state {
        case .done:
            return .historical
        case .running, .waitingForInput, .waitingForPermission:
            if hasSpecificProcessEvidence {
                return .live
            }
            guard Date().timeIntervalSince(modifiedAt) <= activeWindow else {
                return .historical
            }
            return processID != nil ? .live : .inferred
        case .unknown:
            return .historical
        }
    }

    private static func explicitState(
        harness: AgentHarness,
        tailObjects: [Any],
        tailText: String,
        piQuestionToolNames: Set<String>,
        piPermissionToolNames: Set<String>
    ) -> SessionState? {
        if harness == .pi,
           let piState = piLifecycleState(
            from: tailObjects,
            questionToolNames: piQuestionToolNames,
            permissionToolNames: piPermissionToolNames
           ) {
            return piState
        }

        for object in tailObjects.reversed() {
            guard let dictionary = object as? [String: Any] else {
                continue
            }

            if harness == .codex {
                if let codexState = codexLifecycleState(from: dictionary) {
                    return codexState
                }
                continue
            }

            let flattenedDictionaryText = JSONHelpers.flatten(dictionary)

            if isPermissionWaitMarker(flattenedDictionaryText.lowercased()) {
                return .waitingForPermission
            }
            if isInputWaitMarker(flattenedDictionaryText.lowercased()) {
                return .waitingForInput
            }

            let topType = JSONHelpers.topLevelString(dictionary["type"])
            let payload = dictionary["payload"] as? [String: Any]
            let payloadType = JSONHelpers.topLevelString(payload?["type"])
            let payloadName = JSONHelpers.topLevelString(payload?["name"])
            let functionName = JSONHelpers.topLevelString(dictionary["name"])
            let combined = [topType, payloadType, payloadName, functionName]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            if isPermissionWaitMarker(combined) {
                return .waitingForPermission
            } else if isInputWaitMarker(combined) {
                return .waitingForInput
            } else if isDoneMarker(combined) {
                return .done
            } else if isRunningMarker(combined) {
                return .running
            }
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

    private static func codexLifecycleState(from dictionary: [String: Any]) -> SessionState? {
        for markerText in codexLifecycleMarkerTexts(from: dictionary) {
            let marker = markerText.lowercased()
            if isPermissionWaitMarker(marker) {
                return .waitingForPermission
            }
            if isInputWaitMarker(marker) {
                return .waitingForInput
            }
            if isDoneMarker(marker) {
                return .done
            }
            if isRunningMarker(marker) {
                return .running
            }
        }

        return nil
    }

    private static func codexLifecycleMarkerTexts(from dictionary: [String: Any]) -> [String] {
        var texts = [codexDirectMarkerText(in: dictionary)]

        if let payload = JSONHelpers.directDictionary(in: dictionary, keys: ["payload"]) {
            texts.append(codexDirectMarkerText(in: payload))

            if let function = JSONHelpers.directDictionary(in: payload, keys: ["function"]) {
                texts.append(codexDirectMarkerText(in: function))
            }
        }

        return texts.filter { !$0.isEmpty }
    }

    private static func codexDirectMarkerText(in dictionary: [String: Any]) -> String {
        [
            "type", "event", "eventType", "event_type", "hook", "hookEventName", "hook_event_name",
            "kind", "name", "action", "category", "state", "status", "waitingFor", "waiting_for",
            "tool", "toolName", "tool_name", "functionName", "function_name"
        ]
        .compactMap { JSONHelpers.directString(in: dictionary, keys: [$0]) }
        .joined(separator: " ")
    }

    private static func piLifecycleState(
        from tailObjects: [Any],
        questionToolNames: Set<String>,
        permissionToolNames: Set<String>
    ) -> SessionState? {
        for object in tailObjects.reversed() {
            guard let dictionary = object as? [String: Any] else {
                continue
            }

            if let customState = piCustomLifecycleState(from: dictionary) {
                return customState
            }

            if isInputSubmittedMarker(piLifecycleMarkerText(from: dictionary)) {
                return .running
            }

            guard JSONHelpers.topLevelString(dictionary["type"])?.lowercased() == "message" else {
                let flattened = JSONHelpers.flatten(dictionary).lowercased()
                if isPermissionWaitMarker(flattened) {
                    return .waitingForPermission
                }
                if isInputWaitMarker(flattened) {
                    return .waitingForInput
                }
                continue
            }

            guard let message = dictionary["message"] as? [String: Any],
                  let role = JSONHelpers.topLevelString(message["role"])?.lowercased() else {
                continue
            }

            switch role {
            case "user":
                return .running
            case "assistant":
                if let explicitPiState = piAssistantState(
                    from: message,
                    questionToolNames: questionToolNames,
                    permissionToolNames: permissionToolNames
                ) {
                    return explicitPiState
                }

                if piAssistantIsUsingTool(message) {
                    return .running
                }

                if piAssistantIsFinished(message) {
                    return .done
                }

                return .running
            case "toolresult", "tool_result", "bashexecution", "bash_execution":
                if piToolResultIsTerminal(message) {
                    return .done
                }
                return .running
            default:
                continue
            }
        }

        return nil
    }

    private static func piLifecycleMarkerText(from dictionary: [String: Any]) -> String {
        [
            "type", "customType", "custom_type", "event", "eventType", "event_type",
            "hook", "hookEventName", "hook_event_name", "kind", "name", "action",
            "category", "state", "status"
        ]
        .compactMap { JSONHelpers.directString(in: dictionary, keys: [$0]) }
        .joined(separator: " ")
        .lowercased()
    }

    private static func piCustomLifecycleState(from dictionary: [String: Any]) -> SessionState? {
        guard JSONHelpers.topLevelString(dictionary["type"])?.lowercased() == "custom",
              JSONHelpers.normalizedIdentifier(JSONHelpers.topLevelString(dictionary["customType"]) ?? "") == "goalstate",
              let data = dictionary["data"] as? [String: Any],
              data.keys.contains(where: { $0.caseInsensitiveCompare("goal") == .orderedSame }) else {
            return nil
        }

        guard let goal = data.first(where: { $0.key.caseInsensitiveCompare("goal") == .orderedSame })?.value,
              !(goal is NSNull) else {
            return .done
        }

        guard let goalDictionary = goal as? [String: Any],
              let rawStatus = JSONHelpers.topLevelString(goalDictionary["status"]) else {
            return nil
        }

        switch JSONHelpers.normalizedIdentifier(rawStatus) {
        case "active", "running", "working":
            return .running
        case "complete", "completed", "done", "success", "succeeded":
            return .done
        case "paused":
            return .waitingForInput
        case "budget", "budgetreached", "failed", "error", "aborted", "cancelled", "canceled":
            return .done
        default:
            return nil
        }
    }

    private static func piAssistantState(
        from message: [String: Any],
        questionToolNames: Set<String>,
        permissionToolNames: Set<String>
    ) -> SessionState? {
        let flattened = JSONHelpers.flatten(message).lowercased()

        if isPermissionWaitMarker(flattened) || isPermissionToolCall(
            in: message,
            pluginHints: permissionToolNames
        ) {
            return .waitingForPermission
        }

        if isInputWaitMarker(flattened) || isQuestionToolCall(
            in: message,
            pluginHints: questionToolNames
        ) {
            return .waitingForInput
        }

        return nil
    }

    private static func isQuestionToolCall(in message: [String: Any], pluginHints: Set<String>) -> Bool {
        let callNames = piToolCallNames(in: message)
        return callNames.contains {
            isToolNameMatch(
                $0,
                markers: {
                    [
                        "ask",
                        "askquestion",
                        "askuserquestion",
                        "askuserinput",
                        "askusersquestion",
                        "requestuserinput",
                        "request_user_input"
                    ]
                }(),
                pluginHints: pluginHints
            )
        }
    }

    private static func isPermissionToolCall(in message: [String: Any], pluginHints: Set<String>) -> Bool {
        let callNames = piToolCallNames(in: message)
        return callNames.contains {
            isToolNameMatch(
                $0,
                markers: {
                    [
                        "permission",
                        "approval",
                        "approve",
                        "guardrail",
                        "consent",
                        "requestpermission",
                        "toolapproval",
                        "requestapproval",
                        "askpermission"
                    ]
                }(),
                pluginHints: pluginHints
            )
        }
    }

    private static func isToolNameMatch(_ value: String, markers: [String], pluginHints: Set<String>) -> Bool {
        let normalized = JSONHelpers.normalizedIdentifier(value)
        guard !normalized.isEmpty else {
            return false
        }

        if pluginHints.contains(where: { normalized == JSONHelpers.normalizedIdentifier($0) }) {
            return true
        }

        for marker in markers {
            let normalizedMarker = JSONHelpers.normalizedIdentifier(marker)
            if normalized == normalizedMarker {
                return true
            }
            if normalized.contains(normalizedMarker) {
                return true
            }
        }

        return false
    }

    private static func piToolCallNames(in message: [String: Any]) -> Set<String> {
        var names: Set<String> = []

        names.formUnion(piToolCallNames(from: message["tool"], parseNested: true))
        names.formUnion(piToolCallNames(from: message["toolCall"], parseNested: true))
        names.formUnion(piToolCallNames(from: message["tool_call"], parseNested: true))
        names.formUnion(piToolCallNames(from: message["toolCalls"], parseNested: true))
        names.formUnion(piToolCallNames(from: message["tool_calls"], parseNested: true))

        if let function = message["function"] as? [String: Any],
           let functionName = JSONHelpers.topLevelString(function["name"]) {
            names.insert(functionName)
        }

        if let content = message["content"] {
            names.formUnion(piToolCallNames(from: content, parseNested: true))
        }

        if names.isEmpty, let name = JSONHelpers.topLevelString(message["name"]) {
            names.insert(name)
        }

        return names
    }

    private static func piToolCallNames(from value: Any?, parseNested: Bool, depth: Int = 0) -> Set<String> {
        guard depth < 6, let value else {
            return []
        }

        switch value {
        case let dictionary as [String: Any]:
            let type = JSONHelpers.normalizedIdentifier(JSONHelpers.topLevelString(dictionary["type"])?.lowercased() ?? "")
            let looksLikeToolContainer = type.contains("tool") || type.contains("function")
            var names = Set<String>()

            if let toolName = JSONHelpers.topLevelString(dictionary["name"]) {
                names.insert(toolName)
            }
            if looksLikeToolContainer {
                if let toolName = JSONHelpers.topLevelString(dictionary["tool"]) {
                    names.insert(toolName)
                }
                if let toolName = JSONHelpers.topLevelString(dictionary["toolName"]) {
                    names.insert(toolName)
                }
                if let toolName = JSONHelpers.topLevelString(dictionary["tool_name"]) {
                    names.insert(toolName)
                }
                if let toolName = JSONHelpers.topLevelString(dictionary["toolCall"]) {
                    names.insert(toolName)
                }
                if let toolName = JSONHelpers.topLevelString(dictionary["tool_call"]) {
                    names.insert(toolName)
                }
                if let functionName = JSONHelpers.topLevelString(dictionary["functionName"]) {
                    names.insert(functionName)
                }
                if let functionName = JSONHelpers.topLevelString(dictionary["function_name"]) {
                    names.insert(functionName)
                }
                if let toolName = JSONHelpers.topLevelString(dictionary["tool_call_name"]) {
                    names.insert(toolName)
                }
            }

            if parseNested {
                names.formUnion(piToolCallNames(from: dictionary["content"], parseNested: false, depth: depth + 1))
                names.formUnion(piToolCallNames(from: dictionary["arguments"], parseNested: false, depth: depth + 1))
                names.formUnion(piToolCallNames(from: dictionary["toolCalls"], parseNested: false, depth: depth + 1))
                names.formUnion(piToolCallNames(from: dictionary["tool_calls"], parseNested: false, depth: depth + 1))
                names.formUnion(piToolCallNames(from: dictionary["function"], parseNested: false, depth: depth + 1))
            }

            return names
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { result, item in
                result.formUnion(piToolCallNames(from: item, parseNested: parseNested, depth: depth + 1))
            }
        default:
            return []
        }
    }

    private static func piAssistantIsUsingTool(_ message: [String: Any]) -> Bool {
        let stopReason = JSONHelpers.topLevelString(message["stopReason"])?.lowercased()
            ?? JSONHelpers.topLevelString(message["stop_reason"])?.lowercased()
        if stopReason == "tooluse" || stopReason == "tool_use" || stopReason == "tool-use" {
            return true
        }

        guard let content = message["content"] as? [Any] else {
            return false
        }

        return content.contains { block in
            guard let dictionary = block as? [String: Any] else {
                return false
            }
            let type = JSONHelpers.topLevelString(dictionary["type"])?.lowercased()
            return type == "toolcall" || type == "tool_call" || type == "tool-call"
        }
    }

    private static func piAssistantIsFinished(_ message: [String: Any]) -> Bool {
        guard let stopReason = JSONHelpers.topLevelString(message["stopReason"])?.lowercased()
            ?? JSONHelpers.topLevelString(message["stop_reason"])?.lowercased() else {
            return false
        }

        return [
            "stop",
            "length",
            "error",
            "aborted",
            "abort",
            "cancelled",
            "canceled"
        ].contains(stopReason)
    }

    private static func piToolResultIsTerminal(_ message: [String: Any]) -> Bool {
        if let isError = message["isError"] as? Bool, isError {
            return false
        }

        let terminalToolNames: Set<String> = [
            "complete",
            "done",
            "goalcomplete",
            "goaldone",
            "completegoal",
            "taskcomplete",
            "sessioncomplete",
            "agentcomplete",
            "agentdone"
        ]

        for key in ["toolName", "tool_name", "name"] {
            guard let rawName = JSONHelpers.topLevelString(message[key]) else {
                continue
            }
            if terminalToolNames.contains(JSONHelpers.normalizedIdentifier(rawName)) {
                return true
            }
        }

        return false
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
            "permission.request",
            "permission.requested",
            "permission_requested",
            "request_permissions",
            "request_permission",
            "tool_approval",
            "guardrails:action:prompted",
            "guardrails_action_prompted",
            "permission prompt",
            "action_prompted",
            "request permission",
            "permission prompted"
        ].contains { text.contains($0) }
    }

    private static func isInputWaitMarker(_ text: String) -> Bool {
        [
            "request_user_input",
            "ask_user_question",
            "askuserquestion",
            "requestuserinput",
            "ask user",
            "askuserinput",
            "request_user",
            "input_requested",
            "input-requested",
            "waiting_for_input",
            "waiting-for-input",
            "rpiv:ask-user:prompt",
            "ask-user:prompt",
            "ask-user",
            "askuser",
            "question"
        ].contains { text.contains($0) }
    }

    private static func isInputSubmittedMarker(_ text: String) -> Bool {
        let normalized = JSONHelpers.normalizedIdentifier(text)
        return [
            "inputsubmitted",
            "answersubmitted",
            "responsesubmitted",
            "questionanswered",
            "askuserresponse",
            "askuseranswer",
            "inputresponse",
            "questionresponse"
        ].contains { normalized.contains($0) }
    }

    private static func isRunningMarker(_ text: String) -> Bool {
        [
            "task_started",
            "task-started",
            "turn_started",
            "turn-started",
            "turn_start",
            "turn-start",
            "agent_start",
            "agent-start",
            "agent_turn_started",
            "agent-turn-started",
            "beforeshellexecution",
            "before_shell_execution",
            "beforereadfile",
            "before_read_file",
            "beforemcpexecution",
            "before_mcp_execution",
            "tool_call",
            "tool-call",
            "tool_execution_start",
            "tool-execution-start",
            "tool_execution_update",
            "tool-execution-update",
            "tool_execution_end",
            "tool-execution-end",
            "tool_use",
            "tool-use",
            "function_call",
            "function-call",
            "message.part.updated",
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
            "agent_turn_completed",
            "agent-turn-completed",
            "turn_complete",
            "turn-complete",
            "turn_completed",
            "turn-completed",
            "agent_end",
            "agent-end",
            "agent_complete",
            "agent-complete",
            "agent_completed",
            "agent-completed",
            "agent_finished",
            "agent-finished",
            "turn_aborted",
            "turn-aborted",
            "turn abort",
            "turn_abort",
            "aborted",
            "cancelled",
            "canceled",
            "task_finished",
            "task-finished",
            "session.idle",
            "session_status idle"
        ].contains { text.contains($0) }
    }

}
