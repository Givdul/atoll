import Foundation

/// Durable state derived solely from hook events; it never consults processes or locks.
public final class LifecycleSessionRegistry: @unchecked Sendable {
    private struct DeliveryReceipt: Codable {
        var identity: String
        var receivedAt: Date
    }

    private struct EphemeralTaskLabel {
        var value: String
    }

    private struct Record: Codable {
        var sessionID: String
        var harness: AgentHarness
        var state: SessionState
        /// Timestamp reported by the lifecycle provider.
        var updatedAt: Date
        /// Local time when Topside accepted the current state. Optional so
        /// registries written before this field existed continue to decode.
        var observedAt: Date?
        /// Provider time capped at local receipt time, used only for ordering.
        /// This prevents a future-skewed event from blocking later events.
        var orderingAt: Date?
        var startedAt: Date?
        var label: String?
        var originProcessID: Int32?
        var originBundleIdentifier: String?
        /// Legacy single-event key retained only to decode and migrate registry
        /// files written before the bounded receipt ledger.
        var lastEventKey: String?
        /// Recently processed transport identities, including semantic no-ops.
        /// These outlive UI visibility so a queue replay cannot become valid as
        /// dwell or stale-state timing changes.
        var recentDeliveries: [DeliveryReceipt]?

        var key: String { "\(harness.rawValue)-\(sessionID)" }
    }

    private struct LossyRecord: Decodable {
        let value: Record?

        init(from decoder: Decoder) throws {
            value = try? Record(from: decoder)
        }
    }

    private let fileURL: URL
    private let activeTTL: TimeInterval
    private let terminalTTL: TimeInterval
    private let hardensParentDirectory: Bool
    private let filePermissionSetter: PrivateStorage.FilePermissionSetter?
    private let lock = NSLock()
    private var records: [String: Record]
    private var taskLabels: [String: EphemeralTaskLabel]
    private var needsRewrite: Bool

    /// Delivery identities remain deduplicated for one day, independently of
    /// the much shorter active/terminal presentation lifetimes.
    static let deliveryIdentityRetention: TimeInterval = 24 * 60 * 60
    /// Bounds persisted growth for a busy session while covering substantially
    /// more transitions than a normal lifecycle turn emits.
    static let maximumRecentDeliveryIdentities = 256

    public init(
        fileURL: URL,
        activeTTL: TimeInterval = 10 * 60,
        terminalTTL: TimeInterval = 5
    ) {
        self.fileURL = fileURL
        self.activeTTL = activeTTL
        self.terminalTTL = terminalTTL
        self.hardensParentDirectory = fileURL.deletingLastPathComponent().lastPathComponent == ".topside"
        self.filePermissionSetter = nil
        let loaded = Self.load(from: fileURL)
        self.records = loaded.records
        self.taskLabels = [:]
        self.needsRewrite = loaded.needsRewrite
    }

    package init(
        fileURL: URL,
        activeTTL: TimeInterval = 10 * 60,
        terminalTTL: TimeInterval = 5,
        filePermissionSetter: @escaping PrivateStorage.FilePermissionSetter
    ) {
        self.fileURL = fileURL
        self.activeTTL = activeTTL
        self.terminalTTL = terminalTTL
        self.hardensParentDirectory = fileURL.deletingLastPathComponent().lastPathComponent == ".topside"
        self.filePermissionSetter = filePermissionSetter
        let loaded = Self.load(from: fileURL)
        self.records = loaded.records
        self.taskLabels = [:]
        self.needsRewrite = loaded.needsRewrite
    }

