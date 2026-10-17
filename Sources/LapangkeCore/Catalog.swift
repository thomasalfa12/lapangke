import Foundation

/// Satu lokasi yang sudah dikenal beserta penilaiannya. `path` relatif ke home;
/// komponen terakhir boleh memakai wildcard (`AndroidStudio*`).
public struct CatalogRule: Sendable {
    public enum AppCondition: Sendable {
        case always
        /// Berlaku hanya jika app dengan bundle ID ini TIDAK terpasang (data sisa).
        case appAbsent(String)
        /// Berlaku hanya jika app terpasang.
        case appPresent(String)
    }

    public var path: String
    public var title: String
    public var detail: String
    public var category: ItemCategory
    public var safety: Safety
    public var action: CleanupAction
    public var recommended: Bool = false
    public var offloadable: Bool = false
    public var minBytes: Int64 = 20 * MB
    public var condition: AppCondition = .always
}

public enum Catalog {
    static func rule(
        _ path: String, _ title: String, _ detail: String, _ category: ItemCategory, _ safety: Safety,
        rec: Bool = false, offload: Bool = false, min: Int64 = 20 * MB, when: CatalogRule.AppCondition = .always,
        action: CleanupAction? = nil
    ) -> CatalogRule {
        let defaultAction: CleanupAction = safety == .review ? .trash : .delete
        return CatalogRule(
            path: path, title: title, detail: detail, category: category, safety: safety,
            action: action ?? defaultAction, recommended: rec, offloadable: offload, minBytes: min, condition: when
        )
    }

    public static let rules: [CatalogRule] = xcode + android + toolchains + aiTools + appCaches

    // MARK: Xcode

    static let xcode: [CatalogRule] = [
        rule("Library/Developer/Xcode/DerivedData", "DerivedData Xcode",
             "Hasil build, index, dan cache modul Xcode. Dibuat ulang otomatis; build pertama sesudahnya sedikit lebih lama. Tutup Xcode dulu.",
             .xcode, .regenerable, rec: true),
        rule("Library/Developer/Xcode/Archives", "Arsip Xcode (.xcarchive)",
             "Build rilis beserta dSYM untuk membaca laporan crash. Simpan versi yang masih beredar di App Store; sisanya lebih baik dipindah ke SSD daripada dihapus.",
             .xcode, .review, offload: true),
        rule("Library/Developer/Xcode/UserData/Previews", "Cache SwiftUI Previews",
             "Simulator & build khusus Preview. Dibuat ulang saat Preview dibuka.", .xcode, .regenerable, rec: true),
        rule("Library/Developer/Xcode/Products", "Xcode Products", "Produk build lokal. Dibuat ulang saat build.",
             .xcode, .regenerable, rec: true),
        rule("Library/Developer/Xcode/DocumentationCache", "Cache dokumentasi Xcode", "Index dokumentasi. Dibuat ulang otomatis.",
             .xcode, .regenerable, rec: true),
        rule("Library/Caches/com.apple.dt.Xcode", "Cache Xcode", "Cache internal Xcode. Dibuat ulang otomatis.",
             .xcode, .regenerable, rec: true),
        rule("Library/Developer/CoreSimulator/Caches", "Cache Simulator",
             "Cache dyld & runtime simulator. Dibuat ulang saat simulator berikutnya dijalankan.", .simulators, .regenerable, rec: true),
        rule("Library/Logs/CoreSimulator", "Log Simulator", "Log lama dari simulator.", .simulators, .regenerable, rec: true),
        rule("Library/Developer/XCTestDevices", "Simulator klon test paralel",
             "Salinan simulator yang dibuat saat test paralel. Dibuat ulang bila perlu.", .simulators, .regenerable, rec: true),
        rule("Library/Caches/org.swift.swiftpm", "Cache paket SwiftPM", "Paket Swift yang sudah diunduh. Diunduh ulang saat resolve.",
             .xcode, .costly),
        rule("Library/Caches/CocoaPods", "Cache CocoaPods", "Pod yang sudah diunduh. Diunduh ulang saat `pod install`.",
             .xcode, .costly),
    ]

    // MARK: Android

