import Foundation

// MARK: - Simulator iOS

/// Membaca simulator langsung dari `simctl` (ukuran, status, terakhir dipakai),
/// lalu memakai aksi resmi `simctl erase/delete` alih-alih menghapus folder mentah.
public struct SimulatorProvider: ItemProvider {
    public var priority: Int { 100 }
    public var name: String { "Simulator" }
    public init() {}

    struct DeviceList: Decodable { let devices: [String: [Device]] }
    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPath: String?
        let dataPathSize: Int64?
        let lastUsedAt: String?
        let availabilityError: String?
    }

    struct Runtime: Decodable {
        let identifier: String
        let version: String?
        let build: String?
        let sizeBytes: Int64?
        let lastUsedAt: String?
        let deletable: Bool?
        let runtimeIdentifier: String?
        let path: String?
    }

    public func items(in context: ScanContext) async -> [CleanupItem] {
        guard let list = Toolchain.simctl(["list", "devices", "-j"], timeout: 60), list.ok,
              let devices = try? JSONDecoder().decode(DeviceList.self, from: Data(list.stdout.utf8)) else { return [] }
        let iso = ISO8601DateFormatter()
        var items: [CleanupItem] = []
        var usedRuntimes: Set<String> = []

        for (runtimeKey, entries) in devices.devices {
            let runtimeName = Self.runtimeName(runtimeKey)
            for device in entries {
                let lastUsed = device.lastUsedAt.flatMap(iso.date(from:))
                let available = device.isAvailable ?? true
                if available, let days = context.daysSince(lastUsed), days <= 60 { usedRuntimes.insert(runtimeKey) }
                guard let dataPath = device.dataPath else { continue }
                let deviceDir = URL(fileURLWithPath: dataPath).deletingLastPathComponent().path
                let bytes = device.dataPathSize ?? SizeCalculator.measure(URL(fileURLWithPath: deviceDir)).bytes
                guard bytes >= 50 * MB || !available else { continue }
                let title = "\(device.name) · \(runtimeName)"
                let usage = lastUsed.map { "Terakhir dipakai \(Formatters.relative($0, now: context.now))." } ?? "Belum pernah dijalankan."

                if device.state == "Booted" {
                    items.append(CleanupItem(
                        title: title, detail: "Sedang berjalan. \(usage)", path: deviceDir, bytes: bytes,
                        category: .simulators, safety: .keep, action: .manual(instructions: "Matikan simulator dulu bila ingin di-reset."),
                        lastActivity: lastUsed
                    ))
                } else if !available {
                    items.append(CleanupItem(
                        title: title, detail: "Runtime-nya sudah tidak terpasang, simulator ini tidak bisa dipakai lagi.",
                        path: deviceDir, bytes: bytes, category: .simulators, safety: .regenerable,
                        action: .simulatorDelete(udid: device.udid), recommended: true, lastActivity: lastUsed
                    ))
                } else {
                    let stale = context.daysSince(lastUsed).map { $0 > 30 } ?? true
                    items.append(CleanupItem(
                        title: title,
                        detail: "\(usage) Reset mengembalikan simulator ke kondisi baru: app uji & datanya hilang, simulatornya tetap ada.",
                        path: deviceDir, bytes: bytes, category: .simulators, safety: stale ? .regenerable : .costly,
                        action: .simulatorErase(udid: device.udid), recommended: stale, lastActivity: lastUsed
                    ))
                }
            }
        }

        if let runtimeList = Toolchain.simctl(["runtime", "list", "-j"], timeout: 60), runtimeList.ok,
           let runtimes = try? JSONDecoder().decode([String: Runtime].self, from: Data(runtimeList.stdout.utf8)) {
            for runtime in runtimes.values {
                let lastUsed = runtime.lastUsedAt.flatMap(iso.date(from:))
                let title = "Runtime \(runtime.runtimeIdentifier.map(Self.runtimeName) ?? runtime.version ?? "simulator") (\(runtime.build ?? "?"))"
                let inUse = runtime.runtimeIdentifier.map(usedRuntimes.contains) ?? false
                let path = runtime.path ?? "runtime:\(runtime.identifier)"
                if inUse || runtime.deletable == false {
                    items.append(CleanupItem(
                        title: title, detail: "Dipakai simulator Anda. Dikelola Xcode (disimpan di /System/Library/AssetsV2).",
                        path: path, bytes: runtime.sizeBytes ?? 0, category: .simulators, safety: .managed,
                        action: .manual(instructions: "Xcode › Settings › Components untuk mengelola runtime."), lastActivity: lastUsed
                    ))
                } else {
                    items.append(CleanupItem(
                        title: title, detail: "Tidak dipakai simulator mana pun dalam 60 hari. Bisa diunduh ulang dari Xcode › Settings › Components.",
                        path: path, bytes: runtime.sizeBytes ?? 0, category: .simulators, safety: .costly,
                        action: .simulatorRuntimeDelete(identifier: runtime.identifier), lastActivity: lastUsed
                    ))
                }
            }
        }
        return items
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` → `iOS 27.0`
    static func runtimeName(_ key: String) -> String {
        guard let last = key.split(separator: ".").last else { return key }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}

// MARK: - iOS DeviceSupport

/// Simbol debug yang disalin Xcode dari perangkat. Versi terbaru per model dipertahankan;
/// versi lama (iOS sudah di-update) aman dihapus.
public struct DeviceSupportProvider: ItemProvider {
    public var priority: Int { 95 }
    public var name: String { "Device Support" }
    public init() {}

    struct Entry {
        let url: URL
        let model: String
        let version: String
    }

    static func parse(_ name: String) -> (model: String, version: String)? {
        let pattern = #"^(?:(\S+) )?(\d+(?:\.\d+)*)(?: \(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let versionRange = Range(match.range(at: 2), in: name) else { return nil }
        let model = Range(match.range(at: 1), in: name).map { String(name[$0]) } ?? ""
        return (model, String(name[versionRange]))
    }

    public func items(in context: ScanContext) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let root = context.url("Library/Developer/Xcode/\(platform) DeviceSupport")
            let entries = PathTools.children(of: root).compactMap { url -> Entry? in
                guard PathTools.isDirectory(url.path), let parsed = Self.parse(url.lastPathComponent) else { return nil }
                return Entry(url: url, model: parsed.model, version: parsed.version)
            }
            let newestPerModel = Dictionary(grouping: entries, by: \.model).compactMapValues { group in
                group.max { PathTools.compareVersions($0.version, $1.version) == .orderedAscending }?.url
            }
            let sizes = await SizeCalculator.measureAll(entries.map(\.url))
            for entry in entries {
                let bytes = sizes[entry.url]?.bytes ?? 0
                guard bytes >= 50 * MB else { continue }
                let modified = PathTools.modificationDate(entry.url.path)
                let isNewest = newestPerModel[entry.model] == entry.url
                let stale = (context.daysSince(modified) ?? 0) > 120
                let device = entry.model.isEmpty ? platform : entry.model
                if isNewest && !stale {
                    items.append(CleanupItem(
                        title: "Simbol debug \(device) \(platform) \(entry.version)",
                        detail: "Dipakai saat debug di perangkat ini. Jika dihapus, Xcode menyalin ulang (±5–15 menit) saat perangkat dicolok.",
                        path: entry.url.path, bytes: bytes, category: .xcode, safety: .costly, action: .delete, lastActivity: modified
                    ))
                } else {
                    let reason = isNewest ? "Perangkat ini tidak dicolok lebih dari 4 bulan." : "Perangkat sudah memakai \(platform) yang lebih baru."
                    items.append(CleanupItem(
                        title: "Simbol debug lama \(device) \(platform) \(entry.version)",
                        detail: "\(reason) Aman dihapus; disalin ulang otomatis bila dibutuhkan.",
                        path: entry.url.path, bytes: bytes, category: .xcode, safety: .regenerable, action: .delete,
                        recommended: true, lastActivity: modified
                    ))
                }
            }
        }
        return items
    }
}

// MARK: - Gradle

/// Cache & distribusi Gradle per versi. Versi yang dirujuk `gradle-wrapper.properties`
/// di proyek Anda dipertahankan; sisanya aman dihapus.
public struct GradleProvider: ItemProvider {
    public var priority: Int { 90 }
    public var name: String { "Gradle" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let usedVersions = context.projects.gradleVersions
        let usedDistributions = context.projects.gradleDistributions
        var candidates: [(URL, String, String, Safety, Bool)] = []

        for url in PathTools.children(of: context.url(".gradle/caches")) where PathTools.isDirectory(url.path) {
            let name = url.lastPathComponent
            if name.range(of: #"^\d+(\.\d+)+"#, options: .regularExpression) != nil {
                if usedVersions.contains(name) {
                    candidates.append((url, "Cache Gradle \(name)", "Dipakai proyek Anda. Dihapus = build berikutnya lebih lama.", .costly, false))
                } else {
                    candidates.append((url, "Cache Gradle \(name) (tidak dipakai)", "Tidak ada proyek yang memakai Gradle \(name).", .regenerable, true))
                }
            } else if name.hasPrefix("build-cache") {
                candidates.append((url, "Build cache Gradle", "Hasil task yang di-cache. Dibuat ulang saat build.", .regenerable, true))
            } else if name.hasPrefix("transforms") {
                candidates.append((url, "Transform Gradle (\(name))", "Hasil transform dependency. Dibuat ulang saat build (build pertama lebih lama).", .regenerable, false))
            }
        }
        for url in PathTools.children(of: context.url(".gradle/wrapper/dists")) where PathTools.isDirectory(url.path) {
            let name = url.lastPathComponent
            if usedDistributions.contains(name) {
                candidates.append((url, "Distribusi \(name)", "Dipakai proyek Anda. Diunduh ulang (±150 MB) bila dihapus.", .costly, false))
            } else {
                candidates.append((url, "Distribusi \(name) (tidak dipakai)", "Tidak ada proyek yang merujuk \(name).", .regenerable, true))
            }
        }

        let sizes = await SizeCalculator.measureAll(candidates.map(\.0))
        return candidates.compactMap { url, title, detail, safety, recommended in
            guard let bytes = sizes[url]?.bytes, bytes >= 10 * MB else { return nil }
            return CleanupItem(
                title: title, detail: detail, path: url.path, bytes: bytes, category: .android, safety: safety,
                action: .delete, recommended: recommended, lastActivity: PathTools.modificationDate(url.path)
            )
        }
    }
}

// MARK: - Android SDK

public struct AndroidSDKProvider: ItemProvider {
    public var priority: Int { 90 }
    public var name: String { "Android SDK" }
    public init() {}

    static func sdkRoot(home: URL) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"], PathTools.isDirectory(path) {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Library/Android/sdk")
    }

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let sdk = Self.sdkRoot(home: context.home)
        let buildText = context.projects.buildFileText
        let compileSdks = context.projects.compileSdks
        var candidates: [(URL, String, String, Safety, Bool, CleanupAction)] = []

        for ndk in PathTools.children(of: sdk.appendingPathComponent("ndk")) where PathTools.isDirectory(ndk.path) {
            let version = ndk.lastPathComponent
            if buildText.contains(version) {
                candidates.append((ndk, "NDK \(version)", "Dirujuk `ndkVersion` proyek Anda.", .keep, false, .manual(instructions: "Masih dipakai.")))
            } else {
                candidates.append((ndk, "NDK \(version) (tidak dirujuk)", "Tidak ada proyek yang merujuk versi ini. Bisa diunduh ulang lewat sdkmanager (±1 GB).", .costly, false, .delete))
            }
        }
        let buildTools = PathTools.children(of: sdk.appendingPathComponent("build-tools")).filter { PathTools.isDirectory($0.path) }
        let newestBuildTools = buildTools.max { PathTools.compareVersions($0.lastPathComponent, $1.lastPathComponent) == .orderedAscending }
        for tools in buildTools where tools != newestBuildTools {
            let version = tools.lastPathComponent
            let referenced = buildText.contains(version)
            // AGP memilih build-tools bawaannya sendiri, jadi versi lama tidak dipilih otomatis.
            candidates.append((tools, "Build-tools \(version)", referenced ? "Dirujuk proyek Anda." : "Versi lama. AGP mengunduh ulang otomatis bila versinya dibutuhkan.",
                               .costly, false, .delete))
        }
        for platform in PathTools.children(of: sdk.appendingPathComponent("platforms")) where PathTools.isDirectory(platform.path) {
            let level = Int(platform.lastPathComponent.replacingOccurrences(of: "android-", with: "")) ?? 0
            if compileSdks.contains(level) {
                candidates.append((platform, "Platform Android \(level)", "compileSdk proyek Anda.", .keep, false, .manual(instructions: "Masih dipakai.")))
            } else {
                candidates.append((platform, "Platform Android \(level) (tidak dipakai)", "Tidak ada proyek dengan compileSdk \(level). Diunduh ulang otomatis bila dibutuhkan.", .costly, true, .delete))
            }
        }
        for source in PathTools.children(of: sdk.appendingPathComponent("sources")) where PathTools.isDirectory(source.path) {
            candidates.append((source, "Source Android (\(source.lastPathComponent))", "Hanya untuk navigasi kode di IDE; tidak dibutuhkan untuk build.", .regenerable, true, .delete))
        }
        for image in PathTools.children(of: sdk.appendingPathComponent("system-images")) where PathTools.isDirectory(image.path) {
            candidates.append((image, "System image emulator (\(image.lastPathComponent))", "Image emulator. Anda menguji di perangkat asli.", .review, false, .trash))
        }
        let emulator = sdk.appendingPathComponent("emulator")
        if PathTools.isDirectory(emulator.path) {
            candidates.append((emulator, "Android Emulator", "Program emulator. Tidak dibutuhkan bila selalu uji di perangkat asli.", .costly, false, .delete))
        }

        let sizes = await SizeCalculator.measureAll(candidates.map(\.0))
        return candidates.compactMap { url, title, detail, safety, recommended, action in
            guard let bytes = sizes[url]?.bytes, bytes >= 20 * MB else { return nil }
            return CleanupItem(
                title: title, detail: detail, path: url.path, bytes: bytes, category: .android, safety: safety,
                action: action, recommended: recommended, lastActivity: PathTools.modificationDate(url.path)
            )
        }
    }
}

// MARK: - Node (nvm) & Rust (rustup)

public struct ToolchainProvider: ItemProvider {
    public var priority: Int { 85 }
    public var name: String { "Toolchain" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        var candidates: [(URL, String, String, Safety)] = []

        let nvmDefault = (try? String(contentsOf: context.url(".nvm/alias/default"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "v")) ?? ""
        let nodeVersions = PathTools.children(of: context.url(".nvm/versions/node")).filter { PathTools.isDirectory($0.path) }
        let defaultNode = nodeVersions
            .filter { nvmDefault.isEmpty ? false : $0.lastPathComponent.dropFirst().hasPrefix(nvmDefault) }
            .max { PathTools.compareVersions($0.lastPathComponent, $1.lastPathComponent) == .orderedAscending }
        for node in nodeVersions {
            let version = String(node.lastPathComponent.dropFirst())
            let pinned = context.projects.nodeVersions.contains { version.hasPrefix($0) }
            if node == defaultNode || pinned {
                candidates.append((node, "Node \(node.lastPathComponent)", node == defaultNode ? "Versi default nvm." : "Dipin oleh .nvmrc proyek.", .keep))
            } else {
                candidates.append((node, "Node \(node.lastPathComponent) (bukan default)", "Tidak dipakai sebagai default dan tidak dipin proyek. Pasang ulang dengan `nvm install` bila perlu.", .costly))
            }
        }

        for toolchain in PathTools.children(of: context.url(".rustup/toolchains")) where PathTools.isDirectory(toolchain.path) {
            let name = toolchain.lastPathComponent
            if name.hasPrefix("stable") || name.hasPrefix("beta") || name.hasPrefix("nightly") {
                candidates.append((toolchain, "Rust \(name)", "Toolchain utama rustup.", .keep))
                continue
            }
            let pinned = context.projects.rustToolchains.contains { name.hasPrefix($0) }
            if pinned {
                candidates.append((toolchain, "Rust \(name)", "Dipin oleh rust-toolchain.toml proyek Anda.", .keep))
            } else {
                candidates.append((toolchain, "Rust \(name) (tidak dipin)", "Tidak ada proyek yang mem-pin versi ini. Pasang ulang via rustup bila perlu.", .costly))
            }
        }

        let sizes = await SizeCalculator.measureAll(candidates.map(\.0))
        return candidates.compactMap { url, title, detail, safety in
            guard let bytes = sizes[url]?.bytes, bytes >= 20 * MB else { return nil }
            let action: CleanupAction = safety == .keep ? .manual(instructions: "Masih dipakai.") : .delete
            return CleanupItem(title: title, detail: detail, path: url.path, bytes: bytes, category: .toolchains,
                               safety: safety, action: action, lastActivity: PathTools.modificationDate(url.path))
        }
    }
}

// MARK: - Ekstensi editor (VS Code, Antigravity, Cursor, …)

/// Editor berbasis VS Code menyimpan versi lama ekstensi setelah update. Yang dipakai hanya versi terbaru.
public struct EditorExtensionProvider: ItemProvider {
    public var priority: Int { 80 }
    public var name: String { "Ekstensi editor" }
    public init() {}

    static let roots = [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions", ".windsurf/extensions",
                        ".antigravity-ide/extensions", ".antigravity/extensions", ".kiro/extensions"]

    static func parse(_ name: String) -> (id: String, version: String, platform: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?)-(\d+\.\d+\.\d+)(?:-(.+))?$"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let id = Range(match.range(at: 1), in: name), let version = Range(match.range(at: 2), in: name) else { return nil }
        let platform = Range(match.range(at: 3), in: name).map { String(name[$0]) } ?? ""
        return (String(name[id]), String(name[version]), platform)
    }

    public func items(in context: ScanContext) async -> [CleanupItem] {
        var stale: [(URL, String, String)] = []
        for root in Self.roots {
            let base = context.url(root)
            let obsolete = (try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent(".obsolete")))) as? [String: Bool] ?? [:]
            let entries = PathTools.children(of: base).compactMap { url -> (URL, String, String)? in
                guard PathTools.isDirectory(url.path), let parsed = Self.parse(url.lastPathComponent) else { return nil }
                return (url, parsed.id, parsed.version)
            }
            for (_, group) in Dictionary(grouping: entries, by: \.1) {
                guard let newest = group.max(by: { PathTools.compareVersions($0.2, $1.2) == .orderedAscending }) else { continue }
                for entry in group where entry.0 != newest.0 {
                    stale.append((entry.0, "\(entry.1) \(entry.2)", "Versi lama; yang aktif \(newest.2). Editor: \(root.split(separator: "/").first ?? "")"))
                }
            }
            for (name, isObsolete) in obsolete where isObsolete {
                let url = base.appendingPathComponent(name)
                if PathTools.isDirectory(url.path), !stale.contains(where: { $0.0 == url }) {
                    stale.append((url, name, "Ditandai usang oleh editor."))
                }
            }
        }
        let sizes = await SizeCalculator.measureAll(stale.map(\.0))
        return stale.compactMap { url, title, detail in
            guard let bytes = sizes[url]?.bytes, bytes >= 5 * MB else { return nil }
            return CleanupItem(title: "Ekstensi lama: \(title)", detail: detail, path: url.path, bytes: bytes,
                               category: .aiTools, safety: .regenerable, action: .delete, recommended: true,
                               lastActivity: PathTools.modificationDate(url.path))
        }
    }
}

// MARK: - Riwayat sesi Codex

public struct CodexSessionProvider: ItemProvider {
    public var priority: Int { 80 }
    public var name: String { "Riwayat Codex" }
    public init() {}

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.dateComponents([.year, .month], from: context.now)
        let current = (now.year ?? 0) * 12 + (now.month ?? 0)
        var months: [(URL, Int, Int)] = []
        for year in PathTools.children(of: context.url(".codex/sessions")) {
            guard let y = Int(year.lastPathComponent) else { continue }
            for month in PathTools.children(of: year) {
                guard let m = Int(month.lastPathComponent), y * 12 + m < current else { continue }
                months.append((month, y, m))
            }
        }
        let sizes = await SizeCalculator.measureAll(months.map(\.0))
        return months.compactMap { url, year, month in
            guard let bytes = sizes[url]?.bytes, bytes >= 20 * MB else { return nil }
            return CleanupItem(
                title: "Riwayat sesi Codex · \(Formatters.monthYear(year: year, month: month))",
                detail: "Transkrip percakapan Codex bulan itu. Sesi lama tidak bisa dilanjutkan lagi bila dihapus; pindahkan ke SSD bila ingin disimpan.",
                path: url.path, bytes: bytes, category: .aiTools, safety: .review, action: .trash,
                lastActivity: PathTools.modificationDate(url.path), offloadable: true
            )
        }
    }
}
