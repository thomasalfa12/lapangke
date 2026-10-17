import Foundation

/// File besar milik pengguna (video, image disk, arsip, mesin virtual) di folder pribadi.
/// Library, folder tersembunyi, folder proyek, dan isi paket (.app, .photoslibrary) dilewati.
public enum LargeFileFinder {
    public static let threshold: Int64 = 300 * MB

    static let kinds: [(String, Set<String>)] = [
        ("Video", ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "braw", "r3d"]),
        ("Image disk", ["dmg", "iso", "img", "sparseimage", "sparsebundle"]),
        ("Arsip", ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2"]),
        ("Mesin virtual", ["vmdk", "vdi", "qcow2", "vhd", "vhdx", "utm", "pvm"]),
        ("Audio", ["wav", "aif", "aiff", "flac", "caf"]),
        ("Foto RAW", ["cr2", "cr3", "nef", "arw", "raf", "dng"]),
        ("File desain", ["psd", "psb", "ai", "sketch", "fig", "blend", "prproj", "aep"]),
        ("Installer", ["pkg", "apk", "aab", "ipa", "exe", "msi", "xip"]),
    ]

    static func kind(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.1.contains(ext) }?.0 ?? "File"
    }

    /// Folder level teratas di home yang dipindai (Downloads punya aturan sendiri).
    static func roots(in context: ScanContext) -> [URL] {
        let skipped: Set<String> = ["Library", "Applications", "Downloads", "Public"]
        let devRoots = resolvedDevRoots(context)
        return PathTools.children(of: context.home).filter { url in
            let name = url.lastPathComponent
            let path = url.resolvingSymlinksInPath().path
            return PathTools.isDirectory(url.path) && !PathTools.isSymlink(url.path) && !name.hasPrefix(".")
                && !skipped.contains(name) && !devRoots.contains { PathTools.isSameOrAncestor($0, of: path) || PathTools.isSameOrAncestor(path, of: $0) }
        }
    }

    /// Path folder proyek dibandingkan setelah symlink di-resolve (mis. /var → /private/var).
    static func resolvedDevRoots(_ context: ScanContext) -> Set<String> {
        Set(context.devRoots.map { $0.resolvingSymlinksInPath().path })
    }

    public static func find(in context: ScanContext, threshold: Int64 = threshold) -> [CleanupItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isVolumeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let devRoots = resolvedDevRoots(context)
        var items: [CleanupItem] = []
        for root in roots(in: context) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    // Volume lain & folder proyek (artefaknya dinilai provider proyek).
                    if values.isVolume == true || devRoots.contains(url.resolvingSymlinksInPath().path) { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, let size = values.totalFileAllocatedSize, Int64(size) >= threshold else { continue }
                let folder = url.deletingLastPathComponent().path.abbreviatingHome
                let modified = values.contentModificationDate
                let age = modified.map { "diubah \(Formatters.relative($0, now: context.now))" } ?? ""
                items.append(CleanupItem(
                    title: url.lastPathComponent,
                    detail: "\(kind(of: url)) berukuran besar di \(folder), \(age). Hapus bila sudah tidak dibutuhkan, atau pindahkan ke SSD.",
                    path: url.path, bytes: Int64(size), category: .personal, safety: .review, action: .trash,
                    lastActivity: modified, offloadable: true
                ))
            }
        }
        return items
    }
}
