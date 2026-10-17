import Foundation

/// Artefak build di folder proyek. Untuk repo git, kandidat diambil dari
/// `git ls-files --others --ignored --directory` — jadi hanya folder yang memang diabaikan git
/// (bukan kode sumber) yang bisa muncul. Folder rahasia & proyek bersarang selalu dilewati.
public struct ProjectArtifactProvider: ItemProvider {
    public var priority: Int { 70 }
    public var name: String { "Artefak proyek" }
    public init() {}

    enum Kind {
        case dependencies      // node_modules, Pods, .venv — ikut aktivitas repo
        case buildOutput       // hasil build — ikut umur isi folder
        case xcodeBuildFolder  // build/ gaya Xcode: dipecah per isi
        case unknownIgnored    // folder diabaikan git, bukan artefak yang dikenal
    }

    static let simpleArtifacts: [String: (title: String, marker: [String]?, kind: Kind, safety: Safety)] = [
        "node_modules": ("Dependency npm (node_modules)", ["package.json"], .dependencies, .regenerable),
        ".next": ("Build Next.js (.next)", ["package.json"], .buildOutput, .regenerable),
        ".nuxt": ("Build Nuxt (.nuxt)", ["package.json"], .buildOutput, .regenerable),
        ".svelte-kit": ("Build SvelteKit", ["package.json"], .buildOutput, .regenerable),
        ".turbo": ("Cache Turborepo", nil, .buildOutput, .regenerable),
        ".parcel-cache": ("Cache Parcel", nil, .buildOutput, .regenerable),
        ".vite": ("Cache Vite", nil, .buildOutput, .regenerable),
        ".angular": ("Cache Angular", nil, .buildOutput, .regenerable),
        ".expo": ("Cache Expo", nil, .buildOutput, .regenerable),
        ".vinext": ("Build vinext", ["package.json"], .buildOutput, .regenerable),
        ".gradle": ("Cache Gradle proyek", ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"], .buildOutput, .regenerable),
        ".cxx": ("Build native CMake (.cxx)", ["build.gradle", "build.gradle.kts"], .buildOutput, .regenerable),
        ".externalNativeBuild": ("Build native lama", ["build.gradle", "build.gradle.kts"], .buildOutput, .regenerable),
        ".kotlin": ("Data daemon Kotlin", nil, .buildOutput, .regenerable),
        "DerivedData": ("DerivedData proyek", nil, .buildOutput, .regenerable),
        ".build": ("Build SwiftPM (.build)", ["Package.swift"], .buildOutput, .regenerable),
        "Pods": ("CocoaPods (Pods)", ["Podfile"], .dependencies, .costly),
        "target": ("Build Rust/Maven (target)", ["Cargo.toml", "pom.xml"], .buildOutput, .regenerable),
        ".dart_tool": ("Cache Dart", ["pubspec.yaml"], .buildOutput, .regenerable),
        ".venv": ("Virtualenv Python", nil, .dependencies, .costly),
        "venv": ("Virtualenv Python", ["requirements.txt", "pyproject.toml"], .dependencies, .costly),
        "__pycache__": ("Cache Python", nil, .buildOutput, .regenerable),
        ".pytest_cache": ("Cache pytest", nil, .buildOutput, .regenerable),
        "coverage": ("Laporan coverage", ["package.json"], .buildOutput, .regenerable),
        "storybook-static": ("Build Storybook", ["package.json"], .buildOutput, .regenerable),
        "dist": ("Hasil build (dist)", ["package.json"], .buildOutput, .regenerable),
    ]

    /// Folder yang diabaikan git tapi berisi status/kredensial — tidak pernah disarankan.
    static let ignoredButImportant: Set<String> = [
        ".idea", ".vscode", ".vercel", ".claude", ".codex", ".wrangler", ".env", ".supabase", ".firebase",
        "local.properties", ".terraform", ".aws-sam", "secrets", "keystore", "keystores", "signing", "certs", "certificates",
    ]

    public func items(in context: ScanContext) async -> [CleanupItem] {
        let repos = context.projects.repositories
        let repoRoots = repos.map(\.root.path)
        var candidates: [Candidate] = []

        for repo in repos {
            let listing = Toolchain.git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: repo.root, timeout: 120)
            guard listing.ok else { continue }
            for entry in listing.stdout.split(separator: "\0") where entry.hasSuffix("/") {
                let url = repo.root.appendingPathComponent(String(entry.dropLast()))
                if repoRoots.contains(where: { $0 != repo.root.path && PathTools.isSameOrAncestor(url.path, of: $0) }) { continue }
                // Folder yang diabaikan git tapi berisi kode (mis. proyek lain yang di-ignore):
                // jangan disarankan utuh, cukup cari artefak build di dalamnya.
                if Self.simpleArtifacts[url.lastPathComponent] == nil, url.lastPathComponent != "build", Self.containsSource(url) {
                    candidates += findArtifacts(in: url, activity: repo.lastActivity, depth: 0)
                    continue
                }
                candidates += classify(url, activity: repo.lastActivity, gitIgnored: true)
            }
        }
        for project in context.projects.looseProjects {
            let activity = PathTools.children(of: project).compactMap { PathTools.modificationDate($0.path) }.max()
            candidates += findArtifacts(in: project, activity: activity, depth: 0)
        }

        let sizes = await SizeCalculator.measureAll(candidates.map(\.url), trackNewest: true, concurrency: 6)
        var items: [CleanupItem] = []
        for candidate in candidates {
            guard let size = sizes[candidate.url], size.bytes >= candidate.minBytes else { continue }
            if candidate.kind == .unknownIgnored, size.bytes >= GB {
                let children = PathTools.children(of: candidate.url).filter { PathTools.isDirectory($0.path) && !PathTools.isSymlink($0.path) }
                if children.count >= 2 {
                    items += await expand(candidate, children: children, context: context)
                    continue
                }
            }
            items.append(makeItem(candidate, size: size, context: context))
        }
        return items
    }

