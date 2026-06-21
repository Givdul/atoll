import Foundation

struct SessionActivitySummary {
    var prompt: String?
    var lastToolCall: String?

    static func from(objects: [Any]) -> SessionActivitySummary {
        var prompt: String?
        var lastToolCall: String?

        for object in objects.reversed() {
            if lastToolCall == nil {
                lastToolCall = Self.lastToolCall(in: object)
            }
            if prompt == nil {
                prompt = Self.prompt(in: object)
            }
            if prompt != nil, lastToolCall != nil {
                break
            }
        }

        return SessionActivitySummary(prompt: prompt, lastToolCall: lastToolCall)
    }

    private static func prompt(in object: Any) -> String? {
        for dictionary in JSONHelpers.dictionaries(in: object, newestFirst: true) {
            if let prompt = explicitPrompt(in: dictionary) {
                return prompt
            }
            if isUserMessage(dictionary), let prompt = messageText(in: dictionary) {
                return prompt
            }
        }

        return nil
    }

    private static func lastToolCall(in object: Any) -> String? {
        for dictionary in JSONHelpers.dictionaries(in: object, newestFirst: true) {
            if let tool = toolName(in: dictionary) {
                return tool
            }
        }

        return nil
    }

    private static func explicitPrompt(in dictionary: [String: Any]) -> String? {
        guard !isToolContainer(dictionary) else {
            return nil
        }

        for key in ["prompt", "userPrompt", "user_prompt", "task", "instruction", "instructions", "query"] {
            if let value = JSONHelpers.directValue(in: dictionary, keys: [key]),
               let text = cleanText(value) {
                return text
            }
        }

        if let message = JSONHelpers.directValue(in: dictionary, keys: ["message"]) {
            if let messageDictionary = message as? [String: Any],
               isUserMessage(messageDictionary),
               let text = messageText(in: messageDictionary) {
                return text
            }
            if isUserMessage(dictionary), let text = cleanText(message) {
                return text
            }
        }

        if let payload = JSONHelpers.directValue(in: dictionary, keys: ["payload", "data"]) as? [String: Any],
           isUserMessage(payload),
           let text = messageText(in: payload) {
            return text
        }

        return nil
    }

    private static func messageText(in dictionary: [String: Any]) -> String? {
        for key in ["content", "text", "message", "prompt", "question", "query", "task", "instruction"] {
            if let value = JSONHelpers.directValue(in: dictionary, keys: [key]),
               let text = cleanText(value) {
                return text
            }
        }

        return nil
    }

    private static func isUserMessage(_ dictionary: [String: Any]) -> Bool {
        let role = JSONHelpers.directString(in: dictionary, keys: ["role", "author", "speaker"])?.lowercased() ?? ""
        if role.contains("user") || role.contains("human") {
            return true
        }

        let marker = markerText(in: dictionary)
        let normalized = JSONHelpers.normalizedIdentifier(marker)
        guard !normalized.contains("tool") else {
            return false
        }

        return normalized.contains("user")
            || normalized.contains("prompt")
            || normalized.contains("inputsubmitted")
            || normalized.contains("inputrequested")
    }

    private static func toolName(in dictionary: [String: Any]) -> String? {
        let marker = markerText(in: dictionary)
        if let mapped = mappedToolName(marker) {
            return mapped
        }

        guard isToolContainer(dictionary) else {
            return nil
        }

        for key in ["tool", "toolName", "tool_name", "toolCallName", "tool_call_name", "functionName", "function_name", "name"] {
            if let raw = JSONHelpers.directString(in: dictionary, keys: [key]),
               !isLifecycleName(raw),
               let normalized = displayToolName(raw) {
                return normalized
            }
        }

        if let function = JSONHelpers.directValue(in: dictionary, keys: ["function"]) as? [String: Any],
           let raw = JSONHelpers.directString(in: function, keys: ["name"]),
           let normalized = displayToolName(raw) {
            return normalized
        }

        if JSONHelpers.directValue(in: dictionary, keys: ["command", "cmd", "shell"]) != nil {
            return "Shell"
        }

        return nil
    }

