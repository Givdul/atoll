import Foundation

/// The small, harness-neutral protocol written by lifecycle hooks.
public enum LifecycleEventKind: String, Codable, CaseIterable, Sendable {
    case started
    case finished
    case failed
    case cancelled
    case needsInput
    case needsPermission

    var sessionState: SessionState {
        switch self {
        case .started: .running
        case .finished, .failed, .cancelled: .done
        case .needsInput: .waitingForInput
        case .needsPermission: .waitingForPermission
        }
    }

    var isActive: Bool {
        switch self {
        case .finished, .failed, .cancelled: false
        case .started, .needsInput, .needsPermission: true
        }
    }

    public static func parse(_ raw: String) -> LifecycleEventKind? {
        switch raw.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "started", "start", "running", "turnstarted", "agentturnstarted": .started
        case "finished", "finish", "completed", "complete", "done", "turncompleted": .finished
        case "failed", "error": .failed
        case "cancelled", "canceled", "aborted", "turnaborted": .cancelled
        case "needsinput", "waitingforinput", "waitinginput", "requestuserinput": .needsInput
        case "needspermission", "waitingforpermission", "waitingpermission", "approvalrequested": .needsPermission
        default: nil
        }
    }
}

public struct LifecycleEvent: Hashable, Sendable {

    public var sessionID: String
    public var harness: AgentHarness
    public var kind: LifecycleEventKind
    public var timestamp: Date
    public var title: String?
    public var detail: String?
    public var prompt: String?
    public var projectPath: String?
    public var model: String?

    public init(
        sessionID: String,
        harness: AgentHarness,
        kind: LifecycleEventKind,
        timestamp: Date = Date(),
        title: String? = nil,
        detail: String? = nil,
        prompt: String? = nil,
        projectPath: String? = nil,
        model: String? = nil
    ) {
        self.sessionID = sessionID
        self.harness = harness
        self.kind = kind
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
        self.prompt = prompt
        self.projectPath = projectPath
        self.model = model
    }

    /// Parses one JSONL hook record. Aliases cover common hook payloads while
    /// deliberately requiring a harness, session id, and lifecycle marker.
    public static func parse(jsonLine: String) -> LifecycleEvent? {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let harness = AgentHarness.parse(JSONHelpers.directString(in: dictionary, keys: ["harness", "agent", "agent_name"])),
              let sessionID = JSONHelpers.directString(in: dictionary, keys: ["session_id", "sessionId", "id", "conversation_id", "thread_id"]),
              let marker = JSONHelpers.directString(in: dictionary, keys: ["event", "event_type", "eventType", "type", "state", "status"]),
              let kind = LifecycleEventKind.parse(marker) else {
            return nil
        }

        return LifecycleEvent(
            sessionID: sessionID,
            harness: harness,
            kind: kind,
            timestamp: JSONHelpers.directDate(in: dictionary, keys: ["timestamp", "time", "occurred_at", "occurredAt", "updated_at", "updatedAt"]) ?? Date(),
            title: JSONHelpers.directString(in: dictionary, keys: ["title", "summary"]),
            detail: JSONHelpers.directString(in: dictionary, keys: ["detail", "reason", "message"]),
            prompt: JSONHelpers.directString(in: dictionary, keys: ["prompt"]),
            projectPath: JSONHelpers.directString(in: dictionary, keys: ["project_path", "projectPath", "cwd", "workspace"]),
            model: JSONHelpers.directString(in: dictionary, keys: ["model", "model_id", "modelId"])
        )
    }

    /// Normalizes the JSON delivered on stdin by a native hook into Atoll's protocol.
    public static func fromHookPayload(
        harness: AgentHarness,
        kind: LifecycleEventKind,
        json: String
    ) -> LifecycleEvent? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let sessionID = JSONHelpers.directString(
                in: dictionary,
                keys: ["session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId", "id"]
              ) else {
            return nil
        }

        return LifecycleEvent(
            sessionID: sessionID,
            harness: harness,
            kind: kind,
            timestamp: JSONHelpers.directDate(
                in: dictionary,
                keys: ["timestamp", "time", "occurred_at", "occurredAt", "updated_at", "updatedAt"]
            ) ?? Date(),
            title: JSONHelpers.directString(in: dictionary, keys: ["title", "summary"]),
            detail: JSONHelpers.directString(in: dictionary, keys: ["reason", "message"]),
            prompt: JSONHelpers.directString(in: dictionary, keys: ["prompt"]),
            projectPath: JSONHelpers.directString(in: dictionary, keys: ["cwd", "project_path", "projectPath", "workspace"]),
            model: JSONHelpers.directString(in: dictionary, keys: ["model", "model_id", "modelId"])
        )
    }

    public func jsonLine() -> String? {
        var object: [String: Any] = [
            "harness": harness.rawValue,
            "session_id": sessionID,
            "event": kind.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        object["title"] = title
        object["detail"] = detail
        object["prompt"] = prompt
        object["project_path"] = projectPath
        object["model"] = model

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }
}
