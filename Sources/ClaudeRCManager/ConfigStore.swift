import Foundation

/// Persists AppConfig as JSON. Atomic writes; a corrupt file is moved to
/// config.json.bak and an empty config returned (spec: ConfigStore).
/// Main-thread use only; no internal synchronization.
final class ConfigStore {
    enum LoadResult: Equatable {
        case loaded(AppConfig)
        case recoveredFromCorrupt(AppConfig)
        case unreadable(AppConfig)
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
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if Self.isFileNotFound(error) {
                return .loaded(AppConfig())
            }
            // File exists but couldn't be read (permissions, I/O error, etc.)
            // — treat like a corrupt file rather than silently starting fresh.
            return recoverFromCorrupt()
        }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return .loaded(config)
        }
        return recoverFromCorrupt()
    }

    /// Attempts to preserve the unreadable/corrupt file by moving it aside.
    /// Only reports `.recoveredFromCorrupt` when that move actually
    /// succeeds; if it fails, the original file is left in place and
    /// `.unreadable` is returned so callers know not to overwrite it.
    private func recoverFromCorrupt() -> LoadResult {
        do {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return .recoveredFromCorrupt(AppConfig())
        } catch {
            return .unreadable(AppConfig())
        }
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isFileNotFound(underlying)
        }
        return false
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Atomic: write to temp in the same directory, then rename over.
        try data.write(to: fileURL, options: .atomic)
    }
}