    static let android: [CatalogRule] = [
        rule(".gradle/daemon", "Log Gradle daemon", "Log & registry daemon lama.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".gradle/.tmp", "File sementara Gradle", "Sisa file sementara.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".gradle/kotlin-profile", "Laporan profil build Kotlin", "Laporan per build, tidak dipakai lagi.",
             .android, .regenerable, rec: true, min: 10 * MB),
        rule(".gradle/build-scan-data", "Data build scan", "Sisa build scan Gradle.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".gradle/native", "Library native Gradle", "Diekstrak ulang otomatis oleh Gradle.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".gradle/caches/modules-2", "Dependency Gradle (Maven)",
             "Semua library yang diunduh Gradle. Aman dihapus, tapi build berikutnya mengunduh ulang semuanya (butuh internet & waktu).",
             .android, .costly),
        rule(".gradle/jdks", "JDK unduhan Gradle", "JDK untuk Gradle toolchain. Diunduh ulang bila dibutuhkan.", .android, .costly),
        rule(".android/cache", "Cache Android tools", "Cache sdkmanager/lint. Dibuat ulang.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".android/avd", "Emulator Android (AVD)",
             "Image & data emulator. Hapus bila tidak lagi menguji di emulator; bisa dibuat ulang lewat Android Studio › Device Manager.", .android, .review),
        rule("Library/Caches/Google/AndroidStudio*", "Cache Android Studio", "Index & cache IDE. Dibuat ulang saat Studio dibuka.",
             .android, .regenerable, rec: true),
        rule("Library/Logs/Google/AndroidStudio*", "Log Android Studio", "Log IDE lama.", .android, .regenerable, rec: true, min: 10 * MB),
        rule(".konan", "Toolchain Kotlin/Native", "Compiler Kotlin/Native. Diunduh ulang bila proyek KMP di-build.", .android, .costly),
        rule(".m2/repository", "Repository Maven lokal", "Library Maven. Diunduh ulang bila dibutuhkan.", .android, .costly),
    ]

    // MARK: Paket & toolchain

    static let toolchains: [CatalogRule] = [
        rule(".npm/_cacache", "Cache npm", "Paket npm yang sudah diunduh. Diunduh ulang saat install.", .toolchains, .costly),
        rule(".npm/_logs", "Log npm", "Log install lama.", .toolchains, .regenerable, rec: true, min: 5 * MB),
        rule("Library/Caches/Yarn", "Cache Yarn", "Diunduh ulang saat install.", .toolchains, .costly),
        rule("Library/pnpm/store", "Store pnpm", "Diunduh ulang saat install. node_modules yang sudah ada tetap jalan.", .toolchains, .costly),
        rule(".bun/install/cache", "Cache Bun", "Diunduh ulang saat install.", .toolchains, .costly),
        rule("Library/Caches/Homebrew", "Unduhan Homebrew",
             "Installer paket yang sudah terpasang. Aman dihapus (setara `brew cleanup -s`).", .toolchains, .regenerable, rec: true),
        rule("Library/Caches/pip", "Cache pip", "Wheel Python yang sudah diunduh.", .toolchains, .regenerable, rec: true),
        rule(".cargo/registry/src", "Source crate Rust (hasil ekstrak)",
             "Diekstrak ulang dari cache tanpa internet saat build berikutnya.", .toolchains, .regenerable, rec: true),
        rule(".cargo/registry/cache", "Cache crate Rust", "Crate terunduh. Diunduh ulang bila dihapus.", .toolchains, .costly),
        rule(".cargo/git/checkouts", "Checkout git Cargo", "Dependency git Rust. Di-clone ulang bila perlu.", .toolchains, .costly),
        rule(".rustup/downloads", "Unduhan rustup", "Sisa unduhan toolchain.", .toolchains, .regenerable, rec: true, min: 10 * MB),
        rule(".rustup/tmp", "File sementara rustup", "Sisa file sementara.", .toolchains, .regenerable, rec: true, min: 10 * MB),
        rule(".cache/prisma", "Engine Prisma", "Binary engine Prisma. Diunduh ulang saat `prisma generate`.", .toolchains, .costly),
        rule("Library/Caches/ms-playwright", "Browser Playwright", "Browser untuk test. Diunduh ulang lewat `npx playwright install`.",
             .toolchains, .costly),
        rule(".cache/puppeteer", "Browser Puppeteer", "Chromium untuk Puppeteer. Diunduh ulang saat install.", .toolchains, .costly),
        rule("Library/Caches/node-gyp", "Header node-gyp", "Header Node untuk modul native.", .toolchains, .costly),
        rule("Library/Caches/typescript", "Cache TypeScript", "Cache tipe editor.", .toolchains, .regenerable, rec: true, min: 10 * MB),
        rule("Library/Caches/go-build", "Cache build Go", "Dibuat ulang saat build.", .toolchains, .regenerable, rec: true),
        rule("go/pkg/mod", "Modul Go", "Diunduh ulang saat build.", .toolchains, .costly),
        rule(".platformio/.cache", "Cache PlatformIO", "Dibuat ulang.", .toolchains, .regenerable, rec: true, min: 10 * MB),
        rule(".platformio/packages", "Toolchain PlatformIO", "Compiler mikrokontroler. Diunduh ulang bila proyek PlatformIO di-build.",
             .toolchains, .costly),
        rule("Library/Containers/com.docker.docker", "Sisa data Docker Desktop",
             "Docker Desktop sudah tidak terpasang. Folder ini berisi disk VM, image, dan volume lama.",
             .toolchains, .review, when: .appAbsent("com.docker.docker")),
        rule("Library/Containers/com.docker.docker", "Data Docker Desktop",
             "Image, container, dan volume Docker.", .toolchains, .managed, when: .appPresent("com.docker.docker"),
             action: .manual(instructions: "Jalankan `docker system prune -a` (hapus image & cache tak terpakai) atau Docker Desktop › Settings › Resources untuk memperkecil disk image.")),
        rule(".docker/scout", "Cache Docker Scout", "Database analisis image.", .toolchains, .regenerable, rec: true),
        rule("VirtualBox VMs", "Mesin virtual VirtualBox", "Disk VM. Pindahkan ke SSD bila masih dipakai.", .toolchains, .review, offload: true),
    ]

