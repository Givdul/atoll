import Foundation

struct TranscriptSummary {
    var sessionID: String?
    var title: String?
    var prompt: String?
    var lastToolCall: String?
    var projectPath: String?
    var model: String?
    var startedAt: Date?
    var updatedAt: Date?
    var tailObjects: [Any]
    var tailText: String

    static func fromJSONLines(url: URL, fallbackModifiedAt: Date) -> TranscriptSummary {
        let headLines = FileUtilities.headLines(from: url)
        let tailLines = FileUtilities.tailLines(from: url)
        let objects = (headLines + tailLines).compactMap(JSONHelpers.object)
        let tailObjects = tailLines.compactMap(JSONHelpers.object)

        let sessionID = firstString(
            in: objects,
            keys: ["sessionId", "session_id", "conversation_id", "thread_id", "id", "uuid"]
        )
        let title = bestTitle(in: objects)
        let activity = SessionActivitySummary.from(objects: objects)
        let projectPath = firstString(
            in: objects,
            keys: ["cwd", "current_dir", "currentDir", "projectPath", "project_path", "workspace", "workspaceFolder"]
        )
        let model = firstString(in: objects, keys: ["model", "modelId", "model_id"])
        let initialStartedAt = firstDate(
            in: objects,
            keys: ["createdAt", "created_at", "startTime", "started_at", "timestamp", "time"]
        )
        let startedAt = latestActivityStart(in: tailObjects) ?? initialStartedAt
        let updatedAt = firstDate(
            in: tailObjects.reversed(),
            keys: ["updatedAt", "updated_at", "lastModified", "timestamp", "time"]
        ) ?? fallbackModifiedAt
        let tailText = tailObjects
            .map { JSONHelpers.flatten($0) }
            .joined(separator: " ")

        return TranscriptSummary(
            sessionID: sessionID,
            title: title,
            prompt: activity.prompt,
            lastToolCall: activity.lastToolCall,
            projectPath: projectPath,
            model: model,
            startedAt: startedAt,
            updatedAt: updatedAt,
            tailObjects: tailObjects,
            tailText: tailText
        )
    }

    static func bestTitle(in objects: [Any]) -> String? {
        for object in objects {
            guard let dictionary = object as? [String: Any] else {
                continue
            }

            for key in ["title", "thread_name", "summary", "description", "name"] {
                if let value = dictionary[key] as? String, let title = cleanTitle(value) {
                    return title
                }
            }

            if let payload = dictionary["payload"] as? [String: Any] {
                for key in ["title", "thread_name", "summary", "description", "name"] {
                    if let value = payload[key] as? String, let title = cleanTitle(value) {
                        return title
                    }
                }
            }
        }

        let textCandidates = objects.compactMap { object -> String? in
            let role = JSONHelpers.string(in: object, keys: ["role", "type"])?.lowercased() ?? ""
            guard role.contains("user") || role.contains("prompt") || role.contains("message") else {
                return nil
            }
            return JSONHelpers.string(in: object, keys: ["text", "content", "message", "prompt"])
        }

        return textCandidates.compactMap(cleanDisplayTitle).first
    }

    static func firstString(in objects: [Any], keys: [String]) -> String? {
        for object in objects {
            if let string = JSONHelpers.string(in: object, keys: keys) {
                return string
            }
        }
        return nil
    }

    static func firstDate(in objects: [Any], keys: [String]) -> Date? {
        for object in objects {
            if let date = JSONHelpers.date(in: object, keys: keys) {
                return date
            }
        }
        return nil
    }

    static func latestActivityStart(in objects: [Any]) -> Date? {
        for object in objects.reversed() {
            if let date = activityStartDate(in: object) {
                return date
            }
        }

        return nil
    }

    static func cleanTitle(_ string: String?) -> String? {
        guard let string else {
            return nil
        }

        let collapsed = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return nil
        }

        if collapsed.count <= 72 {
            return collapsed
        }

