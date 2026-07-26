import Foundation

public enum SkerryBetaMigration {
    package static let stateDirectoryName = ".skerry"
    package static let betaStateDirectoryName = ".atoll"
    package static let completionMarkerName = ".atoll-beta-migration-v1-complete"

    private static let files = [
        "config.json",
        "lifecycle-sessions.json",
        "lifecycle-runtime-evidence.json"
    ]
    private static let directories = [
        "lifecycle-events",
        "backups"
    ]

    /// Migrates beta-owned state and defaults exactly once. The completion marker
    /// is written only after both stores succeed, so a failed migration can retry.
    public static func migrateIfNeeded(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        from betaDomain: String = "dev.atoll.Atoll",
        to currentDomain: String = "com.givdul.skerry",
        using defaults: UserDefaults = .standard
    ) throws {
        let destination = homeDirectory.appendingPathComponent(stateDirectoryName, isDirectory: true)
        let marker = destination.appendingPathComponent(completionMarkerName)
        guard !isRegularFile(marker, fileManager: fileManager) else { return }

        try migrateState(
            homeDirectory: homeDirectory,
            destination: destination,
            fileManager: fileManager
        )
        try migrateUserDefaults(from: betaDomain, to: currentDomain, using: defaults)
        try PrivateStorage.writeAtomically(
            Data("complete\n".utf8),
            to: marker,
            fileManager: fileManager,
            hardenDirectory: true
        )
    }

    /// Copies beta-owned state without overwriting anything already written by Skerry.
    /// The old tree remains available for rollback; sockets and command bridges are
    /// deliberately regenerated instead of copied.
    private static func migrateState(
        homeDirectory: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let source = homeDirectory.appendingPathComponent(betaStateDirectoryName, isDirectory: true)
        guard isDirectory(source, fileManager: fileManager) else { return }

        try ensureDirectory(destination, fileManager: fileManager)

        for name in files {
            try copyIfMissing(
                from: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name),
                fileManager: fileManager
            )
        }
        for name in directories {
            try copyTreeIfMissing(
                from: source.appendingPathComponent(name, isDirectory: true),
                to: destination.appendingPathComponent(name, isDirectory: true),
                fileManager: fileManager
            )
        }
    }

    private static func migrateUserDefaults(
        from betaDomain: String,
        to currentDomain: String,
        using defaults: UserDefaults
    ) throws {
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]

        for (key, value) in defaults.persistentDomain(forName: betaDomain) ?? [:]
        where current[key] == nil {
            current[key] = value
        }
        defaults.setPersistentDomain(current, forName: currentDomain)
        guard let stored = defaults.persistentDomain(forName: currentDomain),
              NSDictionary(dictionary: stored).isEqual(to: current) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func copyTreeIfMissing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        guard isDirectory(source, fileManager: fileManager) else { return }
        try ensureDirectory(destination, fileManager: fileManager)
        for child in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if isDirectory(child, fileManager: fileManager) {
                try copyTreeIfMissing(from: child, to: target, fileManager: fileManager)
            } else {
                try copyIfMissing(from: child, to: target, fileManager: fileManager)
            }
        }
    }

    private static func copyIfMissing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: destination.path),
              isRegularFile(source, fileManager: fileManager) else { return }
        try ensureDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try fileManager.copyItem(at: source, to: destination)
        try PrivateStorage.hardenFile(at: destination, fileManager: fileManager)
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard isDirectory(url, fileManager: fileManager) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try PrivateStorage.ensureDirectory(at: url, fileManager: fileManager)
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