    // MARK: Tool AI & editor

    static let editorApps = ["Code", "Code - Insiders", "Cursor", "Windsurf", "Antigravity", "Antigravity IDE", "Kiro", "Zed", "Slack", "discord", "Notion", "Figma", "Postman", "Microsoft Teams"]
    static let electronCaches = ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs", "Service Worker/CacheStorage", "DawnGraphiteCache", "DawnWebGPUCache"]

    static let aiTools: [CatalogRule] = [
        rule(".codex/cache", "Cache Codex", "Cache internal Codex. Dibuat ulang otomatis.", .aiTools, .regenerable, rec: true, min: 10 * MB),
        rule(".cache/codex-runtimes", "Runtime Codex", "Runtime terunduh milik Codex. Diunduh ulang bila dibutuhkan.", .aiTools, .costly),
        rule(".codex/generated_images", "Gambar buatan Codex", "Gambar hasil generate. Periksa sebelum dihapus.",
             .aiTools, .review, offload: true),
        rule(".codex/worktrees", "Worktree Codex", "Worktree milik sesi Codex. Kelola dari Codex agar perubahan yang belum di-commit tidak hilang.",
             .aiTools, .managed, action: .manual(instructions: "Buka Codex dan arsipkan/hapus sesi yang tidak dipakai; worktree-nya ikut dibersihkan.")),
        rule(".gemini/antigravity-backup", "Backup Antigravity", "Cadangan data Antigravity.", .aiTools, .review, offload: true),
        rule(".gemini/antigravity-browser-profile", "Profil browser Antigravity",
             "Sesi login browser agent. Dibuat ulang, tapi Anda perlu login lagi.", .aiTools, .costly),
        rule(".gemini/antigravity", "Data Antigravity", "Percakapan, konteks, dan cache Antigravity. Hapus hanya bila Antigravity tidak dipakai lagi.",
             .aiTools, .review, offload: true),
        rule(".gemini/antigravity-ide", "Data Antigravity IDE", "Data IDE Antigravity. Hapus hanya bila Antigravity tidak dipakai lagi.",
             .aiTools, .review, offload: true),
        rule("Library/Application Support/Claude", "Data app Claude",
             "Worktree sesi, cache web, dan versi Claude Code.", .aiTools, .managed,
             action: .manual(instructions: "Buka Claude › Settings › This computer › Storage: bersihkan worktree sesi lama dan Clear cache.")),
        rule(".claude", "Memori & riwayat Claude Code",
             "Memori proyek, riwayat, dan pengaturan Claude Code. Jangan dihapus.", .aiTools, .keep, action: .manual(instructions: "Tidak perlu dibersihkan.")),
    ] + editorApps.flatMap { app in
        electronCaches.map { cache in
            rule("Library/Application Support/\(app)/\(cache)", "\(app) · \(cache)",
                 "Cache editor/app berbasis Electron. Dibuat ulang otomatis saat app dibuka.",
                 .aiTools, .regenerable, rec: true, min: 30 * MB)
        }
    }

