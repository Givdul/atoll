import Foundation

struct TranscriptSummary {
    var sessionID: String?
    var title: String?
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
        let projectPath = firstString(
            in: objects,
            keys: ["cwd", "current_dir", "currentDir", "projectPath", "project_path", "workspace", "workspaceFolder"]
        )
        let model = firstString(in: objects, keys: ["model", "modelId", "model_id"])
        let startedAt = firstDate(
            in: objects,
            keys: ["createdAt", "created_at", "startTime", "started_at", "timestamp", "time"]
        )
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

            for key in ["title", "thread_name", "summary", "description"] {
                if let value = dictionary[key] as? String, let title = cleanTitle(value) {
                    return title
                }
            }

            if let payload = dictionary["payload"] as? [String: Any] {
                for key in ["title", "thread_name", "summary", "description"] {
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

        return textCandidates.compactMap(cleanTitle).first
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
}