    struct Candidate {
        var url: URL
        var title: String
        var kind: Kind
        var safety: Safety
        var repoActivity: Date?
        var minBytes: Int64 = 20 * MB
        var warnings: [String] = []
        var offloadable = false
    }

    func classify(_ url: URL, activity: Date?, gitIgnored: Bool) -> [Candidate] {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        let lower = name.lowercased()
        if Self.ignoredButImportant.contains(lower) || lower.hasPrefix(".env")
            || ["secret", "keystore", "credential", "signing", "private"].contains(where: lower.contains) {
            return []
        }
        // Folder diabaikan tapi berisi proyek sungguhan (mis. SDK vendor yang di-ignore) bukan artefak.
        if Self.simpleArtifacts[name] == nil, name != "build", ProjectIndex.isProjectRoot(url) { return [] }

        if name == "build" { return classifyBuild(url, activity: activity) }
        if let known = Self.simpleArtifacts[name] {
            if let markers = known.marker, !markers.contains(where: { PathTools.exists(parent.appendingPathComponent($0).path) }) {
                return gitIgnored ? [Candidate(url: url, title: "Folder diabaikan git: \(name)", kind: .unknownIgnored, safety: .review, repoActivity: activity, minBytes: 100 * MB, offloadable: true)] : []
            }
            return [Candidate(url: url, title: known.title, kind: known.kind, safety: known.safety, repoActivity: activity)]
        }
        guard gitIgnored else { return [] }
        return [Candidate(url: url, title: "Folder diabaikan git: \(name)", kind: .unknownIgnored, safety: .review,
                          repoActivity: activity, minBytes: 100 * MB, offloadable: true)]
    }

    func classifyBuild(_ url: URL, activity: Date?) -> [Candidate] {
        let parent = url.deletingLastPathComponent()
        let siblings = Set(PathTools.children(of: parent).map(\.lastPathComponent))
        if siblings.contains("build.gradle") || siblings.contains("build.gradle.kts") {
            var candidate = Candidate(url: url, title: "Build Gradle (\(parent.lastPathComponent)/build)", kind: .buildOutput, safety: .regenerable, repoActivity: activity)
            let release = Self.releaseArtifacts(in: url)
            if !release.isEmpty {
                candidate.safety = .costly
                candidate.warnings.append("Berisi \(release.joined(separator: ", ")). Pastikan sudah diunggah ke Play Console sebelum menghapus.")
            }
            return [candidate]
        }
        let isXcode = siblings.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            || siblings.contains("project.yml") || siblings.contains("Package.swift")
        if isXcode {
            return PathTools.children(of: url).filter { PathTools.isDirectory($0.path) && !PathTools.isSymlink($0.path) }.map { child in
                let name = child.lastPathComponent
                if name.contains("DerivedData") {
                    return Candidate(url: child, title: "DerivedData proyek (\(parent.lastPathComponent)/build/\(name))", kind: .buildOutput, safety: .regenerable, repoActivity: activity)
                }
                if name == "Archives" || name.hasSuffix(".xcarchive") {
                    return Candidate(url: child, title: "Arsip rilis iOS (\(name))", kind: .unknownIgnored, safety: .review, repoActivity: activity,
                                     warnings: ["Berisi dSYM untuk membaca crash build yang beredar. Lebih baik pindahkan ke SSD."], offloadable: true)
                }
                return Candidate(url: child, title: "Hasil kerja build/\(name)", kind: .unknownIgnored, safety: .review, repoActivity: activity, minBytes: 50 * MB, offloadable: true)
            }
        }
        if siblings.contains("package.json") || siblings.contains("Cargo.toml") || siblings.contains("CMakeLists.txt") {
            return [Candidate(url: url, title: "Hasil build (\(parent.lastPathComponent)/build)", kind: .buildOutput, safety: .regenerable, repoActivity: activity)]
        }
        return [Candidate(url: url, title: "Folder build (\(parent.lastPathComponent)/build)", kind: .unknownIgnored, safety: .review, repoActivity: activity, minBytes: 100 * MB, offloadable: true)]
    }