    // MARK: Cache app & browser

    static let appCaches: [CatalogRule] = [
        rule("Library/Caches/Google/Chrome", "Cache Google Chrome", "Cache halaman web. Dibuat ulang saat browsing; login tidak hilang.",
             .appCaches, .regenerable, rec: true),
        rule("Library/Caches/BraveSoftware", "Cache Brave", "Cache halaman web.", .appCaches, .regenerable, rec: true),
        rule("Library/Caches/Firefox", "Cache Firefox", "Cache halaman web.", .appCaches, .regenerable, rec: true),
        rule("Library/Caches/com.microsoft.edgemac", "Cache Edge", "Cache halaman web.", .appCaches, .regenerable, rec: true),
        rule("Library/Caches/com.spotify.client", "Cache Spotify", "Lagu yang di-cache untuk streaming.", .appCaches, .regenerable, rec: true),
        rule("Library/Application Support/Spotify/PersistentCache", "Cache lagu Spotify", "Diunduh ulang saat diputar.",
             .appCaches, .regenerable, rec: true),
        rule("Library/Application Support/Google/DriveFS", "Cache Google Drive",
             "File Drive yang di-cache/mirror di Mac.", .appCaches, .managed,
             action: .manual(instructions: "Google Drive › Settings › Preferences: pilih 'Stream files' (bukan Mirror) dan kecilkan batas cache.")),
        rule("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", "Media WhatsApp",
             "Foto, video, dan dokumen dari chat WhatsApp.", .personal, .review, offload: true),
        rule("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", "Data Telegram",
             "Media & cache chat Telegram.", .personal, .managed,
             action: .manual(instructions: "Telegram › Settings › Data and Storage › Storage Usage › Clear Cache.")),
        rule("Library/Application Support/MobileSync/Backup", "Backup iPhone/iPad",
             "Cadangan perangkat lewat Finder. Hapus yang lama atau pindahkan ke SSD.", .personal, .review, offload: true),
        rule("Movies/TV", "Unduhan Apple TV", "Film/serial yang diunduh.", .personal, .review),
        rule("Library/Roblox", "Data Roblox", "Game Roblox.", .apps, .review),
        rule("Library/Application Support/Steam/steamapps", "Game Steam", "Game yang terpasang lewat Steam.", .apps, .review),
    ]
}

/// Mengubah katalog statis menjadi item, hanya untuk lokasi yang ada & cukup besar.
public struct CatalogProvider: ItemProvider {
    public var priority: Int { 50 }
    public var name: String { "Katalog lokasi dikenal" }
    public var rules: [CatalogRule]

    public init(rules: [CatalogRule] = Catalog.rules) { self.rules = rules }

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let installed = InstalledApps.bundleIdentifiers()
        var targets: [(CatalogRule, URL)] = []
        for rule in rules {
            switch rule.condition {
            case .always: break
            case let .appAbsent(id): if installed.contains(id) { continue }
            case let .appPresent(id): if !installed.contains(id) { continue }
            }
            for url in expand(rule.path, home: context.home) { targets.append((rule, url)) }
        }
        let sizes = await SizeCalculator.measureAll(targets.map(\.1), trackNewest: false)
        return targets.compactMap { rule, url in
            guard let size = sizes[url], size.bytes >= rule.minBytes || rule.safety >= .keep && size.bytes > 0 else { return nil }
            var warnings: [String] = []
            if !size.mountPoints.isEmpty { warnings.append("Berisi volume ter-mount; bagian itu dilewati.") }
            let title = rule.path.contains("*") ? "\(rule.title) (\(url.lastPathComponent))" : rule.title
            return CleanupItem(
                title: title, detail: rule.detail, path: url.path, bytes: size.bytes, category: rule.category,
                safety: rule.safety, action: rule.action, recommended: rule.recommended,
                lastActivity: PathTools.modificationDate(url.path), offloadable: rule.offloadable, warnings: warnings
            )
        }
    }

    func expand(_ relative: String, home: URL) -> [URL] {
        let url = home.appendingPathComponent(relative)
        let last = url.lastPathComponent
        guard last.contains("*") else { return PathTools.exists(url.path) && !PathTools.isSymlink(url.path) ? [url] : [] }
        let parent = url.deletingLastPathComponent()
        return PathTools.children(of: parent).filter { PathTools.matches($0.lastPathComponent, pattern: last) }
    }
}
