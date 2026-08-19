import Foundation

enum SpawnMode: String, Codable, CaseIterable {
    case sameDir = "same-dir"
    case worktree
    case session
}

enum PermissionMode: String, Codable, CaseIterable {
    case acceptEdits, auto, bypassPermissions, `default`, dontAsk, plan
}

struct FolderConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var name: String
    var spawnMode: SpawnMode = .sameDir
    var createSessionInDir = false
    var capacity = 32
    var permissionMode: PermissionMode?
    var extraArgs = ""
    var autostart = false
    var autoRestart = true

    init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, name, spawnMode, createSessionInDir, capacity, permissionMode, extraArgs, autostart, autoRestart
    }

    /// Tolerant decoding: only `path` is required. Every other field falls
    /// back to its default when missing, and the two enum fields degrade to
    /// their default (or nil) rather than failing the whole file when the
    /// raw value is unrecognized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        self.path = path
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? (path as NSString).lastPathComponent
        let spawnModeRaw = try container.decodeIfPresent(String.self, forKey: .spawnMode)
        spawnMode = spawnModeRaw.flatMap { SpawnMode(rawValue: $0) } ?? .sameDir
        createSessionInDir = try container.decodeIfPresent(Bool.self, forKey: .createSessionInDir) ?? false
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? 32
        let permissionModeRaw = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        permissionMode = permissionModeRaw.flatMap { PermissionMode(rawValue: $0) }
        extraArgs = try container.decodeIfPresent(String.self, forKey: .extraArgs) ?? ""
        autostart = try container.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
    }
}

struct AppConfig: Codable, Equatable {
    var version = 1
    var folders: [FolderConfig] = []

    init(version: Int = 1, folders: [FolderConfig] = []) {
        self.version = version
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case version, folders
    }

    /// Tolerant decoding: both fields fall back to their default when
    /// missing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        folders = try container.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
    }
}
