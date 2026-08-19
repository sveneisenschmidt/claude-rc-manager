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
        if var config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config.folders = Self.deduplicatingIDs(config.folders)
            return .loaded(config)
        }
        return recoverFromCorrupt()
    }

    /// A hand-edited (or hand-copied) config.json can repeat a folder id. Ids
    /// key the menu, the settings windows, and process lookup, so a duplicate
    /// would make one of the two folders unreachable. Keep the first
    /// occurrence, re-key the rest, preserve order.
    private static func deduplicatingIDs(_ folders: [FolderConfig]) -> [FolderConfig] {
        var seen: Set<UUID> = []
        return folders.map { folder in
            var folder = folder
            while !seen.insert(folder.id).inserted {
                folder.id = UUID()
            }
            return folder
        }
    }

    /// Attempts to preserve the unreadable/corrupt file by moving it aside.
    /// Only reports `.recoveredFromCorrupt` when that move actually
    /// succeeds; if it fails, the original file is left in place,
    /// `.unreadable` is returned, and save() refuses to run so the
    /// preserved file cannot be overwritten. An existing backup is only
    /// removed when the move fails on the name collision, so a failed move
    /// never destroys a good backup for nothing.
    private func recoverFromCorrupt() -> LoadResult {
        let fm = FileManager.default
        do {
            do {
                try fm.moveItem(at: fileURL, to: backupURL)
            } catch CocoaError.fileWriteFileExists {
                try fm.removeItem(at: backupURL)
                try fm.moveItem(at: fileURL, to: backupURL)
            }
            return .recoveredFromCorrupt(AppConfig())
        } catch {
            saveSuppressed = true
            return .unreadable(AppConfig())
        }
    }

    /// True after load() returned .unreadable: the on-disk file could not
    /// be read or preserved, so overwriting it would destroy data.
    private(set) var saveSuppressed = false

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

    struct SaveSuppressedError: Error {}

    func save(_ config: AppConfig) throws {
        guard !saveSuppressed else { throw SaveSuppressedError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Atomic: write to temp in the same directory, then rename over.
        try data.write(to: fileURL, options: .atomic)
    }
}

/// How the on-disk config fared at launch, as the UI needs to say it.
/// `.unreadable` is distinct from `.recoveredFromCorrupt`: the bad file
/// could not even be moved aside, so save() refuses to overwrite it and
/// every change is in-memory only.
enum ConfigHealth {
    case ok
    case recoveredFromCorrupt
    case unreadable
}

extension ConfigStore.LoadResult {
    /// Derived, not hand-mapped at the call site, so a new case cannot
    /// silently keep reporting a healthy config.
    var health: ConfigHealth {
        switch self {
        case .loaded: return .ok
        case .recoveredFromCorrupt: return .recoveredFromCorrupt
        case .unreadable: return .unreadable
        }
    }

    var config: AppConfig {
        switch self {
        case .loaded(let c), .recoveredFromCorrupt(let c), .unreadable(let c): return c
        }
    }
}
