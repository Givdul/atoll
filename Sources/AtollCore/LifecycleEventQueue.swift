import Foundation

/// A durable handoff for hook events emitted while the menu-bar app is not running.
public struct LifecycleEventQueue: Sendable {
    private let directory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".atoll/lifecycle-events", isDirectory: true)
    }

    public func enqueue(_ event: LifecycleEvent) {
        guard let line = event.jsonLine() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).json")
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }

    public func drain() -> [LifecycleEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return left < right
            }
            .compactMap { file in
                defer { try? FileManager.default.removeItem(at: file) }
                guard let line = try? String(contentsOf: file) else { return nil }
                return LifecycleEvent.parse(jsonLine: line)
            }
    }
}