    private static func isToolContainer(_ dictionary: [String: Any]) -> Bool {
        let marker = JSONHelpers.normalizedIdentifier(markerText(in: dictionary))
        if marker.contains("tool")
            || marker.contains("function")
            || marker.contains("mcp")
            || marker.contains("shell")
            || marker.contains("bash")
            || marker.contains("execution")
            || marker.contains("command") {
            return true
        }

        return JSONHelpers.directValue(in: dictionary, keys: ["tool", "toolName", "tool_name", "toolCall", "tool_call", "function"]) != nil
    }

    private static func mappedToolName(_ raw: String) -> String? {
        let normalized = JSONHelpers.normalizedIdentifier(raw)
        if normalized.isEmpty {
            return nil
        }

        if normalized.contains("beforeshellexecution")
            || normalized.contains("aftershellexecution")
            || normalized.contains("shellexecution")
            || normalized.contains("execcommand")
            || normalized.contains("runcommand")
            || normalized.contains("bash")
            || normalized.contains("shell") {
            return "Shell"
        }

        if normalized.contains("beforereadfile")
            || normalized.contains("readfile")
            || normalized == "read" {
            return "Read"
        }

        if normalized.contains("beforewritefile")
            || normalized.contains("writefile")
            || normalized.contains("editfile")
            || normalized.contains("applypatch")
            || normalized.contains("patch") {
            return "Edit"
        }

        if normalized.contains("beforemcpexecution")
            || normalized.contains("mcpexecution")
            || normalized.contains("mcp") {
            return "MCP"
        }

        if normalized.contains("websearch")
            || normalized.contains("googlesearch")
            || normalized.contains("search") {
            return "Search"
        }

        if normalized.contains("webfetch")
            || normalized.contains("fetch") {
            return "Fetch"
        }

        if normalized.contains("grep") {
            return "Grep"
        }

        if normalized.contains("glob") {
            return "Glob"
        }

        if normalized.contains("todowrite") || normalized == "todo" {
            return "Todo"
        }

        return nil
    }

    private static func displayToolName(_ raw: String) -> String? {
        if let mapped = mappedToolName(raw) {
            return mapped
        }

        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + String(lower.dropFirst())
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return nil
        }

        if cleaned.count <= 22 {
            return cleaned
        }

        let end = cleaned.index(cleaned.startIndex, offsetBy: 22)
        return String(cleaned[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLifecycleName(_ raw: String) -> Bool {
        let normalized = JSONHelpers.normalizedIdentifier(raw)
        return normalized.contains("started")
            || normalized.contains("completed")
            || normalized.contains("finished")
            || normalized.contains("idle")
            || normalized.contains("busy")
    }

    private static func markerText(in dictionary: [String: Any]) -> String {
        [
            "type", "event", "eventType", "event_type", "hook", "hookEventName", "hook_event_name",
            "kind", "name", "action", "category"
        ]
        .compactMap { JSONHelpers.directString(in: dictionary, keys: [$0]) }
        .joined(separator: " ")
    }

    private static func cleanText(_ value: Any?) -> String? {
        if let string = value as? String {
            return cleanDisplayText(string)
        }

        if let number = value as? NSNumber {
            return cleanDisplayText(number.stringValue)
        }

        if let dictionary = value as? [String: Any] {
            for key in ["text", "content", "message", "prompt", "question", "value"] {
                if let nested = JSONHelpers.directValue(in: dictionary, keys: [key]),
                   let text = cleanText(nested) {
                    return text
                }
            }
        }

        if let array = value as? [Any] {
            let parts = array.compactMap(cleanText)
            guard !parts.isEmpty else {
                return nil
            }
            return cleanDisplayText(parts.joined(separator: " "))
        }

        return nil
    }

    private static func cleanDisplayText(_ string: String) -> String? {
        guard let cleaned = TranscriptSummary.cleanTitle(string) else {
            return nil
        }

        return isSyntheticPrompt(cleaned) ? nil : cleaned
    }

    private static func isSyntheticPrompt(_ string: String) -> Bool {
        let normalized = string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            "<turn_aborted>",
            "turn_aborted",
            "<turn aborted>",
            "turn aborted"
        ].contains(normalized)
    }

}