        let index = collapsed.index(collapsed.startIndex, offsetBy: 72)
        return String(collapsed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanDisplayTitle(_ string: String?) -> String? {
        guard let title = cleanTitle(string) else {
            return nil
        }

        let normalized = title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == "<turn_aborted>" || normalized == "turn_aborted" {
            return nil
        }

        return title
    }

    private static func activityStartDate(in object: Any) -> Date? {
        for dictionary in dictionaries(in: object, newestFirst: true) {
            if isUserActivity(dictionary) {
                if let message = directValue(in: dictionary, keys: ["message"]) as? [String: Any],
                   let date = directDate(in: message, keys: ["timestamp", "time", "createdAt", "created_at", "startTime", "started_at"]) {
                    return date
                }

                if let date = directDate(
                    in: dictionary,
                    keys: ["timestamp", "time", "createdAt", "created_at", "startTime", "started_at"]
                ) {
                    return date
                }
            }

            if isWorkStartMarker(dictionary) {
                if let state = directValue(in: dictionary, keys: ["state"]) as? [String: Any],
                   let time = directValue(in: state, keys: ["time"]) as? [String: Any],
                   let date = directDate(in: time, keys: ["start", "started", "created", "timestamp", "time"]) {
                    return date
                }

                if let time = directValue(in: dictionary, keys: ["time"]) as? [String: Any],
                   let date = directDate(in: time, keys: ["start", "started", "created", "timestamp", "time"]) {
                    return date
                }

                if let date = directDate(
                    in: dictionary,
                    keys: ["start", "started", "created", "timestamp", "time", "createdAt", "created_at", "startTime", "started_at"]
                ) {
                    return date
                }
            }
        }

        return nil
    }

    private static func isUserActivity(_ dictionary: [String: Any]) -> Bool {
        if let message = directValue(in: dictionary, keys: ["message"]) as? [String: Any],
           isUserMessage(message),
           let text = directString(in: message, keys: ["content", "text", "message", "prompt"]),
           cleanDisplayTitle(text) != nil {
            return true
        }

        if isUserMessage(dictionary),
           let text = directString(in: dictionary, keys: ["content", "text", "message", "prompt", "question", "query"]),
           cleanDisplayTitle(text) != nil {
            return true
        }

        return false
    }

    private static func isWorkStartMarker(_ dictionary: [String: Any]) -> Bool {
        let marker = normalizedIdentifier(markerText(in: dictionary))
        if marker.contains("turnstarted")
            || marker.contains("agentturnstarted")
            || marker.contains("taskstarted")
            || marker.contains("toolcall")
            || marker.contains("tooluse")
            || marker.contains("functioncall")
            || marker.contains("beforeshellexecution")
            || marker.contains("beforereadfile")
            || marker.contains("beforemcpexecution") {
            return true
        }

        let nestedState = directValue(in: dictionary, keys: ["state"]) as? [String: Any]
        let state = directString(in: dictionary, keys: ["status"])?.lowercased()
            ?? nestedState.flatMap { directString(in: $0, keys: ["status"])?.lowercased() }
        if state == "running" || state == "busy" || state == "working" {
            return true
        }

        return directValue(in: dictionary, keys: ["tool", "toolName", "tool_name", "toolCall", "tool_call", "function"]) != nil
    }

    private static func isUserMessage(_ dictionary: [String: Any]) -> Bool {
        let role = directString(in: dictionary, keys: ["role", "author", "speaker"])?.lowercased() ?? ""
        if role.contains("user") || role.contains("human") {
            return true
        }

        let marker = normalizedIdentifier(markerText(in: dictionary))
        guard !marker.contains("tool") else {
            return false
        }

        return marker.contains("user")
            || marker.contains("prompt")
            || marker.contains("inputsubmitted")
            || marker.contains("inputrequested")
    }

    private static func markerText(in dictionary: [String: Any]) -> String {
        [
            "type", "event", "eventType", "event_type", "hook", "hookEventName", "hook_event_name",
            "kind", "name", "action", "category"
        ]
        .compactMap { directString(in: dictionary, keys: [$0]) }
        .joined(separator: " ")
    }

    private static func dictionaries(in object: Any?, newestFirst: Bool, maxDepth: Int = 8) -> [[String: Any]] {
        guard let object, maxDepth >= 0 else {
            return []
        }

        if let dictionary = object as? [String: Any] {
            var values = Array(dictionary.values)
            if newestFirst {
                values.reverse()
            }
            return [dictionary] + values.flatMap {
                dictionaries(in: $0, newestFirst: newestFirst, maxDepth: maxDepth - 1)
            }
        }

        if let array = object as? [Any] {
            var values = array
            if newestFirst {
                values.reverse()
            }
            return values.flatMap {
                dictionaries(in: $0, newestFirst: newestFirst, maxDepth: maxDepth - 1)
            }
        }

        return []
    }

    private static func directValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return value
            }
        }

        return nil
    }

    private static func directString(in dictionary: [String: Any], keys: [String]) -> String? {
        guard let value = directValue(in: dictionary, keys: keys) else {
            return nil
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private static func directDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        guard let value = directValue(in: dictionary, keys: keys) else {
            return nil
        }

        return DateParsing.date(from: value)
    }

    private static func normalizedIdentifier(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
