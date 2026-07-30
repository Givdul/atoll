import Foundation

public enum TopsideMigration {
    package static let stateDirectoryName = ".topside"
    package static let skerryStateDirectoryName = ".skerry"
    package static let atollStateDirectoryName = ".atoll"
    package static let completionMarkerName = ".legacy-identity-migration-v1-complete"

    private static let files = [
        "config.json",
        "lifecycle-sessions.json",
        "lifecycle-runtime-evidence.json",
        "trial-entitlement-v1.json"
    ]
    private static let directories = [
        "lifecycle-events",
        "backups"
    ]

    /// Migrates known legacy state and defaults exactly once. Existing Topside
    /// values win, followed by Skerry and then Atoll. Legacy trees remain intact.
    public static func migrateIfNeeded(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        skerryDomain: String = "com.givdul.skerry",
        atollDomain: String = "dev.atoll.Atoll",
        topsideDomain: String = "com.givdul.topside",
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
        try migrateUserDefaults(
            from: [skerryDomain, atollDomain],
            to: topsideDomain,
            using: defaults
        )
        try PrivateStorage.writeAtomically(
            Data("complete\n".utf8),
            to: marker,
            fileManager: fileManager,
            hardenDirectory: true
        )
    }

    private static func migrateState(
        homeDirectory: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let sources = [skerryStateDirectoryName, atollStateDirectoryName]
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0, fileManager: fileManager) }
        guard !sources.isEmpty else { return }

        try ensureDirectory(destination, fileManager: fileManager)
        for source in sources {
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
    }

    private static func migrateUserDefaults(
        from sourceDomains: [String],
        to currentDomain: String,
        using defaults: UserDefaults
    ) throws {
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        for sourceDomain in sourceDomains {
            for (key, value) in defaults.persistentDomain(forName: sourceDomain) ?? [:]
            where current[key] == nil {
                current[key] = value
            }
        }
        defaults.setPersistentDomain(current, forName: currentDomain)
        let stored = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard NSDictionary(dictionary: stored).isEqual(to: current) else {
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
