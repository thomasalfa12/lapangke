import CoreServices
import Foundation

public enum AppRole: String, Codable, Sendable, CaseIterable {
    case work, communication, nonWork, system, other

    public var label: String {
        switch self {
        case .work: "Kerja"
        case .communication: "Komunikasi"
        case .nonWork: "Non-kerja"
        case .system: "Sistem"
        case .other: "Lainnya"
        }
    }
}

/// Satu lokasi data milik sebuah app (cache, container, dukungan aplikasi, …).
public struct AppDataLocation: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var kind: String
    public var bytes: Int64
}

public struct InstalledApp: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleID: String?
    public var executable: String?
    public var version: String?
    public var categoryType: String?
    /// Ukuran bundle .app saja.
    public var bytes: Int64
    /// Data app di ~/Library yang ikut terhapus saat uninstall.
    public var data: [AppDataLocation]
    public var lastUsed: Date?
    /// Berapa kali dibuka menurut Spotlight (bila tercatat).
    public var useCount: Int?
    public var fromAppStore: Bool
    public var role: AppRole
    public var reason: String
    /// Saran Lapangke: layak dihapus atau tidak, beserta alasannya.
    public var suggested: Bool
    public var advice: String
    /// Sedang berjalan saat dipindai.
    public var isRunning: Bool = false
    /// App menu bar / agen latar (LSUIElement): Spotlight sering tidak mencatat kapan dibuka.
    public var isBackgroundAgent: Bool = false
    /// Kapan data app di ~/Library terakhir berubah (tanda masih dipakai walau tak tercatat dibuka).
    public var dataActivity: Date?

    /// Tanda pemakaian terbaru: dibuka (Spotlight) atau datanya berubah.
    public var lastActivity: Date? { [lastUsed, dataActivity].compactMap { $0 }.max() }

    public var dataBytes: Int64 { data.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { bytes + dataBytes }
    public var isRemovable: Bool { role != .system }
}

public enum InstalledApps {
    static let roots = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Applications"]

