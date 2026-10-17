import Foundation

public enum GuardError: LocalizedError, Equatable {
    case notDeletable(String)
    case invalidPath(String)
    case outsideAllowedRoots(String)
    case protectedPath(String)
    case containsMountPoint(String)
    case isRepository(String)
    case missing(String)
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case let .notDeletable(why): "Tidak boleh dihapus: \(why)"
        case let .invalidPath(path): "Path tidak valid: \(path)"
        case let .outsideAllowedRoots(path): "Di luar area yang boleh dibersihkan: \(path.abbreviatingHome)"
        case let .protectedPath(path): "Dilindungi (data penting): \(path.abbreviatingHome)"
        case let .containsMountPoint(mount): "Berisi volume lain yang ter-mount (\(mount.abbreviatingHome)) — dilewati agar isi perangkat tidak ikut terhapus"
        case let .isRepository(path): "Ini repository git (kode sumber): \(path.abbreviatingHome)"
        case let .missing(path): "Sudah tidak ada: \(path.abbreviatingHome)"
        case let .invalidIdentifier(id): "ID tidak valid: \(id)"
        }
    }
}

/// Lapisan pengaman terakhir sebelum apa pun dihapus. Semua aksi Cleaner/Offload lewat sini,
/// jadi bug di sebuah rule tidak bisa berujung menghapus kode, kredensial, atau isi perangkat.
public struct SafetyGuard: Sendable {
    public let home: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.path
    }

    /// Folder wadah: isinya boleh dibersihkan per bagian, foldernya sendiri tidak.
    static let protectedExact: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Logs", "Library/Developer", "Library/Developer/Xcode",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices",
        "Library/Android", "Library/Android/sdk", ".gradle", ".gradle/caches", ".gradle/wrapper",
        ".gradle/wrapper/dists", ".android", ".npm", ".cargo", ".rustup", ".nvm", ".codex",
        ".codex/sessions", ".gemini", ".config", ".local", ".cache", "Applications",
        "Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures", "Public",
    ]

    /// Tidak pernah disentuh, termasuk isinya.
    static let protectedPrefixes: [String] = [
        ".ssh", ".gnupg", ".aws", ".kube", ".docker/config.json", ".config/gh", ".netrc",
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Messages", "Library/Mail", "Library/Photos", "Library/Preferences",
        "Library/Developer/CoreDevice", "Library/Application Support/com.apple.TCC",
        "Library/Logs/DiagnosticReports", "Library/Android/sdk/platform-tools",
        "Library/Android/sdk/licenses", ".android/debug.keystore", ".android/adbkey",
        ".claude", "Library/Application Support/Claude", ".codex/auth.json", ".codex/config.toml",
        ".codex/worktrees", ".gradle/gradle.properties", ".gradle/init.d",
    ]

    /// Nama file yang selalu dianggap rahasia/penting (keystore rilis, sertifikat, env).
    static let secretSuffixes = [
        ".jks", ".keystore", ".p12", ".p8", ".pem", ".key", ".mobileprovision",
        ".provisionprofile", ".keychain", ".keychain-db", ".photoslibrary",
    ]

    public func validate(_ item: CleanupItem) throws {
        guard item.safety.isDeletable else { throw GuardError.notDeletable(item.safety.label) }
        switch item.action {
        case .manual:
            throw GuardError.notDeletable("butuh langkah manual")
        case let .simulatorErase(udid), let .simulatorDelete(udid):
            try validateUUID(udid)
        case let .simulatorRuntimeDelete(identifier):
            try validateUUID(identifier)
        case .emptyTrash:
            guard item.path == home + "/.Trash" else { throw GuardError.invalidPath(item.path) }
        case .delete:
            try validate(path: item.path)
        case .trash:
            try validate(path: item.path, allowApplicationBundle: true)
        }
    }

    public func validate(path raw: String, allowRepository: Bool = false, allowApplicationBundle: Bool = false) throws {
        guard raw.hasPrefix("/"), !raw.contains("/../"), !raw.hasSuffix("/.."), !raw.contains("\0") else {
            throw GuardError.invalidPath(raw)
        }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        let name = (path as NSString).lastPathComponent.lowercased()

        if name.hasPrefix(".env") || Self.secretSuffixes.contains(where: { name.hasSuffix($0) }) {
            throw GuardError.protectedPath(path)
        }

        if allowApplicationBundle, try validateApplicationBundle(path) { return }

        guard path.hasPrefix(home + "/") else { throw GuardError.outsideAllowedRoots(path) }
        let relative = String(path.dropFirst(home.count + 1))
        let depth = relative.split(separator: "/").count
        guard depth >= 2, !Self.protectedExact.contains(relative) else { throw GuardError.protectedPath(path) }
        for prefix in Self.protectedPrefixes where relative == prefix || relative.hasPrefix(prefix + "/") {
            throw GuardError.protectedPath(path)
        }
        guard PathTools.exists(path) else { throw GuardError.missing(path) }

        // Symlink: yang dihapus hanya tautannya, bukan tujuannya.
        if PathTools.isSymlink(path) { return }
        if PathTools.isDirectory(path) {
            if !allowRepository, PathTools.exists(path + "/.git") { throw GuardError.isRepository(path) }
            if let mount = MountTable.mountPoints(inside: path).first { throw GuardError.containsMountPoint(mount) }
        }
    }

    /// `/Applications/X.app` atau `~/Applications/X.app` milik pihak ketiga.
    private func validateApplicationBundle(_ path: String) throws -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard path.hasSuffix(".app"), parent == "/Applications" || parent == home + "/Applications" else {
            return false
        }
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        let bundleID = plist?["CFBundleIdentifier"] as? String ?? ""
        if bundleID.hasPrefix("com.apple.") { throw GuardError.protectedPath(path) }
        guard PathTools.exists(path) else { throw GuardError.missing(path) }
        return true
    }

    private func validateUUID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else { throw GuardError.invalidIdentifier(value) }
    }
}
