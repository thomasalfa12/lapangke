import Foundation

// MARK: - File pribadi

public struct PersonalFilesProvider: ItemProvider {
    public var priority: Int { 40 }
    public var name: String { "File pribadi" }
    public init() {}

    static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso", "exe", "msi", "mpkg"]
    static let packageExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "apk", "aab", "ipa", "deb", "appimage"]

    public func items(in context: ScanContext) async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Unduhan: installer yang sudah dipakai paling aman dibuang.
        let downloads = PathTools.children(of: context.url("Downloads"))
        let downloadSizes = await SizeCalculator.measureAll(downloads, trackNewest: true)
        for url in downloads {
            guard let size = downloadSizes[url] else { continue }
            let ext = url.pathExtension.lowercased()
            let modified = PathTools.modificationDate(url.path)
            let age = context.daysSince(modified) ?? 0
            if Self.installerExtensions.contains(ext), size.bytes >= 5 * MB {
                items.append(CleanupItem(
                    title: url.lastPathComponent, detail: "Installer di Unduhan (\(age) hari). Biasanya tidak dibutuhkan lagi setelah app terpasang.",
                    path: url.path, bytes: size.bytes, category: .personal, safety: .review, action: .trash,
                    lastActivity: modified
                ))
            } else if Self.packageExtensions.contains(ext) || url.lastPathComponent.hasSuffix(".app"), size.bytes >= 20 * MB {
                items.append(CleanupItem(
                    title: url.lastPathComponent, detail: "Arsip/paket di Unduhan (\(age) hari).",
                    path: url.path, bytes: size.bytes, category: .personal, safety: .review, action: .trash,
                    lastActivity: modified, offloadable: true
                ))
            } else if size.bytes >= 100 * MB {
                items.append(CleanupItem(
                    title: url.lastPathComponent, detail: "Isi Unduhan berukuran besar (\(age) hari).",
                    path: url.path, bytes: size.bytes, category: .personal, safety: .review, action: .trash,
                    lastActivity: modified, offloadable: true
                ))
            }
        }

        // Photos dikelola lewat app-nya (sinkron iCloud), bukan dihapus sebagai file.
        for library in PathTools.children(of: context.url("Pictures")) where library.pathExtension == "photoslibrary" {
            let size = SizeCalculator.measure(library)
            guard size.bytes >= 200 * MB else { continue }
            items.append(CleanupItem(
                title: "Library Photos (\(library.deletingPathExtension().lastPathComponent))",
                detail: "Kelola lewat app Photos agar sinkron iCloud tetap benar.", path: library.path, bytes: size.bytes,
                category: .personal, safety: .managed,
                action: .manual(instructions: "Photos › Settings › iCloud › 'Optimize Mac Storage', atau pindahkan library ke SSD: tutup Photos, salin .photoslibrary ke SSD, lalu buka sambil menahan Option."),
                lastActivity: PathTools.modificationDate(library.path)
            ))
        }

        // File besar satu per satu (video, image disk, arsip, VM) di semua folder pribadi.
        items += LargeFileFinder.find(in: context)

        // Tong Sampah: ruangnya baru benar-benar bebas setelah dikosongkan.
        let trash = context.url(".Trash")
        let trashSize = SizeCalculator.measure(trash)
        if trashSize.bytes >= 10 * MB {
            items.append(CleanupItem(
                title: "Isi Tong Sampah", detail: "\(trashSize.files) file. Mengosongkan Tong Sampah menghapus permanen isinya.",
                path: trash.path, bytes: trashSize.bytes, category: .personal, safety: .review, action: .emptyTrash
            ))
        }
        return items
    }
}

// MARK: - App non-kerja

public struct InstalledAppsProvider: ItemProvider {
    // Di atas katalog: cache milik app yang disarankan dihapus ikut terhitung di item app-nya, bukan dua kali.
    public var priority: Int { 60 }
    public var name: String { "Aplikasi" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        await InstalledApps.list(home: context.home, now: context.now).filter { $0.suggested && $0.totalBytes >= 5 * MB }.map { app in
            var warnings: [String] = []
            if app.fromAppStore { warnings.append("Dari App Store: macOS mungkin meminta password admin saat dihapus.") }
            if !app.data.isEmpty {
                warnings.append("Termasuk \(app.data.count) lokasi data (\(app.dataBytes.bytesText)): " + app.data.prefix(3).map(\.kind).joined(separator: ", "))
            }
            return CleanupItem(
                title: app.name, detail: app.advice, path: app.path, bytes: app.totalBytes, category: .apps,
                safety: .review, action: .trash, lastActivity: app.lastUsed, warnings: warnings,
                relatedPaths: app.data.map(\.path)
            )
        }
    }
}

// MARK: - Sisa app yang sudah dihapus

