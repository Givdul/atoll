import Foundation

/// Durable proof that Atoll accepted a validated local event from a provider.
/// The file contains only provider identifiers and local receipt times.
public final class LifecycleRuntimeEvidenceStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var receiptTimes: [String: Date]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = homeDirectory.appendingPathComponent(".atoll/lifecycle-runtime-evidence.json")
        try? PrivateStorage.ensureDirectory(at: fileURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? PrivateStorage.hardenFile(at: fileURL)
        }
        receiptTimes = Self.load(from: fileURL)
    }

    public func lastValidEvent(for provider: AgentHarness) -> Date? {
        lock.withLock { receiptTimes[provider.rawValue] }
    }

    /// Records evidence only after the caller has durably accepted the event.
    /// Returns false without changing in-memory state if persistence fails.
    @discardableResult
    public func record(provider: AgentHarness, receivedAt: Date) -> Bool {
        guard LifecycleHookInstaller.supportedAgents.contains(provider) else { return false }
        return lock.withLock {
            let previous = receiptTimes
            receiptTimes[provider.rawValue] = max(receiptTimes[provider.rawValue] ?? .distantPast, receivedAt)
            do {
                let data = try JSONEncoder().encode(receiptTimes)
                try PrivateStorage.writeAtomically(data, to: fileURL, hardenDirectory: true)
                return true
            } catch {
                receiptTimes = previous
                return false
            }
        }
    }

    /// Invalidates runtime proof after an integration or shared bridge repair.
    @discardableResult
    public func invalidate(providers: [AgentHarness]) -> Bool {
        let keys = Set(providers.filter(LifecycleHookInstaller.supportedAgents.contains).map(\.rawValue))
        guard !keys.isEmpty else { return true }
        return lock.withLock {
            let previous = receiptTimes
            receiptTimes = receiptTimes.filter { !keys.contains($0.key) }
            do {
                let data = try JSONEncoder().encode(receiptTimes)
                try PrivateStorage.writeAtomically(data, to: fileURL, hardenDirectory: true)
                return true
            } catch {
                receiptTimes = previous
                return false
            }
        }
    }

    private static func load(from fileURL: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded.filter { key, _ in
            AgentHarness.parse(key).map(LifecycleHookInstaller.supportedAgents.contains) == true
        }
    }
}
