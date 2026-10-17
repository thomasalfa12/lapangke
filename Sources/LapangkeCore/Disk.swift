import Darwin
import Foundation

public struct SmartInfo: Codable, Sendable, Hashable {
    /// Perkiraan keausan NVMe (0–100+%).
    public var percentageUsed: Int?
    public var dataWrittenBytes: Int64?
    public var powerOnHours: Int?
    public var availableSpare: Int?
    public var status: String?
    public var unsafeShutdowns: Int?
}

public struct APFSVolumeUsage: Codable, Sendable, Hashable {
    public var name: String
    public var role: String
    public var bytes: Int64
}

public struct DiskSnapshot: Codable, Sendable {
    public var total: Int64
    /// Benar-benar kosong.
    public var available: Int64
    /// Kosong + yang bisa dibebaskan macOS sendiri (purgeable).
    public var availableImportant: Int64
    public var apfsVolumes: [APFSVolumeUsage]
    public var smart: SmartInfo?
    public var swapUsed: Int64
    public var physicalMemory: Int64
    public var hasFullDiskAccess: Bool

    public var used: Int64 { max(0, total - available) }
    public var purgeable: Int64 { max(0, availableImportant - available) }
}

public enum DiskInspector {
    public static func snapshot(home: URL, includeSmart: Bool = true) -> DiskSnapshot {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? home.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? Int64(available)

        let info = includeSmart ? diskutilInfo("/") : nil
        return DiskSnapshot(
            total: total, available: available, availableImportant: important,
            apfsVolumes: apfsVolumes(), smart: info.flatMap(smart(from:)), swapUsed: swapUsed(),
            physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory), hasFullDiskAccess: hasFullDiskAccess()
        )
    }

    /// Ruang kosong saja (murah, untuk menu bar).
    public static func freeSpace(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (available: Int64, total: Int64) {
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    /// TCC.db sistem hanya bisa dibaca bila Full Disk Access aktif.
    public static func hasFullDiskAccess() -> Bool {
        if let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") {
            try? handle.close()
            return true
        }
        return false
    }

    public static func diskutilInfo(_ target: String) -> [String: Any]? {
        let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", target], timeout: 20)
        guard result.ok, let data = result.stdout.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    public static func smart(from info: [String: Any]) -> SmartInfo? {
        let keys = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any]
        guard keys != nil || info["SMARTStatus"] != nil else { return nil }
        func int(_ key: String) -> Int? { (keys?[key] as? NSNumber)?.intValue }
        // NVMe: satu "data unit" = 1000 × 512 byte.
        let written = (keys?["DATA_UNITS_WRITTEN_0"] as? NSNumber).map { $0.int64Value * 512_000 }
        return SmartInfo(
            percentageUsed: int("PERCENTAGE_USED"), dataWrittenBytes: written, powerOnHours: int("POWER_ON_HOURS_0"),
            availableSpare: int("AVAILABLE_SPARE"), status: info["SMARTStatus"] as? String, unsafeShutdowns: int("UNSAFE_SHUTDOWNS_0")
        )
    }

    /// Volume di container APFS yang sama dengan disk boot (System, Data, Preboot, VM, …).
    public static func apfsVolumes() -> [APFSVolumeUsage] {
        let container = diskutilInfo("/")?["APFSContainerReference"] as? String
        let result = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 30)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [] }
        let target = containers.first { ($0["ContainerReference"] as? String) == container } ?? containers.first
        let volumes = target?["Volumes"] as? [[String: Any]] ?? []
        return volumes.map { volume in
            APFSVolumeUsage(
                name: volume["Name"] as? String ?? "?",
                role: (volume["Roles"] as? [String])?.first ?? "",
                bytes: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    public static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }
}
