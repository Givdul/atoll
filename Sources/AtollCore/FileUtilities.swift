import Foundation

struct RecentFile {
    var url: URL
    var modifiedAt: Date
}

enum FileUtilities {
    static func fileModificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    static func existingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func recentFiles(
        under root: URL,
        extensions allowedExtensions: Set<String>,
        maxFiles: Int,
        scanCap: Int = 8_000
    ) -> [RecentFile] {
        guard existingDirectory(root) else {
            return []
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [RecentFile] = []
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > scanCap {
                break
            }

            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else {
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else {
                continue
            }

            files.append(RecentFile(url: url, modifiedAt: values?.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map { $0 }
    }

    static func tailLines(from url: URL, maxBytes: UInt64 = 512_000, maxLines: Int = 80) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }

        defer {
            try? handle.close()
        }

        let end = (try? handle.seekToEnd()) ?? 0
        let offset = end > maxBytes ? end - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let string = String(data: data, encoding: .utf8) else {
            return []
        }

        return string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(maxLines)
            .map(String.init)
    }

    static func headLines(from url: URL, maxBytes: Int = 64_000, maxLines: Int = 40) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }

        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: maxBytes), let string = String(data: data, encoding: .utf8) else {
            return []
        }

        return string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
    }

    static func directoryChildren(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
