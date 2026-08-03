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
    public var label: String
    /// Ephemeral presentation text. It is accepted only on the live socket
    /// path and is never part of the canonical queue or registry record.
    public var taskLabel: String?
    public var originProcessID: Int32?
    public var originBundleIdentifier: String?
    /// Topside-generated transport identity. It remains stable through socket and
    /// queue retries while distinct hook invocations receive distinct values.
    public var deliveryID: String?
    private var legacyDeliveryIdentity: String?

    public init(
        sessionID: String,
        harness: AgentHarness,
        kind: LifecycleEventKind,
        timestamp: Date = Date(),
        label: String? = nil,
        taskLabel: String? = nil,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil,
        deliveryID: String? = UUID().uuidString
    ) {
        self.sessionID = sessionID
        self.harness = harness
        self.kind = kind
        self.timestamp = timestamp
        self.label = Self.sanitizedLabel(label) ?? "\(harness.displayName) session"
        self.taskLabel = Self.normalizedTaskLabel(taskLabel)
        let normalizedBundleIdentifier = originBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let originProcessID,
           originProcessID > 0,
           let normalizedBundleIdentifier,
           !normalizedBundleIdentifier.isEmpty {
            self.originProcessID = originProcessID
            self.originBundleIdentifier = normalizedBundleIdentifier
        } else {
            self.originProcessID = nil
            self.originBundleIdentifier = nil
        }
        self.deliveryID = deliveryID
        self.legacyDeliveryIdentity = nil
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

        let deliveryID = JSONHelpers.directString(in: dictionary, keys: ["delivery_id", "deliveryId"])
        var event = LifecycleEvent(
            sessionID: sessionID,
            harness: harness,
            kind: kind,
            timestamp: JSONHelpers.directDate(in: dictionary, keys: ["timestamp", "time", "occurred_at", "occurredAt", "updated_at", "updatedAt"]) ?? Date(),
            label: JSONHelpers.directString(in: dictionary, keys: ["label"])
                ?? projectLabel(from: JSONHelpers.directString(
                    in: dictionary,
                    keys: ["project_path", "projectPath", "cwd", "workspace"]
                )),
            taskLabel: JSONHelpers.directString(in: dictionary, keys: ["task_label", "taskLabel"]),
            originProcessID: JSONHelpers.directString(in: dictionary, keys: ["origin_process_id", "originProcessID"]).flatMap(Int32.init),
            originBundleIdentifier: JSONHelpers.directString(in: dictionary, keys: ["origin_bundle_identifier", "originBundleIdentifier"]),
            deliveryID: deliveryID
        )
        if deliveryID == nil {
            event.legacyDeliveryIdentity = validatedDeliveryIdentity(
                JSONHelpers.directString(in: dictionary, keys: ["delivery_identity", "deliveryIdentity"])
            ) ?? deliveryIdentity(forCanonicalRepresentation: jsonLine)
        }
        return event
    }

    /// Normalizes the JSON delivered on stdin by a native hook into Topside's protocol.
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
            label: projectLabel(from: JSONHelpers.directString(
                in: dictionary,
                keys: ["cwd", "project_path", "projectPath", "workspace"]
            )),
            taskLabel: taskLabel(for: harness, payload: dictionary),
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

    private static func projectLabel(from workingDirectory: String?) -> String? {
        guard let workingDirectory,
              workingDirectory.hasPrefix("/") else {
            return nil
        }
        return sanitizedLabel((workingDirectory as NSString).lastPathComponent)
    }

    private static func sanitizedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let label = (value as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              label != "/",
              label != ".",
              label != "..",
              label != "~",
              label.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return label
    }

    private static func taskLabel(for harness: AgentHarness, payload: [String: Any]) -> String? {
        switch harness {
        case .cursor, .opencode:
            return normalizedTaskLabel(JSONHelpers.directString(in: payload, keys: ["title"]))
                ?? normalizedTaskLabel(JSONHelpers.directString(in: payload, keys: ["prompt", "message", "text"]))
        case .codex, .claude, .pi:
            return normalizedTaskLabel(JSONHelpers.directString(in: payload, keys: ["prompt", "message", "text"]))
        case .topside:
            return nil
        }
    }

    private static func normalizedTaskLabel(_ value: String?) -> String? {
        guard let value else { return nil }

        var cleaned = ""
        cleaned.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                cleaned.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
        }

        let normalized = cleaned.split(separator: " ").joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 48 else { return normalized }
        return String(normalized.prefix(47)) + "…"
    }

    private static func validatedDeliveryIdentity(_ value: String?) -> String? {
        guard let value,
              value.hasPrefix("sha256:"),
              value.count == 71,
              value.dropFirst(7).allSatisfy(\.isHexDigit) else {
            return nil
        }
        return value.lowercased()
    }

    public func jsonLine() -> String? {
        jsonLine(includeTaskLabel: false)
    }

    /// The live-only socket representation. The queue calls `jsonLine()` and
    /// therefore cannot persist this field.
    package func socketLine() -> String? {
        jsonLine(includeTaskLabel: true)
    }

    private func jsonLine(includeTaskLabel: Bool) -> String? {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: Any] = [
            "harness": harness.rawValue,
            "session_id": sessionID,
            "event": kind.rawValue,
            "timestamp": timestampFormatter.string(from: timestamp)
        ]
        object["label"] = label
        object["origin_process_id"] = originProcessID
        object["origin_bundle_identifier"] = originBundleIdentifier
        object["delivery_id"] = deliveryID
        object["delivery_identity"] = deliveryID == nil ? legacyDeliveryIdentity : nil
        if includeTaskLabel {
            object["task_label"] = taskLabel
        }

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
        if let legacyDeliveryIdentity {
            return legacyDeliveryIdentity
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
            component(label),
            component(originProcessID.map(String.init)),
            component(originBundleIdentifier)
        ].joined(separator: "|")
        return Self.deliveryIdentity(forCanonicalRepresentation: representation)
    }

    /// Normalizes the unbounded canonical wire form into a fixed-size persisted
    /// key. This also migrates `lastEventKey` values written before the receipt
    /// ledger used digests.
    static func deliveryIdentity(forCanonicalRepresentation representation: String) -> String {
        if let identity = validatedDeliveryIdentity(representation) {
            return identity
        }
        let digest = SHA256.hash(data: Data(representation.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Migrates either the former canonical JSON key or an already-digested key
    /// without hashing a digest a second time.
    static func migratedDeliveryIdentity(_ legacyKey: String) -> String {
        if let identity = validatedDeliveryIdentity(legacyKey) {
            return identity
        }
        if let legacyEvent = LifecycleEvent.parse(jsonLine: legacyKey) {
            return legacyEvent.deliveryIdentity
        }
        return deliveryIdentity(forCanonicalRepresentation: legacyKey)
    }
}