    /// Semua bundle ID yang terpasang, termasuk extension & helper di dalam app
    /// (dipakai untuk mengenali folder Containers sisa app yang sudah dihapus).
    public static func bundleIdentifiers() -> Set<String> {
        var ids: Set<String> = []
        for root in roots {
            for app in PathTools.children(of: URL(fileURLWithPath: root)) where app.pathExtension == "app" {
                if let id = bundleID(of: app) { ids.insert(id) }
                for sub in ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/Helpers", "Contents/Frameworks"] {
                    for nested in PathTools.children(of: app.appendingPathComponent(sub)) {
                        if let id = bundleID(of: nested) { ids.insert(id) }
                    }
                }
            }
        }
        return ids
    }

    static func bundleID(of url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    public static func usage(_ url: URL) -> (lastUsed: Date?, useCount: Int?) {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return (nil, nil) }
        let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let count = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
        return (date, count)
    }

    /// Path executable semua proses yang berjalan (satu panggilan `ps`).
    static func runningExecutables() -> [String] {
        Shell.run("/bin/ps", ["-axo", "comm="], timeout: 10).stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Sisa data

    /// Nama folder yang dipakai bersama banyak app dari vendor yang sama — tidak boleh dicocokkan berdasarkan nama.
    static let sharedVendorFolders: Set<String> = [
        "google", "microsoft", "apple", "adobe", "jetbrains", "mozilla", "oracle", "caches", "cache", "logs", "data", "app",
    ]

    /// Folder di ~/Library yang jelas milik app ini, dicari dari bundle ID dan nama app.
    public static func dataLocations(bundleID: String?, name: String, home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library")
        var found: [URL] = []
        func add(_ relative: String) {
            let url = library.appendingPathComponent(relative)
            if PathTools.exists(url.path), !found.contains(url) { found.append(url) }
        }
        if let id = bundleID, id.contains(".") {
            for folder in ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Logs", "Application Scripts"] {
                add("\(folder)/\(id)")
            }
            add("Saved Application State/\(id).savedState")
            add("HTTPStorages/\(id).binarycookies")
            add("Cookies/\(id).binarycookies")
            // Extension app: com.vendor.app.Widget
            for child in PathTools.children(of: library.appendingPathComponent("Containers")) where child.lastPathComponent.hasPrefix(id + ".") {
                add("Containers/\(child.lastPathComponent)")
            }
            // Group container: group.<id>, <TEAMID>.<id>, group.<id>.shared
            for child in PathTools.children(of: library.appendingPathComponent("Group Containers")) {
                let group = child.lastPathComponent
                if group == id || group.hasSuffix("." + id) || group.hasPrefix("group." + id) || group.contains("." + id + ".") {
                    add("Group Containers/\(group)")
                }
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3, !sharedVendorFolders.contains(trimmed.lowercased()) {
            for folder in ["Application Support", "Caches", "Logs"] { add("\(folder)/\(trimmed)") }
        }
        return found
    }

    static func dataKind(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        switch parent {
        case "Application Support": return "Data aplikasi"
        case "Caches": return "Cache"
        case "Containers": return "Container (data & pengaturan)"
        case "Group Containers": return "Data bersama"
        case "Logs": return "Log"
        case "Saved Application State": return "Status jendela"
        case "HTTPStorages", "WebKit", "Cookies": return "Data web"
        case "Application Scripts": return "Skrip"
        default: return parent
        }
    }

    // MARK: Daftar

    public static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(), measure: Bool = true) async -> [InstalledApp] {
        var urls: [URL] = []
        for root in roots where root != "/System/Applications" {
            urls += PathTools.children(of: URL(fileURLWithPath: root)).filter { $0.pathExtension == "app" && !PathTools.isSymlink($0.path) }
        }
        let guardrail = SafetyGuard(home: home)
        var dataByApp: [URL: [URL]] = [:]
        for url in urls {
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let id = plist?["CFBundleIdentifier"] as? String
            let name = (plist?["CFBundleDisplayName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            // Hanya lokasi yang memang boleh dihapus (bukan data penting yang dilindungi).
            dataByApp[url] = id?.hasPrefix("com.apple.") == true ? [] : dataLocations(bundleID: id, name: name, home: home).filter {
                (try? guardrail.validate(path: $0.path)) != nil
            }
        }
        let allPaths = urls + dataByApp.values.flatMap { $0 }
        let running = runningExecutables()
        let sizes = measure ? await SizeCalculator.measureAll(allPaths, trackNewest: true, concurrency: 4) : [:]

        return urls.map { url in
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let id = plist?["CFBundleIdentifier"] as? String
            let category = plist?["LSApplicationCategoryType"] as? String
            let name = (plist?["CFBundleDisplayName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let (role, reason) = classify(name: name, bundleID: id, category: category, path: url.path)
            let (lastUsed, useCount) = usage(url)
            let data = (dataByApp[url] ?? []).map {
                AppDataLocation(path: $0.path, kind: dataKind($0), bytes: sizes[$0]?.bytes ?? 0)
            }.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            var app = InstalledApp(
                name: name, path: url.path, bundleID: id, executable: plist?["CFBundleExecutable"] as? String,
                version: plist?["CFBundleShortVersionString"] as? String, categoryType: category,
                bytes: sizes[url]?.bytes ?? 0, data: data, lastUsed: lastUsed, useCount: useCount,
                fromAppStore: PathTools.exists(url.path + "/Contents/_MASReceipt"),
                role: role, reason: reason, suggested: false, advice: ""
            )
            app.dataActivity = (dataByApp[url] ?? []).compactMap { sizes[$0]?.newest }.max()
            app.isRunning = running.contains { $0.hasPrefix(url.path + "/Contents/") }
            app.isBackgroundAgent = (plist?["LSUIElement"] as? Bool) == true || (plist?["LSBackgroundOnly"] as? Bool) == true
                || (plist?["LSUIElement"] as? String) == "1"
            (app.suggested, app.advice) = advise(app, now: now)
            return app
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Saran yang bisa dijelaskan: lama tidak dibuka, jarang dipakai, dan seberapa besar.
    public static func advise(_ app: InstalledApp, now: Date) -> (Bool, String) {
        guard app.isRemovable else { return (false, "Bawaan macOS") }
        if app.isRunning { return (false, "Sedang berjalan, jadi masih dipakai.") }
        let size = app.totalBytes.bytesText
        let days = Formatters.days(since: app.lastActivity, now: now)
        let lastOpened: String
        if let opened = app.lastUsed, opened == app.lastActivity {
            lastOpened = "dibuka terakhir \(Formatters.relative(opened, now: now))"
        } else if let touched = app.dataActivity {
            lastOpened = "datanya terakhir berubah \(Formatters.relative(touched, now: now))"
        } else {
            lastOpened = "tidak tercatat pernah dibuka"
        }
        let uses = app.useCount.map { " · dibuka \($0)×" } ?? ""

        switch (app.role, days) {
        case (.nonWork, nil), (.nonWork, .some(31...)):
            return (true, "Bukan app kerja, \(lastOpened)\(uses). Hapus untuk membebaskan \(size).")
        case (_, .some(181...)):
            return (true, "Tidak dibuka lebih dari 6 bulan\(uses). Hapus untuk membebaskan \(size).")
        case (.other, .some(91...)):
            return (true, "Tidak dibuka 3 bulan terakhir\(uses). Hapus untuk membebaskan \(size).")
        case (.other, nil) where app.totalBytes >= 100 * MB && !app.isBackgroundAgent:
            return (true, "Tidak tercatat pernah dibuka. Hapus untuk membebaskan \(size).")
        default:
            return (false, "Masih dipakai, \(lastOpened)\(uses).")
        }
    }

    static let workIDs = [
        "com.apple.dt.", "com.apple.TestFlight", "com.apple.Simulator", "com.apple.iconcomposer", "com.apple.SFSymbols",
        "com.google.android.studio", "com.jetbrains.", "com.microsoft.VSCode", "com.todesktop.", "com.exafunction.windsurf",
        "com.google.antigravity", "com.anthropic.", "com.openai.", "com.docker.", "com.postmanlabs.", "com.figma.",
        "com.github.", "com.googlecode.iterm2", "dev.warp.", "com.mitchellh.ghostty", "com.proxyman.", "com.charlesproxy.",
        "com.tinyapp.TablePlus", "com.cloudflare.", "com.google.Chrome", "com.brave.", "org.mozilla.firefox",
        "com.google.drivefs", "com.thomasalfa.", "space.ourbooth.", "app.ourbooth.", "id.thomasalfa.",
        "com.sublimetext.", "com.panic.", "com.raycast.", "com.1password.", "com.bitwarden.", "com.microsoft.Word",
        "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.iWork.", "com.adobe.", "com.canva.", "com.notion.",
    ]
    static let communicationIDs = [
        "net.whatsapp.", "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "us.zoom.", "com.microsoft.teams", "org.whispersystems.signal", "jp.naver.line", "com.skype.",
    ]
    static let nonWorkNames = [
        "steam", "dota", "roblox", "minecraft", "epic games", "battle.net", "league of legends", "valorant", "genshin",
        "spotify", "netflix", "insaquarium", "safe exam browser", "plants vs", "among us", "fortnite", "garena",
    ]
    static let nonWorkCategories = ["games", "entertainment", "music", "sports", "lifestyle", "social-networking", "education", "kids"]

    static func classify(name: String, bundleID: String?, category: String?, path: String) -> (AppRole, String) {
        let id = bundleID ?? ""
        let lowerName = name.lowercased()
        if workIDs.contains(where: { id.hasPrefix($0) }) || lowerName.contains("ourbooth") {
            return (.work, "Tool kerja")
        }
        if communicationIDs.contains(where: { id.hasPrefix($0) }) { return (.communication, "App komunikasi") }
        if nonWorkNames.contains(where: { lowerName.contains($0) }) { return (.nonWork, "Game/hiburan") }
        if let category, nonWorkCategories.contains(where: { category.contains($0) }) {
            return (.nonWork, "Kategori \(category.replacingOccurrences(of: "public.app-category.", with: ""))")
        }
        if id.hasPrefix("com.apple.") { return (.system, "Bawaan macOS") }
        if let category, category.contains("developer-tools") { return (.work, "Tool developer") }
        return (.other, category.map { "Kategori \($0.replacingOccurrences(of: "public.app-category.", with: ""))" } ?? "Tanpa kategori")
    }
}
