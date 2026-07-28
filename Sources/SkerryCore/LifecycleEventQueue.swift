import Darwin
import Foundation

/// A durable lifecycle event together with the receipt needed to remove it.
///
/// Callers must acknowledge a receipt only after the event has been ingested.
public struct QueuedLifecycleEvent: Sendable {
    public let event: LifecycleEvent
    public let receivedAt: Date

    fileprivate let fileURL: URL

    fileprivate init(event: LifecycleEvent, receivedAt: Date, fileURL: URL) {
        self.event = event
        self.receivedAt = receivedAt
        self.fileURL = fileURL
    }
}

/// A durable handoff for hook events emitted while the menu-bar app is not running.
public struct LifecycleEventQueue: Sendable {
    public static let maximumPendingEvents = 256
    private static let overflowLockWaitNanoseconds: UInt64 = 350_000_000

    private let rootDirectory: URL
    private let directory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rootDirectory = homeDirectory.appendingPathComponent(".skerry", isDirectory: true)
        directory = rootDirectory.appendingPathComponent("lifecycle-events", isDirectory: true)
    }

    /// Persists an event and returns the receipt that can remove it after ingestion.
    @discardableResult
    public func enqueue(_ event: LifecycleEvent) -> QueuedLifecycleEvent? {
        guard LifecycleHookInstaller.supportedAgents.contains(event.harness),
              let line = event.jsonLine() else { return nil }

        do {
            try prepareDirectory()
            let file = directory.appendingPathComponent("\(UUID().uuidString).json")
            try PrivateStorage.writeAtomically(Data(line.utf8), to: file)
            let receipt = QueuedLifecycleEvent(event: event, receivedAt: Date(), fileURL: file)

            guard queuedFiles().count > Self.maximumPendingEvents else {
                return receipt
            }

            for attempt in 0..<2 {
                do {
                    try withOverflowLock {
                        try removeEventsBeyondCap(preserving: file)
                    }
                    return FileManager.default.fileExists(atPath: file.path) ? receipt : nil
                } catch let error as POSIXError
                    where error.code == .EWOULDBLOCK && attempt == 0 {
                    let files = queuedFiles()
                    if files.count <= Self.maximumPendingEvents {
                        return files.contains(file) ? receipt : nil
                    }
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
            }

            let files = queuedFiles()
            guard files.count > Self.maximumPendingEvents else {
                return files.contains(file) ? receipt : nil
            }
            try? FileManager.default.removeItem(at: file)
            return nil
        } catch {
            return nil
        }
    }

    /// Returns durable events without deleting them.
    ///
    /// Unreadable files remain available for a later retry. Files that can be read
    /// but are not valid lifecycle events are removed so they cannot poison every
    /// subsequent refresh.
    public func pendingEvents() -> [QueuedLifecycleEvent] {
        guard (try? prepareDirectory()) != nil else { return [] }
        if queuedFiles().count > Self.maximumPendingEvents {
            try? withOverflowLock {
                try removeEventsBeyondCap()
            }
        }

        // Writers publish only complete atomic files; concurrent pruning or
        // acknowledgment can therefore make a file disappear, never partial.
        return queuedFiles()
            .compactMap { file in
                do {
                    try PrivateStorage.hardenFile(at: file)
                } catch {
                    return nil
                }
                guard let line = try? String(contentsOf: file, encoding: .utf8) else {
                    return nil
                }
                guard let event = LifecycleEvent.parse(jsonLine: line) else {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                guard LifecycleHookInstaller.supportedAgents.contains(event.harness) else {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                let receivedAt = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                guard let sanitizedLine = event.jsonLine() else { return nil }
                if sanitizedLine != line {
                    do {
                        try PrivateStorage.writeAtomically(Data(sanitizedLine.utf8), to: file)
                    } catch {
                        return nil
                    }
                }
                return QueuedLifecycleEvent(event: event, receivedAt: receivedAt, fileURL: file)
            }
    }

    /// Removes one queued event after its receipt has been ingested successfully.
    /// Acknowledgment is idempotent so replay and overlapping refreshes are safe.
    @discardableResult
    public func acknowledge(_ receipt: QueuedLifecycleEvent) -> Bool {
        guard receipt.fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: receipt.fileURL)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private func prepareDirectory() throws {
        try PrivateStorage.ensureDirectory(at: rootDirectory)
        try PrivateStorage.ensureDirectory(at: directory)
    }

    private func withOverflowLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = rootDirectory.appendingPathComponent(".lifecycle-events.writer.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        try PrivateStorage.hardenFile(at: lockURL)

        let deadline = DispatchTime.now().uptimeNanoseconds
            + Self.overflowLockWaitNanoseconds
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {
                continue
            }
            guard (errno == EWOULDBLOCK || errno == EAGAIN),
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EWOULDBLOCK)
            }
            usleep(1_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func removeEventsBeyondCap(preserving retainedFile: URL? = nil) throws {
        var files = queuedFiles()
        while files.count > Self.maximumPendingEvents {
            guard let index = files.firstIndex(where: { $0 != retainedFile }) else {
                throw POSIXError(.ENOSPC)
            }
            let oldest = files.remove(at: index)
            do {
                try FileManager.default.removeItem(at: oldest)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }

    private func queuedFiles() -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter {
                (try? $0.resourceValues(forKeys: resourceKeys).isRegularFile) == true
            }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if leftDate == rightDate {
                    return left.lastPathComponent < right.lastPathComponent
                }
                return leftDate < rightDate
            }
    }

}
