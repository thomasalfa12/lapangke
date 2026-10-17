import Darwin
import Foundation

public struct SizeResult: Sendable, Equatable {
    /// Ukuran yang benar-benar terpakai di disk (allocated).
    public var bytes: Int64 = 0
    /// Ukuran logis isi file (untuk verifikasi salinan antar-volume).
    public var logicalBytes: Int64 = 0
    public var files: Int = 0
    public var mountPoints: [String] = []
    public var unreadable: Int = 0
    public var newest: Date?
}

public enum SizeCalculator {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
    ]
    private static let keySet = Set(keys)

    /// Menghitung ukuran tanpa mengikuti symlink dan tanpa masuk ke volume lain
    /// (mis. `~/Library/Developer/CoreDevice/DeviceFS` = isi iPad yang tersambung).
    public static func measure(_ url: URL, trackNewest: Bool = false, ignoreAppleDouble: Bool = false) -> SizeResult {
        var result = SizeResult()
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            result.unreadable = 1
            return result
        }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return result }
        if type != S_IFDIR {
            result.bytes = Int64(st.st_blocks) * 512
            result.logicalBytes = Int64(st.st_size)
            result.files = 1
            result.newest = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            return result
        }

        let nestedMounts = Set(MountTable.mountPoints(inside: url.path))
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            result.unreadable = 1
            return result
        }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if values.isVolume == true || nestedMounts.contains(child.path) {
                    result.mountPoints.append(child.path)
                    enumerator.skipDescendants()
                }
                continue
            }
            if ignoreAppleDouble, child.lastPathComponent.hasPrefix("._") { continue }
            result.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            result.logicalBytes += Int64(values.fileSize ?? 0)
            result.files += 1
            if trackNewest, let modified = values.contentModificationDate,
               modified > (result.newest ?? .distantPast) {
                result.newest = modified
            }
        }
        result.unreadable = unreadable
        return result
    }

    /// Mengukur banyak path sekaligus (paralel, dibatasi agar SSD tidak kewalahan).
    public static func measureAll(_ urls: [URL], trackNewest: Bool = false, concurrency: Int = 6) async -> [URL: SizeResult] {
        var results: [URL: SizeResult] = [:]
        await withTaskGroup(of: (URL, SizeResult).self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<concurrency {
                guard let url = iterator.next() else { break }
                group.addTask { (url, measure(url, trackNewest: trackNewest)) }
            }
            while let (url, size) = await group.next() {
                results[url] = size
                if let next = iterator.next() {
                    group.addTask { (next, measure(next, trackNewest: trackNewest)) }
                }
            }
        }
        return results
    }
}

/// Daftar mount point dari kernel (`getfsstat`), termasuk mount tersembunyi seperti DeviceFS.
public enum MountTable {
    public static func all() -> [String] {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard count > 0 else { return [] }
        let capacity = count + 8
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let filled = Int(getfsstat(buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        guard filled > 0 else { return [] }
        return (0..<filled).map { index in
            withUnsafePointer(to: &buffer[index].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    /// Mount point yang sama dengan atau berada di dalam `path`.
    public static func mountPoints(inside path: String) -> [String] {
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return all().filter { $0 == base || $0.hasPrefix(base + "/") }
    }
}

public enum PathTools {
    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Isi langsung sebuah folder (termasuk file tersembunyi), tanpa mengikuti symlink.
    public static func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []
    }

    /// `a` adalah `b` atau leluhur `b`.
    public static func isSameOrAncestor(_ a: String, of b: String) -> Bool {
        a == b || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    /// Pencocokan wildcard sederhana gaya shell (`AndroidStudio*`).
    public static func matches(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    /// Bandingkan versi numerik: "27.0.1" > "27.0".
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let b = rhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