    @discardableResult
    public func ingest(_ event: LifecycleEvent, now: Date = Date()) -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        let sessions = ingestLocked(event, now: now)
        _ = save()
        return sessions
    }

    /// Ingests an event only if the resulting registry can be written atomically.
    ///
    /// The in-memory mutation is rolled back when persistence fails so callers
    /// can leave a queue receipt pending and safely replay it later.
    @discardableResult
    public func ingestPersisting(_ event: LifecycleEvent, now: Date = Date()) -> [AgentSession]? {
        lock.lock()
        defer { lock.unlock() }

        let previousRecords = records
        let previousTaskLabels = taskLabels
        let sessions = ingestLocked(event, now: now)
        guard save() else {
            records = previousRecords
            taskLabels = previousTaskLabels
            return nil
        }
        return sessions
    }

    private func ingestLocked(_ event: LifecycleEvent, now: Date) -> [AgentSession] {
        prune(now: now)

        let key = "\(event.harness.rawValue)-\(event.sessionID)"
        let incomingEventKey = event.deliveryIdentity
        let incomingOrderingAt = min(event.timestamp, now)
        let retainedRecord = records[key]

        if retainedRecord?.recentDeliveries?.contains(where: { $0.identity == incomingEventKey }) == true {
            // A receipt can replay after a crash between registry persistence
            // and queue acknowledgment. Exact replay must not refresh local
            // liveness or make a running/waiting state immortal.
            return sessionsLocked(now: now)
        }

        let existingRecord = retainedRecord.flatMap {
            stateIsSemanticallyRetained($0, now: now) ? $0 : nil
        }

        if existingRecord == nil,
           event.kind.isActive,
           now.timeIntervalSince(incomingOrderingAt) > activeTTL {
            // The event is too old to recreate active UI state, but its receipt
            // must still be persisted so retrying it cannot become meaningful.
            var deliveryRecord = retainedRecord ?? initialRecord(
                for: event,
                orderingAt: incomingOrderingAt,
                observedAt: incomingOrderingAt
            )
            recordDelivery(incomingEventKey, receivedAt: now, in: &deliveryRecord)
            records[key] = deliveryRecord
            prune(now: now)
            return sessionsLocked(now: now)
        }

        var record = existingRecord ?? initialRecord(
            for: event,
            orderingAt: incomingOrderingAt,
            observedAt: now
        )
        if existingRecord == nil {
            record.recentDeliveries = retainedRecord?.recentDeliveries
            if let originProcessID = retainedRecord?.originProcessID,
               let originBundleIdentifier = retainedRecord?.originBundleIdentifier {
                record.originProcessID = originProcessID
                record.originBundleIdentifier = originBundleIdentifier
            }
        }
        recordDelivery(incomingEventKey, receivedAt: now, in: &record)

        let currentOrderingAt = record.orderingAt
            ?? min(record.updatedAt, record.observedAt ?? record.updatedAt)

        guard incomingOrderingAt >= currentOrderingAt else {
            return persistNoOp(record, key: key, now: now)
        }

        if let originProcessID = event.originProcessID,
           originProcessID > 0,
           let originBundleIdentifier = event.originBundleIdentifier,
           !originBundleIdentifier.isEmpty {
            record.originProcessID = originProcessID
            record.originBundleIdentifier = originBundleIdentifier
        }

        if existingRecord != nil,
           record.state.isTerminal,
           event.kind.sessionState == record.state {
            // Repeated cleanup/session-end notifications are exact duplicates,
            // not new ordering evidence. Keeping the original ordering point
            // lets a queued start for the next cycle pass the tombstone.
            return persistNoOp(record, key: key, now: now)
        }

        let nextState = event.kind.sessionState
        if incomingOrderingAt == currentOrderingAt,
           record.state.isTerminal,
           !nextState.isTerminal,
           now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= terminalTTL {
            // A terminal outcome wins over an equal-time active retry. Once its
            // visible dwell elapses, the retained tombstone can open a genuine
            // new cycle without letting a late retry erase the outcome early.
            return persistNoOp(record, key: key, now: now)
        }

        if record.state == .failed || record.state == .cancelled,
           nextState == .done {
            // Generic cleanup/session-end hooks often arrive after the hook that
            // captured the actual outcome. They must not flatten it to Done.
            return persistNoOp(record, key: key, now: now)
        }

        let stateChanged = record.state != nextState
        let startsNewCycle = record.state.isTerminal && !nextState.isTerminal

        if startsNewCycle {
            taskLabels.removeValue(forKey: key)
        }
        if let taskLabel = event.taskLabel {
            taskLabels[key] = EphemeralTaskLabel(value: taskLabel)
        }

        record.state = nextState
        record.updatedAt = event.timestamp
        record.orderingAt = incomingOrderingAt
        if startsNewCycle {
            record.startedAt = incomingOrderingAt
        } else if record.startedAt == nil, event.kind == .started {
            record.startedAt = incomingOrderingAt
        }
        if !nextState.isTerminal || stateChanged {
            // Active retries refresh liveness without changing startedAt.
            // A corrected terminal outcome receives a fresh visible dwell.
            record.observedAt = now
        }
        let fallbackLabel = "\(event.harness.displayName) session"
        if record.label == nil || event.label != fallbackLabel {
            record.label = event.label
        }
        record.lastEventKey = nil
        records[key] = record
        prune(now: now)
        return sessionsLocked(now: now)
    }

    private func initialRecord(
        for event: LifecycleEvent,
        orderingAt: Date,
        observedAt: Date
    ) -> Record {
        let hasOrigin = (event.originProcessID ?? 0) > 0
            && !(event.originBundleIdentifier?.isEmpty ?? true)
        return Record(
            sessionID: event.sessionID,
            harness: event.harness,
            state: event.kind.sessionState,
            updatedAt: event.timestamp,
            observedAt: observedAt,
            orderingAt: orderingAt,
            startedAt: event.kind == .started ? orderingAt : nil,
            label: event.label,
            originProcessID: hasOrigin ? event.originProcessID : nil,
            originBundleIdentifier: hasOrigin ? event.originBundleIdentifier : nil,
            lastEventKey: nil,
            recentDeliveries: nil
        )
    }

    private func recordDelivery(
        _ identity: String,
        receivedAt: Date,
        in record: inout Record
    ) {
        var deliveries = record.recentDeliveries ?? []
        deliveries.removeAll {
            receivedAt.timeIntervalSince($0.receivedAt) > Self.deliveryIdentityRetention
        }
        if !deliveries.contains(where: { $0.identity == identity }) {
            deliveries.append(DeliveryReceipt(identity: identity, receivedAt: receivedAt))
        }
        if deliveries.count > Self.maximumRecentDeliveryIdentities {
            deliveries.removeFirst(deliveries.count - Self.maximumRecentDeliveryIdentities)
        }
        record.lastEventKey = nil
        record.recentDeliveries = deliveries
    }

    private func persistNoOp(_ record: Record, key: String, now: Date) -> [AgentSession] {
        records[key] = record
        prune(now: now)
        return sessionsLocked(now: now)
    }

    private func stateIsSemanticallyRetained(_ record: Record, now: Date) -> Bool {
        let ttl = record.state.isTerminal ? max(activeTTL, terminalTTL) : activeTTL
        return now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= ttl
    }

    /// Returns visible sessions and removes entries whose hook activity expired.
    public func sessions(now: Date = Date()) -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        let changed = prune(now: now)
        if changed || needsRewrite { _ = save() }
        return sessionsLocked(now: now)
    }

    private func sessionsLocked(now: Date) -> [AgentSession] {
        records.values
        .filter { record in
            let ttl = record.state.isTerminal ? terminalTTL : activeTTL
            return now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= ttl
        }
        .map { record in
            let presentationUpdatedAt = record.orderingAt
                ?? min(record.updatedAt, record.observedAt ?? record.updatedAt)
            return AgentSession(
                id: record.key,
                harness: record.harness,
                label: record.label ?? "\(record.harness.displayName) session",
                state: record.state,
                updatedAt: presentationUpdatedAt,
                taskLabel: taskLabels[record.key]?.value,
                observedAt: record.observedAt,
                startedAt: record.startedAt,
                originProcessID: record.originProcessID,
                originBundleIdentifier: record.originBundleIdentifier
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    private func prune(now: Date) -> Bool {
        var changed = false
        var retained: [String: Record] = [:]

        for (key, originalRecord) in records {
            var record = originalRecord
            var deliveries = record.recentDeliveries ?? []
            let previousDeliveryCount = deliveries.count
            deliveries.removeAll {
                now.timeIntervalSince($0.receivedAt) > Self.deliveryIdentityRetention
            }
            if deliveries.count > Self.maximumRecentDeliveryIdentities {
                deliveries.removeFirst(deliveries.count - Self.maximumRecentDeliveryIdentities)
            }
            if deliveries.count != previousDeliveryCount || record.lastEventKey != nil {
                changed = true
            }
            record.lastEventKey = nil
            record.recentDeliveries = deliveries.isEmpty ? nil : deliveries

            // State has a short semantic tombstone, while processed delivery
            // identities remain hidden and deduplicated for the longer policy.
            let semanticallyRetained = stateIsSemanticallyRetained(record, now: now)
            if semanticallyRetained || !deliveries.isEmpty {
                retained[key] = record
                if !semanticallyRetained {
                    taskLabels.removeValue(forKey: key)
                }
            } else {
                taskLabels.removeValue(forKey: key)
                changed = true
            }
        }
        records = retained
        for key in Array(taskLabels.keys) where retained[key] == nil {
            taskLabels.removeValue(forKey: key)
            changed = true
        }
        return changed
    }

    private static func load(from fileURL: URL) -> (records: [String: Record], needsRewrite: Bool) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if directory.lastPathComponent == ".topside" {
            try? PrivateStorage.ensureDirectory(at: directory, fileManager: fileManager)
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? PrivateStorage.hardenFile(at: fileURL, fileManager: fileManager)
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LossyRecord].self, from: data) else {
            return ([:], false)
        }
        let now = Date()
        let records = decoded.compactMap(\.value).map { decodedRecord in
            var record = decodedRecord
            let observedAt = record.observedAt ?? min(record.updatedAt, now)
            record.observedAt = observedAt
            record.orderingAt = record.orderingAt ?? min(record.updatedAt, observedAt)
            var deliveries = record.recentDeliveries ?? []
            if let lastEventKey = record.lastEventKey {
                let migratedIdentity = LifecycleEvent.migratedDeliveryIdentity(lastEventKey)
                if !deliveries.contains(where: { $0.identity == migratedIdentity }) {
                    deliveries.append(DeliveryReceipt(identity: migratedIdentity, receivedAt: observedAt))
                }
            }
            deliveries = deliveries.map {
                DeliveryReceipt(
                    identity: LifecycleEvent.migratedDeliveryIdentity($0.identity),
                    receivedAt: $0.receivedAt
                )
            }
            var seenIdentities: Set<String> = []
            deliveries = deliveries.filter { seenIdentities.insert($0.identity).inserted }
            if deliveries.count > Self.maximumRecentDeliveryIdentities {
                deliveries.removeFirst(deliveries.count - Self.maximumRecentDeliveryIdentities)
            }
            record.lastEventKey = nil
            record.recentDeliveries = deliveries.isEmpty ? nil : deliveries
            record.label = record.label ?? "\(record.harness.displayName) session"
            let bundleIdentifier = record.originBundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (record.originProcessID ?? 0) <= 0 || bundleIdentifier?.isEmpty != false {
                record.originProcessID = nil
                record.originBundleIdentifier = nil
            } else {
                record.originBundleIdentifier = bundleIdentifier
            }
            return record
        }
        return (Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }), true)
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records.values.sorted { $0.key < $1.key }) else {
            return false
        }

        do {
            try PrivateStorage.writeAtomically(
                data,
                to: fileURL,
                hardenDirectory: hardensParentDirectory,
                filePermissionSetter: filePermissionSetter
            )
            needsRewrite = false
            return true
        } catch {
            return false
        }
    }
}