    static let sourceFolders: Set<String> = ["src", "Sources", "lib", "app", "include", "cmd", "pkg"]
    static let sourceExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "ts", "tsx", "js", "jsx", "svelte", "vue", "rs", "go", "py", "c", "cc", "cpp", "h", "m", "mm",
    ]

    /// Folder berisi kode sumber (bukan hasil build), dilihat dari isi level teratasnya.
    static func containsSource(_ url: URL) -> Bool {
        if ProjectIndex.isProjectRoot(url) || PathTools.exists(url.appendingPathComponent(".git").path) { return true }
        return PathTools.children(of: url).contains { child in
            PathTools.isDirectory(child.path)
                ? sourceFolders.contains(child.lastPathComponent)
                : sourceExtensions.contains(child.pathExtension.lowercased())
        }
    }

    /// AAB/APK rilis & mapping R8 adalah artefak yang mahal bila hilang sebelum diunggah.
    static func releaseArtifacts(in build: URL) -> [String] {
        var found: [String] = []
        let outputs = build.appendingPathComponent("outputs")
        if !PathTools.children(of: outputs.appendingPathComponent("bundle")).isEmpty { found.append("AAB rilis") }
        let apkDirs = PathTools.children(of: outputs.appendingPathComponent("apk"))
        if apkDirs.contains(where: { $0.lastPathComponent.lowercased().contains("release") || $0.lastPathComponent.lowercased().contains("prod") }) {
            found.append("APK rilis")
        }
        if PathTools.exists(outputs.appendingPathComponent("mapping").path) { found.append("mapping R8") }
        return found
    }

    /// Proyek tanpa git: cari artefak yang dikenal saja (tidak ada "folder tak dikenal").
    func findArtifacts(in dir: URL, activity: Date?, depth: Int) -> [Candidate] {
        guard depth <= 4 else { return [] }
        var result: [Candidate] = []
        for child in PathTools.children(of: dir) where PathTools.isDirectory(child.path) && !PathTools.isSymlink(child.path) {
            let name = child.lastPathComponent
            if name == ".git" { continue }
            let found = (Self.simpleArtifacts[name] != nil || name == "build") ? classify(child, activity: activity, gitIgnored: false) : []
            if found.isEmpty {
                if !name.hasPrefix(".") { result += findArtifacts(in: child, activity: activity, depth: depth + 1) }
            } else {
                result += found
            }
        }
        return result
    }

    func makeItem(_ candidate: Candidate, size: SizeResult, context: ScanContext) -> CleanupItem {
        let repoInactive = context.isInactive(candidate.repoActivity)
        let outputStale = (context.daysSince(size.newest) ?? Int.max) > 7
        var safety = candidate.safety
        var recommended = false
        var detail: String
        let project = candidate.url.path.abbreviatingHome

        switch candidate.kind {
        case .dependencies:
            if !repoInactive, safety == .regenerable { safety = .costly }
            recommended = repoInactive
            detail = repoInactive
                ? "Proyek tidak aktif \(context.daysSince(candidate.repoActivity).map { "\($0) hari" } ?? "lama"). Pasang ulang dengan npm/pnpm install saat dibutuhkan."
                : "Proyek sedang aktif. Aman dihapus, tapi perlu install ulang (butuh internet)."
        case .buildOutput, .xcodeBuildFolder:
            recommended = safety == .regenerable && (repoInactive || outputStale)
            let age = size.newest.map { "Terakhir diubah \(Formatters.relative($0, now: context.now))." } ?? ""
            detail = "Hasil build, dibuat ulang otomatis saat build berikutnya. \(age)"
        case .unknownIgnored:
            detail = "Folder di luar kode sumber (diabaikan git). Bisa berisi hasil kerja seperti screenshot, rekaman, atau rilis — periksa dulu atau pindahkan ke SSD."
        }
        if candidate.url.path.contains("/.claude/worktrees/") {
            detail += " Berada di worktree sesi Claude."
        }
        return CleanupItem(
            title: candidate.title, detail: detail + "\n\(project)", path: candidate.url.path, bytes: size.bytes,
            category: .projects, safety: safety, action: safety == .review ? .trash : .delete,
            recommended: recommended, lastActivity: size.newest ?? candidate.repoActivity,
            offloadable: candidate.offloadable || candidate.kind == .unknownIgnored, warnings: candidate.warnings
        )
    }

    /// Folder tak dikenal yang besar (mis. `output/` 9 GB) dipecah per subfolder supaya
    /// Anda bisa menyimpan yang baru dan memindahkan/menghapus yang lama.
    func expand(_ candidate: Candidate, children: [URL], context: ScanContext) async -> [CleanupItem] {
        let sizes = await SizeCalculator.measureAll(children, trackNewest: true)
        return children.compactMap { child in
            guard let size = sizes[child], size.bytes >= 20 * MB else { return nil }
            var sub = candidate
            sub.url = child
            sub.title = "\(candidate.url.lastPathComponent)/\(child.lastPathComponent)"
            return makeItem(sub, size: size, context: context)
        }
    }
}
