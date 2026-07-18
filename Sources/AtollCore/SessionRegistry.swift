import Foundation

/// Durable state derived solely from hook events; it never consults processes or locks.
public final class LifecycleSessionRegistry: @unchecked Sendable {
    private struct Record: Codable {
        var sessionID: String
        var harness: AgentHarness
        var state: SessionState
        /// Timestamp reported by the lifecycle provider.
        var updatedAt: Date
        /// Local time when Atoll accepted the current state. Optional so
        /// registries written before this field existed continue to decode.
        var observedAt: Date?
        /// Provider time capped at local receipt time, used only for ordering.
        /// This prevents a future-skewed event from blocking later events.
        var orderingAt: Date?
        var startedAt: Date?
        var title: String?
        var detail: String?
        var prompt: String?
        var projectPath: String?
        var model: String?

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
    private let lock = NSLock()
    private var records: [String: Record]

    public init(
        fileURL: URL,
        activeTTL: TimeInterval = 10 * 60,
        terminalTTL: TimeInterval = 5
    ) {
        self.fileURL = fileURL
        self.activeTTL = activeTTL
        self.terminalTTL = terminalTTL
        self.records = Self.load(from: fileURL)
    }

    @discardableResult
    public func ingest(_ event: LifecycleEvent, now: Date = Date()) -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)

        let key = "\(event.harness.rawValue)-\(event.sessionID)"
        let incomingOrderingAt = min(event.timestamp, now)
        let existingRecord = records[key]

        if existingRecord == nil,
           event.kind.isActive,
           now.timeIntervalSince(incomingOrderingAt) > activeTTL {
            return sessionsLocked(now: now)
        }

        var record = existingRecord ?? Record(
            sessionID: event.sessionID,
            harness: event.harness,
            state: event.kind.sessionState,
            updatedAt: event.timestamp,
            observedAt: now,
            orderingAt: incomingOrderingAt,
            startedAt: event.kind == .started ? event.timestamp : nil,
            title: nil, detail: nil, prompt: nil, projectPath: nil, model: nil
        )

        let currentOrderingAt = record.orderingAt
            ?? min(record.updatedAt, record.observedAt ?? record.updatedAt)

        if existingRecord != nil,
           record.state.isTerminal,
           event.kind.sessionState == record.state {
            // Repeated cleanup/session-end notifications are exact duplicates,
            // not new ordering evidence. Keeping the original ordering point
            // lets a queued start for the next cycle pass the tombstone.
            return sessionsLocked(now: now)
        }

        guard incomingOrderingAt >= currentOrderingAt else {
            return sessionsLocked(now: now)
        }

        let nextState = event.kind.sessionState
        if incomingOrderingAt == currentOrderingAt,
           record.state.isTerminal,
           !nextState.isTerminal,
           now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= terminalTTL {
            // A terminal outcome wins over an equal-time active retry. Once its
            // visible dwell elapses, the retained tombstone can open a genuine
            // new cycle without letting a late retry erase the outcome early.
            return sessionsLocked(now: now)
        }

        if record.state == .failed || record.state == .cancelled,
           nextState == .done {
            // Generic cleanup/session-end hooks often arrive after the hook that
            // captured the actual outcome. They must not flatten it to Done.
            return sessionsLocked(now: now)
        }

        let stateChanged = record.state != nextState
        let startsNewCycle = record.state.isTerminal && !nextState.isTerminal

        record.state = nextState
        record.updatedAt = event.timestamp
        record.orderingAt = incomingOrderingAt
        if startsNewCycle {
            record.startedAt = event.timestamp
        } else if record.startedAt == nil, event.kind == .started {
            record.startedAt = event.timestamp
        }
        if !nextState.isTerminal || stateChanged {
            // Active retries refresh liveness without changing startedAt.
            // A corrected terminal outcome receives a fresh visible dwell.
            record.observedAt = now
        }
        record.title = event.title ?? record.title
        record.detail = event.detail ?? record.detail
        record.prompt = event.prompt ?? record.prompt
        record.projectPath = event.projectPath ?? record.projectPath
        record.model = event.model ?? record.model
        records[key] = record
        prune(now: now)
        save()
        return sessionsLocked(now: now)
    }

    /// Returns visible sessions and removes entries whose hook activity expired.
    public func sessions(now: Date = Date()) -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        let changed = prune(now: now)
        if changed { save() }
        return sessionsLocked(now: now)
    }

    private func sessionsLocked(now: Date) -> [AgentSession] {
        records.values
        .filter { record in
            !record.state.isTerminal
                || now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= terminalTTL
        }
        .map { record in
            AgentSession(
                id: record.key,
                harness: record.harness,
                title: record.title ?? "\(record.harness.displayName) session",
                detail: record.detail ?? record.harness.displayName,
                prompt: record.prompt,
                projectPath: record.projectPath,
                model: record.model,
                state: record.state,
                updatedAt: record.updatedAt,
                observedAt: record.observedAt,
                startedAt: record.startedAt,
                sourcePath: "lifecycle://\(record.key)",
                confidence: .live
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    private func prune(now: Date) -> Bool {
        let before = records.count
        records = records.filter { _, record in
            // Terminal records outlive their visible dwell as tombstones so a
            // late cleanup cannot recreate a second, phantom Done notification.
            let ttl = record.state.isTerminal ? max(activeTTL, terminalTTL) : activeTTL
            return now.timeIntervalSince(record.observedAt ?? record.updatedAt) <= ttl
        }
        return records.count != before
    }

    private static func load(from fileURL: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LossyRecord].self, from: data) else {
            return [:]
        }
        let now = Date()
        let records = decoded.compactMap(\.value).map { decodedRecord in
            var record = decodedRecord
            let observedAt = record.observedAt ?? min(record.updatedAt, now)
            record.observedAt = observedAt
            record.orderingAt = record.orderingAt ?? min(record.updatedAt, observedAt)
            return record
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records.values.sorted { $0.key < $1.key }) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
