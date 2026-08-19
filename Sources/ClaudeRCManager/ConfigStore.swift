import Foundation

/// Persists AppConfig as JSON. Atomic writes; a corrupt file is moved to
/// config.json.bak and an empty config returned (spec: ConfigStore).
final class ConfigStore {
    enum LoadResult: Equatable {
        case fresh(AppConfig)
        case recoveredFromCorrupt(AppConfig)
    }

    private let fileURL: URL
    private let backupURL: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude RC Manager")
    }

    init(directory: URL = ConfigStore.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("config.json")
        backupURL = directory.appendingPathComponent("config.json.bak")
    }

    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .fresh(AppConfig())
        }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return .fresh(config)
        }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return .recoveredFromCorrupt(AppConfig())
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Atomic: write to temp in the same directory, then rename over.
        try data.write(to: fileURL, options: .atomic)
    }
}
