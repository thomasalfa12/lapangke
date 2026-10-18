import Darwin
import Foundation

public struct MapNode: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bytes: Int64
    /// Jumlah folder yang tidak bisa dibaca (biasanya butuh Full Disk Access).
    public var unreadable: Int
    public var children: [MapNode]?
}

public struct StorageMap: Codable, Sendable {
    public var createdAt: Date
    public var roots: [MapNode]
    public var duration: TimeInterval
}

/// Peta penyimpanan: satu kali jalan menelusuri tiap root, ukuran dijumlahkan ke folder level 1 & 2.
public enum StorageMapper {
    public static func defaultRoots(home: URL) -> [URL] {
        [home, URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Library"),
         URL(fileURLWithPath: "/System/Library/AssetsV2"), URL(fileURLWithPath: "/opt/homebrew"),
         URL(fileURLWithPath: "/usr/local"), URL(fileURLWithPath: "/private/var/folders")]
            .filter { PathTools.isDirectory($0.path) }
    }

    public static func map(roots: [URL], progress: @escaping @Sendable (String) -> Void = { _ in }) async -> StorageMap {
        let started = Date()
        var nodes: [MapNode] = []
        await withTaskGroup(of: MapNode.self) { group in
            for root in roots {
                group.addTask {
                    progress("Memetakan \(root.path.abbreviatingHome)…")
                    return mapTree(root)
                }
            }
            for await node in group { nodes.append(node) }
        }
        return StorageMap(createdAt: started, roots: nodes.sorted { $0.bytes > $1.bytes }, duration: Date().timeIntervalSince(started))
    }

    final class Bucket {
        var bytes: Int64 = 0
        var unreadable = 0
        var children: [String: Bucket] = [:]
    }

    static let maxDepth = 3

    static func mapTree(_ root: URL) -> MapNode {
        let rootPath = root.standardizedFileURL.path
        let base = rootPath == "/" ? "/" : rootPath + "/"
        // realpath(), bukan resolvingSymlinksInPath(): yang terakhir justru membuang awalan /private.
        let resolvedRoot = realpath(rootPath, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? rootPath
        let resolvedBase = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        let top = Bucket()
        let mounts = Set(MountTable.mountPoints(inside: rootPath).filter { $0 != rootPath })
        let keys: [URLResourceKey] = [.isDirectoryKey, .isVolumeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)

        final class ErrorCounter { var failedPaths: [String] = [] }
        let errors = ErrorCounter()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, _ in
            errors.failedPaths.append(url.path)
            return true
        }) else {
            return MapNode(name: root.lastPathComponent, path: rootPath, bytes: 0, unreadable: 1, children: nil)
        }

        /// Rantai bucket level 1…maxDepth untuk sebuah path (folder induk dari file).
        func chain(for path: String) -> [Bucket] {
            // Enumerator bisa mengembalikan path ter-resolve (/var → /private/var); cocokkan keduanya.
            let prefix = [base, resolvedBase].first { path.hasPrefix($0) }
            let relative = prefix.map { path.dropFirst($0.count) } ?? Substring(path)
            let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
            var result: [Bucket] = []
            var current = top
            // Komponen terakhir adalah file itu sendiri; hanya folder induknya yang jadi bucket (kecuali level 1).
            for (index, part) in parts.prefix(maxDepth).enumerated() {
                if index > 0, index == parts.count - 1 { break }
                let key = String(part)
                let next = current.children[key, default: Bucket()]
                current.children[key] = next
                result.append(next)
                current = next
            }
            return result
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if values.isVolume == true || mounts.contains(url.path) { enumerator.skipDescendants() }
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            top.bytes += size
            for bucket in chain(for: url.path) { bucket.bytes += size }
        }
        for path in errors.failedPaths {
            top.unreadable += 1
            for bucket in chain(for: path + "/x") { bucket.unreadable += 1 }
        }

        func node(_ name: String, _ path: String, _ bucket: Bucket, depth: Int) -> MapNode {
            let kids: [MapNode]? = depth >= maxDepth || bucket.children.isEmpty ? nil : bucket.children
                .map { node($0.key, path == "/" ? "/\($0.key)" : "\(path)/\($0.key)", $0.value, depth: depth + 1) }
                .filter { $0.bytes >= 5 * MB || $0.unreadable > 0 }
                .sorted { $0.bytes > $1.bytes }
            return MapNode(name: name, path: path, bytes: bucket.bytes, unreadable: bucket.unreadable, children: kids)
        }
        let name = rootPath == NSHomeDirectory() ? "Home (~)" : rootPath
        return node(name, rootPath, top, depth: 0)
    }

    public static func save(_ map: StorageMap) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(map) { try? data.write(to: AppPaths.storageMap, options: .atomic) }
    }

    public static func load() -> StorageMap? {
        guard let data = try? Data(contentsOf: AppPaths.storageMap) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StorageMap.self, from: data)
    }
}
