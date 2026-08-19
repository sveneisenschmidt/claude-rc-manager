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
}

struct AppConfig: Codable, Equatable {
    var version = 1
    var folders: [FolderConfig] = []
}
