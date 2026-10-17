import Foundation

/// Cache dev yang bisa diarahkan permanen ke SSD, sehingga build berikutnya tidak lagi
/// memenuhi disk internal. Bila SSD dicabut, semuanya otomatis kembali memakai lokasi bawaan.
public enum DevCache: String, CaseIterable, Codable, Sendable, Identifiable {
    case xcodeDerivedData
    case gradleHome
    case npmCache

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xcodeDerivedData: "DerivedData Xcode"
        case .gradleHome: "Gradle (cache, wrapper, JDK)"
        case .npmCache: "Cache npm"
        }
    }

    public var detail: String {
        switch self {
        case .xcodeDerivedData:
            "Lewat pengaturan Xcode (Locations › Derived Data). Build Xcode berikutnya menulis ke SSD. Skrip yang memakai `-derivedDataPath` sendiri tidak terpengaruh."
        case .gradleHome:
            "Lewat GRADLE_USER_HOME di ~/.zshenv, aktif hanya bila SSD terpasang. Berlaku untuk Gradle dari Terminal; buka terminal baru setelah menerapkan."
        case .npmCache:
            "Lewat npm_config_cache di ~/.zshenv, aktif hanya bila SSD terpasang."
        }
    }

    /// Nama folder di SSD. Akhiran `.noindex` membuat Spotlight melewatinya.
    var folderName: String {
        switch self {
        case .xcodeDerivedData: "DerivedData.noindex"
        case .gradleHome: "gradle.noindex"
        case .npmCache: "npm-cache.noindex"
        }
    }

    var environmentVariable: String? {
        switch self {
        case .xcodeDerivedData: nil
        case .gradleHome: "GRADLE_USER_HOME"
        case .npmCache: "npm_config_cache"
        }
    }
}

public struct RelocationService: Sendable {
    public static let devFolder = "Lapangke Dev"
    static let beginMarker = "# >>> Lapangke: cache dev di SSD (dikelola otomatis, jangan diedit) >>>"
    static let endMarker = "# <<< Lapangke <<<"

    public var home: URL
    public var zshenv: URL
    public var defaultsDomain: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaultsDomain: String = "com.apple.dt.Xcode") {
        self.home = home
        zshenv = home.appendingPathComponent(".zshenv")
        self.defaultsDomain = defaultsDomain
    }

    /// Lokasi aktif tiap cache saat ini (nil = lokasi bawaan di disk internal).
    public func currentTargets() -> [DevCache: String] {
        var result: [DevCache: String] = [:]
        let xcode = Shell.run("/usr/bin/defaults", ["read", defaultsDomain, "IDECustomDerivedDataLocation"], timeout: 10)
        if xcode.ok {
            let value = xcode.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[.xcodeDerivedData] = value }
        }
        for (cache, path) in managedExports() { result[cache] = path }
        return result
    }

    public func apply(_ caches: Set<DevCache>, volume: VolumeInfo) throws {
        guard volume.supportsDevWork else { throw OffloadError.unsupportedFormat(volume.formatName) }
        let root = URL(fileURLWithPath: volume.mountPath).appendingPathComponent(Self.devFolder)
        var exports = managedExports()
        for cache in caches {
            let target = root.appendingPathComponent(cache.folderName)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            // Cache tidak perlu ikut backup Time Machine.
            Shell.run("/usr/bin/tmutil", ["addexclusion", target.path], timeout: 20)
            switch cache {
            case .xcodeDerivedData:
                let result = Shell.run("/usr/bin/defaults", ["write", defaultsDomain, "IDECustomDerivedDataLocation", target.path], timeout: 10)
                guard result.ok else { throw OffloadError.copyFailed(result.stderr) }
            case .gradleHome:
                copyGradleConfiguration(to: target)
                exports[cache] = target.path
            case .npmCache:
                exports[cache] = target.path
            }
        }
        try writeExports(exports)
    }

    public func revert(_ caches: Set<DevCache>) throws {
        var exports = managedExports()
        for cache in caches {
            switch cache {
            case .xcodeDerivedData:
                Shell.run("/usr/bin/defaults", ["delete", defaultsDomain, "IDECustomDerivedDataLocation"], timeout: 10)
            case .gradleHome, .npmCache:
                exports[cache] = nil
            }
        }
        try writeExports(exports)
    }

    /// gradle.properties & init script (bisa berisi kredensial signing) disalin, bukan dipindah,
    /// supaya build tetap jalan saat SSD dicabut dan Gradle kembali ke ~/.gradle.
    func copyGradleConfiguration(to target: URL) {
        let source = home.appendingPathComponent(".gradle")
        for name in ["gradle.properties", "init.d", "init.gradle", "init.gradle.kts"] {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard PathTools.exists(from.path), !PathTools.exists(to.path) else { continue }
            try? FileManager.default.copyItem(at: from, to: to)
        }
    }

    // MARK: ~/.zshenv

    func managedExports() -> [DevCache: String] {
        guard let text = try? String(contentsOf: zshenv, encoding: .utf8),
              let start = text.range(of: Self.beginMarker), let end = text.range(of: Self.endMarker),
              start.upperBound <= end.lowerBound else { return [:] }
        var result: [DevCache: String] = [:]
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            for cache in DevCache.allCases {
                guard let variable = cache.environmentVariable else { continue }
                let prefix = "export \(variable)=\""
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(prefix), trimmed.hasSuffix("\"") {
                    result[cache] = String(trimmed.dropFirst(prefix.count).dropLast())
                }
            }
        }
        return result
    }

    static func block(for exports: [DevCache: String]) -> String {
        guard !exports.isEmpty else { return "" }
        var lines = [beginMarker]
        for cache in DevCache.allCases {
            guard let variable = cache.environmentVariable, let path = exports[cache] else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            lines.append("if [ -d \"\(folder)\" ]; then")
            lines.append("  export \(variable)=\"\(path)\"")
            lines.append("fi")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    func writeExports(_ exports: [DevCache: String]) throws {
        var text = (try? String(contentsOf: zshenv, encoding: .utf8)) ?? ""
        if let start = text.range(of: Self.beginMarker), let end = text.range(of: Self.endMarker), start.lowerBound < end.upperBound {
            var removalEnd = end.upperBound
            if removalEnd < text.endIndex, text[removalEnd] == "\n" { removalEnd = text.index(after: removalEnd) }
            text.removeSubrange(start.lowerBound..<removalEnd)
        }
        let block = Self.block(for: exports)
        if !block.isEmpty {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += block + "\n"
        }
        if text.isEmpty, !PathTools.exists(zshenv.path) { return }
        // Dotfiles yang di-symlink tetap jadi symlink: tulis ke file tujuannya.
        try text.write(to: zshenv.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
    }
}
