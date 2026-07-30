import Darwin
import Foundation

/// Permission and atomic-write policy for Topside-owned state under `~/.topside`.
package enum PrivateStorage {
    package typealias FilePermissionSetter = @Sendable (URL) throws -> Void

    package static let directoryPermissions: Int = 0o700
    package static let filePermissions: Int = 0o600

    package static func ensureDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: directoryPermissions)]
        )
        try setPermissions(directoryPermissions, at: url, fileManager: fileManager)
    }

    package static func hardenFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try setPermissions(filePermissions, at: url, fileManager: fileManager)
    }

    /// Writes a fully hardened temporary file before atomically replacing the
    /// destination. If permission hardening fails, the old destination remains.
    package static func writeAtomically(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default,
        hardenDirectory: Bool = false,
        filePermissionSetter: FilePermissionSetter? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        if hardenDirectory || !fileManager.fileExists(atPath: directory.path) {
            try ensureDirectory(at: directory, fileManager: fileManager)
        }

        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: .atomic)
        if let filePermissionSetter {
            try filePermissionSetter(temporaryURL)
        } else {
            try hardenFile(at: temporaryURL, fileManager: fileManager)
        }

        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func setPermissions(
        _ permissions: Int,
        at url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let stored = attributes[.posixPermissions] as? NSNumber,
              stored.intValue & 0o777 == permissions else {
            throw POSIXError(.EPERM)
        }
    }
}