public struct OrphanedContainerProvider: ItemProvider {
    public var priority: Int { 30 }
    public var name: String { "Sisa app" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let installed = InstalledApps.bundleIdentifiers()
        let containers = PathTools.children(of: context.url("Library/Containers")).filter { url in
            let id = url.lastPathComponent
            guard !id.hasPrefix("com.apple."), id.contains(".") else { return false }
            return !installed.contains { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
        }
        let sizes = await SizeCalculator.measureAll(containers)
        return containers.compactMap { url in
            guard let bytes = sizes[url]?.bytes, bytes >= 100 * MB else { return nil }
            return CleanupItem(
                title: "Sisa data \(url.lastPathComponent)",
                detail: "App pemilik folder ini tidak ditemukan di Applications. Kemungkinan sisa app yang sudah dihapus.",
                path: url.path, bytes: bytes, category: .appCaches, safety: .review, action: .trash,
                lastActivity: PathTools.modificationDate(url.path)
            )
        }
    }
}

// MARK: - Cache & log generik

/// `~/Library/Caches` dan `~/Library/Logs` per app. Menurut aturan macOS, isi Caches boleh
/// dihapus kapan saja; tetap tidak dipilih otomatis karena app-nya tidak dikenal.
public struct GenericCacheProvider: ItemProvider {
    public var priority: Int { 20 }
    public var name: String { "Cache app" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let caches = PathTools.children(of: context.url("Library/Caches")).filter { !$0.lastPathComponent.hasPrefix("com.apple.") }
        let logs = PathTools.children(of: context.url("Library/Logs")).filter {
            !["DiagnosticReports", "CoreSimulator"].contains($0.lastPathComponent)
        }
        let sizes = await SizeCalculator.measureAll(caches + logs)
        let cacheItems: [CleanupItem] = caches.compactMap { url in
            guard let bytes = sizes[url]?.bytes, bytes >= 100 * MB else { return nil }
            return CleanupItem(
                title: "Cache app: \(url.lastPathComponent)", detail: "Cache app. Dibuat ulang otomatis; tutup app-nya dulu.",
                path: url.path, bytes: bytes, category: .appCaches, safety: .regenerable, action: .delete,
                lastActivity: PathTools.modificationDate(url.path)
            )
        }
        let logItems: [CleanupItem] = logs.compactMap { url in
            guard let bytes = sizes[url]?.bytes, bytes >= 30 * MB else { return nil }
            return CleanupItem(
                title: "Log \(url.lastPathComponent)", detail: "Log lama aplikasi.", path: url.path, bytes: bytes,
                category: .appCaches, safety: .regenerable, action: .delete, recommended: true,
                lastActivity: PathTools.modificationDate(url.path)
            )
        }
        return cacheItems + logItems
    }
}

// MARK: - Sistem (hanya informasi)

public struct SystemProvider: ItemProvider {
    public var priority: Int { 10 }
    public var name: String { "Sistem" }
    public init() {}

    static let assetNames: [String: (String, String)] = [
        "com_apple_MobileAsset_iOSSimulatorRuntime": ("Runtime Simulator iOS", "Kelola di Xcode › Settings › Components."),
        "com_apple_MobileAsset_AppleDeveloperDocumentation": ("Dokumentasi Xcode", "Xcode › Settings › Components › hapus Documentation bila jarang dibaca offline."),
        "com_apple_MobileAsset_MetalToolchain": ("Metal Toolchain", "Dibutuhkan untuk compile shader Metal. Kelola di Xcode › Settings › Components."),
        "com_apple_MobileAsset_UAF_LinguisticData": ("Model bahasa Apple Intelligence", "Dikelola macOS (System Settings › Apple Intelligence & Siri)."),
        "com_apple_MobileAsset_UAF_Siri_Understanding": ("Model Siri", "Dikelola macOS (System Settings › Apple Intelligence & Siri)."),
        "com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive": ("Model Photos", "Dikelola macOS."),
    ]

    public func items(in context: ScanContext) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        let assets = PathTools.children(of: URL(fileURLWithPath: "/System/Library/AssetsV2"))
        let sizes = await SizeCalculator.measureAll(assets)
        for url in assets {
            guard let bytes = sizes[url]?.bytes, bytes >= 300 * MB else { continue }
            let known = Self.assetNames[url.lastPathComponent]
            let fallback = url.lastPathComponent.replacingOccurrences(of: "com_apple_MobileAsset_", with: "").replacingOccurrences(of: "_", with: " ")
            items.append(CleanupItem(
                title: known?.0 ?? "Aset macOS: \(fallback)", detail: "Aset unduhan macOS/Xcode di /System/Library/AssetsV2.",
                path: url.path, bytes: bytes, category: .system, safety: .managed,
                action: .manual(instructions: known?.1 ?? "Dikelola macOS; tidak bisa dihapus manual.")
            ))
        }

        let disk = DiskInspector.snapshot(home: context.home, includeSmart: false)
        for volume in disk.apfsVolumes where volume.role != "Data" && volume.bytes > 0 {
            let (title, instructions): (String, String) = switch volume.role {
            case "VM": ("Swap memori (VM)", "macOS memakai SSD sebagai RAM tambahan. Berkurang setelah restart; tutup app berat (browser, emulator) saat build.")
            case "Preboot": ("Preboot (komponen boot & cryptex)", "Dikelola macOS. Membesar sementara saat update; mengecil setelah update selesai.")
            case "Recovery": ("Recovery", "Partisi pemulihan macOS. Jangan diubah.")
            case "System": ("macOS (System)", "Volume sistem tersegel. Tidak bisa dikurangi.")
            case "Update": ("Update macOS", "File update yang sedang disiapkan.")
            default: ("Volume \(volume.name)", "Dikelola macOS.")
            }
            items.append(CleanupItem(
                title: title, detail: "Volume APFS terpisah di disk internal.", path: "apfs:\(volume.name):\(volume.role)",
                bytes: volume.bytes, category: .system, safety: .managed, action: .manual(instructions: instructions)
            ))
        }

        let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20).stdout
            .split(separator: "\n").filter { $0.contains("com.apple") }
        if !snapshots.isEmpty {
            items.append(CleanupItem(
                title: "Snapshot lokal Time Machine (\(snapshots.count))", detail: "Snapshot menahan ruang file yang sudah dihapus.",
                path: "tmutil:localsnapshots", bytes: 0, category: .system, safety: .managed,
                action: .manual(instructions: "Jalankan di Terminal: tmutil thinlocalsnapshots / 999999999999 4")
            ))
        }
        return items
    }
}
