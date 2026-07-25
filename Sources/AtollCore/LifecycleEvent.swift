import CryptoKit
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
        case .finished: .done
        case .failed: .failed
        case .cancelled: .cancelled
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
    public var originProcessID: Int32?
    public var originBundleIdentifier: String?
    /// Atoll-generated transport identity. It remains stable through socket and
    /// queue retries while distinct hook invocations receive distinct values.
    public var deliveryID: String?

    public init(
        sessionID: String,
        harness: AgentHarness,
        kind: LifecycleEventKind,
        timestamp: Date = Date(),
        title: String? = nil,
        detail: String? = nil,
        prompt: String? = nil,
        projectPath: String? = nil,
        model: String? = nil,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil,
        deliveryID: String? = UUID().uuidString
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
        self.originProcessID = originProcessID
        self.originBundleIdentifier = originBundleIdentifier
        self.deliveryID = deliveryID
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
            model: JSONHelpers.directString(in: dictionary, keys: ["model", "model_id", "modelId"]),
            originProcessID: JSONHelpers.directString(in: dictionary, keys: ["origin_process_id", "originProcessID"]).flatMap(Int32.init),
            originBundleIdentifier: JSONHelpers.directString(in: dictionary, keys: ["origin_bundle_identifier", "originBundleIdentifier"]),
            deliveryID: JSONHelpers.directString(in: dictionary, keys: ["delivery_id", "deliveryId"])
        )
    }

    /// Normalizes the JSON delivered on stdin by a native hook into Atoll's protocol.
    public static func fromHookPayload(
        harness: AgentHarness,
        kind: LifecycleEventKind,
        json: String,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil
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

        let resolvedKind = resolvedHookKind(
            harness: harness,
            fallback: kind,
            payload: dictionary
        )

        return LifecycleEvent(
            sessionID: sessionID,
            harness: harness,
            kind: resolvedKind,
            timestamp: JSONHelpers.directDate(
                in: dictionary,
                keys: ["timestamp", "time", "occurred_at", "occurredAt", "updated_at", "updatedAt"]
            ) ?? Date(),
            title: JSONHelpers.directString(in: dictionary, keys: ["title", "summary"]),
            detail: JSONHelpers.directString(in: dictionary, keys: ["reason", "message"]),
            prompt: JSONHelpers.directString(in: dictionary, keys: ["prompt"]),
            projectPath: JSONHelpers.directString(in: dictionary, keys: ["cwd", "project_path", "projectPath", "workspace"]),
            model: JSONHelpers.directString(in: dictionary, keys: ["model", "model_id", "modelId"]),
            originProcessID: originProcessID,
            originBundleIdentifier: originBundleIdentifier
        )
    }

    private static func resolvedHookKind(
        harness: AgentHarness,
        fallback: LifecycleEventKind,
        payload: [String: Any]
    ) -> LifecycleEventKind {
        guard !fallback.isActive else { return fallback }

        switch harness {
        case .cursor:
            switch JSONHelpers.directString(in: payload, keys: ["status"])?.lowercased() {
            case "completed": return .finished
            case "aborted": return .cancelled
            case "error": return .failed
            default: return fallback
            }
        default:
            return fallback
        }
    }

    public func jsonLine() -> String? {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: Any] = [
            "harness": harness.rawValue,
            "session_id": sessionID,
            "event": kind.rawValue,
            "timestamp": timestampFormatter.string(from: timestamp)
        ]
        object["title"] = title
        object["detail"] = detail
        object["prompt"] = prompt
        object["project_path"] = projectPath
        object["model"] = model
        object["origin_process_id"] = originProcessID
        object["origin_bundle_identifier"] = originBundleIdentifier
        object["delivery_id"] = deliveryID

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }

    /// Stable identity for at-least-once delivery deduplication. Current events
    /// use their transport ID; legacy events use their canonical wire form so an
    /// in-memory receipt and the same event reparsed after a crash still match.
    var deliveryIdentity: String {
        if let deliveryID, !deliveryID.isEmpty {
            return Self.deliveryIdentity(forCanonicalRepresentation: "delivery-id:\(deliveryID)")
        }
        if let line = jsonLine() {
            return Self.deliveryIdentity(forCanonicalRepresentation: line)
        }

        // Lifecycle events contain JSON-safe values, so this is defensive only.
        // Length prefixes keep the fallback unambiguous.
        func component(_ value: String?) -> String {
            guard let value else { return "n" }
            return "s\(value.utf8.count):\(value)"
        }

        let representation = [
            component(harness.rawValue),
            component(sessionID),
            component(kind.rawValue),
            component(String(timestamp.timeIntervalSinceReferenceDate.bitPattern)),
            component(title),
            component(detail),
            component(prompt),
            component(projectPath),
            component(model),
            component(originProcessID.map(String.init)),
            component(originBundleIdentifier)
        ].joined(separator: "|")
        return Self.deliveryIdentity(forCanonicalRepresentation: representation)
    }

    /// Normalizes the unbounded canonical wire form into a fixed-size persisted
    /// key. This also migrates `lastEventKey` values written before the receipt
    /// ledger used digests.
    static func deliveryIdentity(forCanonicalRepresentation representation: String) -> String {
        if representation.hasPrefix("sha256:"), representation.count == 71 {
            return representation
        }
        let digest = SHA256.hash(data: Data(representation.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Migrates either the former canonical JSON key or an already-digested key
    /// without hashing a digest a second time.
    static func migratedDeliveryIdentity(_ legacyKey: String) -> String {
        if legacyKey.hasPrefix("sha256:"), legacyKey.count == 71 {
            return legacyKey
        }
        if let legacyEvent = LifecycleEvent.parse(jsonLine: legacyKey),
           legacyEvent.deliveryID != nil {
            return legacyEvent.deliveryIdentity
        }
        return deliveryIdentity(forCanonicalRepresentation: legacyKey)
    }
}
