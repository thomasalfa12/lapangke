import Darwin
import Foundation

public struct Advice: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable { case good, info, warning }
    public var id: String { title }
    public var level: Level
    public var title: String
    public var detail: String
    public var command: String?
}

public struct VolumeInfo: Identifiable, Codable, Sendable, Hashable {
    public var id: String { uuid ?? mountPath }
    public var name: String
    public var mountPath: String
    public var uuid: String?
    public var formatName: String
    public var fsType: String
    public var isInternal: Bool
    public var isEjectable: Bool
    public var total: Int64
    public var free: Int64
    public var busProtocol: String?
    public var solidState: Bool?
    public var ownersEnabled: Bool?
    public var encrypted: Bool?
    public var smart: SmartInfo?
    public var deviceIdentifier: String?

    public var isAPFS: Bool { fsType == "apfs" }
    public var supportsDevWork: Bool { fsType == "apfs" || fsType == "hfs" }
    public var advice: [Advice] { VolumeAdvisor.advice(for: self) }
}

public enum VolumeService {
    /// Volume eksternal yang terlihat di Finder (SSD/HDD/flashdisk), dengan detail dari diskutil.
    public static func externalVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsRootFileSystem != true,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            return info(for: url, values: values)
        }
    }

    static func info(for url: URL, values: URLResourceValues) -> VolumeInfo {
        let plist = DiskInspector.diskutilInfo(url.path) ?? [:]
        var statfsInfo = statfs()
        var fsType = (plist["FilesystemType"] as? String)?.lowercased() ?? ""
        if fsType.isEmpty, statfs(url.path, &statfsInfo) == 0 {
            fsType = withUnsafePointer(to: &statfsInfo.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
        }
        let encrypted = (plist["Encryption"] as? Bool) ?? (plist["FileVault"] as? Bool)
        return VolumeInfo(
            name: values.volumeName ?? url.lastPathComponent, mountPath: url.path, uuid: values.volumeUUIDString,
            formatName: (plist["FilesystemUserVisibleName"] as? String) ?? values.volumeLocalizedFormatDescription ?? fsType,
            fsType: fsType, isInternal: values.volumeIsInternal ?? false,
            isEjectable: values.volumeIsEjectable ?? values.volumeIsRemovable ?? true,
            total: Int64(values.volumeTotalCapacity ?? 0), free: Int64(values.volumeAvailableCapacity ?? 0),
            busProtocol: plist["BusProtocol"] as? String, solidState: plist["SolidState"] as? Bool,
            ownersEnabled: plist["GlobalPermissionsEnabled"] as? Bool, encrypted: encrypted,
            smart: DiskInspector.smart(from: plist), deviceIdentifier: plist["DeviceIdentifier"] as? String
        )
    }

    public static func volume(uuid: String?) -> VolumeInfo? {
        guard let uuid else { return nil }
        return externalVolumes().first { $0.uuid == uuid }
    }

    public static func eject(_ volume: VolumeInfo) -> ShellResult {
        Shell.run("/usr/sbin/diskutil", ["eject", volume.mountPath], timeout: 60)
    }

    public struct SpeedResult: Sendable {
        public var writeMBps: Double
        public var readMBps: Double
    }

    /// Uji baca/tulis sekuensial tanpa cache (F_NOCACHE). Membuat lalu menghapus file sementara.
    public static func speedTest(at directory: URL, megabytes: Int = 1024) throws -> SpeedResult {
        let path = directory.appendingPathComponent(".lapangke-speedtest-\(UUID().uuidString)").path
        defer { unlink(path) }
        let chunk = 8 << 20
        let count = max(1, megabytes / 8)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, chunk)

        let writeFD = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard writeFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(writeFD, F_NOCACHE, 1)
        let writeStart = Date()
        for _ in 0..<count {
            guard write(writeFD, buffer, chunk) == chunk else {
                close(writeFD)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
        _ = fcntl(writeFD, F_FULLFSYNC)
        close(writeFD)
        let writeSeconds = Date().timeIntervalSince(writeStart)

        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = fcntl(readFD, F_NOCACHE, 1)
        let readStart = Date()
        while read(readFD, buffer, chunk) > 0 {}
        close(readFD)
        let readSeconds = Date().timeIntervalSince(readStart)

        let megabytesWritten = Double(count * chunk) / 1_000_000
        return SpeedResult(writeMBps: megabytesWritten / max(writeSeconds, 0.001), readMBps: megabytesWritten / max(readSeconds, 0.001))
    }
}

/// Saran konfigurasi SSD eksternal untuk kerja iOS/Android.
public enum VolumeAdvisor {
    public static func advice(for volume: VolumeInfo) -> [Advice] {
        var result: [Advice] = []
        switch volume.fsType {
        case "apfs":
            result.append(Advice(level: .good, title: "Format APFS", detail: "Format terbaik untuk SSD di Mac: cepat, mendukung symlink, izin file, clone, dan snapshot."))
        case "hfs":
            result.append(Advice(level: .info, title: "Format Mac OS Extended", detail: "Berfungsi, tapi APFS lebih cepat dan andal untuk SSD. Pertimbangkan format ulang ke APFS saat SSD kosong."))
        case "exfat", "msdos":
            result.append(Advice(level: .warning, title: "Format \(volume.formatName) — tidak cocok untuk kerja dev",
                                 detail: "Tanpa journaling dan izin file Unix: repo git, symlink, cache Gradle/Xcode bisa rusak bila SSD tercabut. Pakai hanya untuk foto/video, atau pindahkan isinya dulu lalu format ulang ke APFS lewat Disk Utility › Erase (isi SSD terhapus)."))
        default:
            result.append(Advice(level: .info, title: "Format \(volume.formatName)", detail: "Format ini tidak umum dipakai di Mac."))
        }
        if volume.supportsDevWork, volume.ownersEnabled == false {
            result.append(Advice(level: .warning, title: "Ownership diabaikan",
                                 detail: "macOS mengabaikan pemilik file di volume ini. Untuk proyek & cache dev sebaiknya diaktifkan agar izin executable dan git konsisten.",
                                 command: "sudo diskutil enableOwnership \"\(volume.mountPath)\""))
        }
        if volume.solidState == false {
            result.append(Advice(level: .warning, title: "Bukan SSD", detail: "Disk berputar (HDD) terlalu lambat untuk build. Pakai untuk arsip & backup saja."))
        }
        if let bus = volume.busProtocol {
            let fast = ["Thunderbolt", "PCI-Express", "PCI"].contains { bus.contains($0) }
            result.append(Advice(level: fast ? .good : .info, title: "Koneksi \(bus)",
                                 detail: fast ? "Jalur cepat (Thunderbolt/USB4), cocok untuk proyek & cache build."
                                     : "USB biasa cukup untuk arsip & cache. Untuk menaruh proyek/DerivedData, enclosure Thunderbolt/USB4 NVMe 2–4× lebih cepat."))
        }
        if volume.encrypted == false, volume.supportsDevWork {
            result.append(Advice(level: .info, title: "Tidak terenkripsi",
                                 detail: "Kode, keystore, dan sesi login di SSD bisa dibaca orang lain bila SSD hilang. Pertimbangkan APFS (Encrypted)."))
        }
        if volume.total > 0, Double(volume.free) / Double(volume.total) < 0.1 {
            result.append(Advice(level: .warning, title: "SSD hampir penuh", detail: "Sisakan minimal 10–15% agar kinerja SSD tetap stabil."))
        }
        if let percent = volume.smart?.percentageUsed, percent >= 80 {
            result.append(Advice(level: .warning, title: "Keausan SSD \(percent)%", detail: "Siapkan backup & pengganti."))
        }
        return result
    }
}
