import Foundation

public enum AppPaths {
    public static var support: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lapangke", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var activity: URL { support.appendingPathComponent("activity.jsonl") }
    public static var offloads: URL { support.appendingPathComponent("offloads.json") }
    public static var lastReport: URL { support.appendingPathComponent("last-report.json") }
    public static var storageMap: URL { support.appendingPathComponent("storage-map.json") }
}

public struct LapangkeSettings: Codable, Sendable, Equatable {
    /// Folder tempat proyek kode berada (relatif ke home boleh pakai `~`).
    public var devRoots: [String]
    /// Proyek yang tidak disentuh selama ini dianggap tidak aktif.
    public var inactiveDays: Int
    /// Ikon menu bar memerah bila ruang kosong di bawah angka ini.
    public var lowSpaceWarningGB: Int
    /// UUID volume SSD kerja yang dipilih.
    public var workVolumeUUID: String?
    /// Cache dev yang sudah dipindah ke SSD: `DevCache.rawValue` → folder tujuan.
    public var relocations: [String: String]

    public static let candidateRoots = [
        "~/builder", "~/Developer", "~/AndroidStudioProjects", "~/StudioProjects", "~/Projects",
        "~/projects", "~/Code", "~/code", "~/dev", "~/src", "~/Documents/GitHub", "~/XcodeProjects",
    ]

    public static var defaults: LapangkeSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = candidateRoots.filter { PathTools.isDirectory($0.replacingOccurrences(of: "~", with: home)) }
        return LapangkeSettings(devRoots: roots, inactiveDays: 21, lowSpaceWarningGB: 20, workVolumeUUID: nil, relocations: [:])
    }

    public init(devRoots: [String], inactiveDays: Int, lowSpaceWarningGB: Int, workVolumeUUID: String?, relocations: [String: String]) {
        self.devRoots = devRoots
        self.inactiveDays = inactiveDays
        self.lowSpaceWarningGB = lowSpaceWarningGB
        self.workVolumeUUID = workVolumeUUID
        self.relocations = relocations
    }

    public func resolvedDevRoots(home: URL) -> [URL] {
        devRoots.map { root in
            root.hasPrefix("~") ? URL(fileURLWithPath: home.path + root.dropFirst()) : URL(fileURLWithPath: root)
        }
    }

    public static func load() -> LapangkeSettings {
        guard let data = try? Data(contentsOf: AppPaths.settings),
              let settings = try? JSONDecoder().decode(LapangkeSettings.self, from: data) else { return .defaults }
        return settings
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: AppPaths.settings, options: .atomic) }
    }
}
