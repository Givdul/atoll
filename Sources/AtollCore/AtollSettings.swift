import Foundation

public struct AtollSettings: Codable, Sendable {
    public var enabled: Bool
    public var screenMode: String
    public var testMode: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled
        case screenMode
        case testMode
    }

    public init(
        enabled: Bool = true,
        screenMode: String = "primary",
        testMode: Bool = false
    ) {
        self.enabled = enabled
        self.screenMode = screenMode
        self.testMode = testMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.screenMode = try container.decodeIfPresent(String.self, forKey: .screenMode) ?? "primary"
        self.testMode = try container.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let directory: URL
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let directory = homeDirectory.appendingPathComponent(".atoll", isDirectory: true)
        self.directory = directory
        self.url = directory.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> AtollSettings {
        try? PrivateStorage.ensureDirectory(at: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try? PrivateStorage.hardenFile(at: url)
        }
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(AtollSettings.self, from: data) else {
            return AtollSettings()
        }
        return settings
    }

    public func save(_ settings: AtollSettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        try? PrivateStorage.writeAtomically(data, to: url, hardenDirectory: true)
    }
}
