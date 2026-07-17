import Foundation

/// Durable state derived solely from hook events; it never consults processes or locks.
public final class LifecycleSessionRegistry: @unchecked Sendable {
    private struct Record: Codable {
        var sessionID: String
        var harness: AgentHarness
        var state: SessionState
        var updatedAt: Date
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
        var record = records[key] ?? Record(
            sessionID: event.sessionID,
            harness: event.harness,
            state: event.kind.sessionState,
            updatedAt: event.timestamp,
            startedAt: event.kind == .started ? event.timestamp : nil,
            title: nil, detail: nil, prompt: nil, projectPath: nil, model: nil
        )
        guard event.timestamp >= record.updatedAt else { return sessionsLocked(now: now) }

        record.state = event.kind.sessionState
        record.updatedAt = event.timestamp
        if event.kind == .started { record.startedAt = event.timestamp }
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
        records.values.map { record in
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
            let ttl = record.state.isTerminal ? terminalTTL : activeTTL
            return now.timeIntervalSince(record.updatedAt) <= ttl
        }
        return records.count != before
    }

    private static func load(from fileURL: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LossyRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap(\.value).map { ($0.key, $0) })
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records.values.sorted { $0.key < $1.key }) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
