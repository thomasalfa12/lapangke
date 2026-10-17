import Foundation

/// Semua yang dibutuhkan provider untuk menilai data: lokasi home, folder proyek,
/// dan indeks proyek (versi Gradle/NDK/toolchain yang benar-benar dipakai).
public struct ScanContext: Sendable {
    public var home: URL
    public var devRoots: [URL]
    public var inactiveDays: Int
    public var now: Date
    public var projects: ProjectIndex

    public init(home: URL, devRoots: [URL], inactiveDays: Int = 21, now: Date = Date(), projects: ProjectIndex = .empty) {
        self.home = home
        self.devRoots = devRoots
        self.inactiveDays = inactiveDays
        self.now = now
        self.projects = projects
    }

    public func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    public func daysSince(_ date: Date?) -> Int? { Formatters.days(since: date, now: now) }

    public func isInactive(_ date: Date?) -> Bool {
        guard let days = daysSince(date) else { return true }
        return days > inactiveDays
    }
}

public protocol ItemProvider: Sendable {
    /// Semakin tinggi, semakin diutamakan saat dua item menunjuk folder yang tumpang tindih.
    var priority: Int { get }
    var name: String { get }
    func items(in context: ScanContext) async -> [CleanupItem]
}

public struct Scanner: Sendable {
    public var settings: LapangkeSettings
    public var home: URL

    public init(settings: LapangkeSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.settings = settings
        self.home = home
    }

    public static func defaultProviders() -> [any ItemProvider] {
        [
            SimulatorProvider(), DeviceSupportProvider(), GradleProvider(), AndroidSDKProvider(),
            ToolchainProvider(), EditorExtensionProvider(), CodexSessionProvider(),
            ProjectArtifactProvider(), CatalogProvider(), PersonalFilesProvider(),
            InstalledAppsProvider(), OrphanedContainerProvider(), GenericCacheProvider(), SystemProvider(),
        ]
    }

    public func run(
        providers: [any ItemProvider] = Scanner.defaultProviders(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ScanReport {
        let started = Date()
        progress("Mengindeks proyek…")
        let roots = settings.resolvedDevRoots(home: home)
        let index = ProjectIndex.build(roots: roots)
        let context = ScanContext(home: home, devRoots: roots, inactiveDays: settings.inactiveDays, now: started, projects: index)

        var collected: [(Int, [CleanupItem])] = []
        await withTaskGroup(of: (Int, String, [CleanupItem]).self) { group in
            for provider in providers {
                group.addTask {
                    (provider.priority, provider.name, await provider.items(in: context))
                }
            }
            for await (priority, name, items) in group {
                progress("Selesai: \(name)")
                collected.append((priority, items))
            }
        }

        let merged = Self.merge(collected)
        progress("Membaca kondisi disk…")
        let disk = DiskInspector.snapshot(home: home)
        var notes: [String] = []
        if !disk.hasFullDiskAccess {
            notes.append("Full Disk Access belum aktif: Tong Sampah, Containers, dan media WhatsApp/Telegram tidak bisa diukur. Aktifkan di System Settings › Privacy & Security › Full Disk Access.")
        }
        if Toolchain.developerDir == nil {
            notes.append("Xcode tidak ditemukan, jadi simulator & runtime dilewati.")
        }
        return ScanReport(startedAt: started, duration: Date().timeIntervalSince(started), items: merged, disk: disk, notes: notes)
    }

    /// Item dari provider berprioritas tinggi menang; item lain yang tumpang tindih
    /// (folder induk atau anak) dibuang supaya tidak ada byte yang dihitung dua kali.
    public static func merge(_ batches: [(Int, [CleanupItem])]) -> [CleanupItem] {
        let ordered = batches.sorted { $0.0 > $1.0 }.flatMap { batch in
            batch.1.sorted { $0.bytes > $1.bytes }
        }
        var accepted: [CleanupItem] = []
        var acceptedPaths: [String] = []
        for item in ordered {
            let paths = [item.path] + (item.relatedPaths ?? [])
            let overlaps = paths.contains { path in
                acceptedPaths.contains { PathTools.isSameOrAncestor($0, of: path) || PathTools.isSameOrAncestor(path, of: $0) }
            }
            if overlaps { continue }
            accepted.append(item)
            acceptedPaths += paths
        }
        return accepted.sorted { lhs, rhs in
            lhs.safety == rhs.safety ? lhs.bytes > rhs.bytes : lhs.safety < rhs.safety
        }
    }
}

// MARK: - Indeks proyek

public struct Repository: Sendable, Hashable {
    public var root: URL
    public var lastActivity: Date?
}

/// Ringkasan proyek di folder kerja: repo git, proyek tanpa git, dan versi tool yang dirujuk
/// file build. Dipakai untuk memutuskan versi Gradle/NDK/toolchain mana yang masih penting.
public struct ProjectIndex: Sendable {
    public var repositories: [Repository]
    public var looseProjects: [URL]
    public var gradleDistributions: Set<String>
    public var buildFileText: String
    public var rustToolchains: Set<String>
    public var nodeVersions: Set<String>

    public static let empty = ProjectIndex(repositories: [], looseProjects: [], gradleDistributions: [], buildFileText: "", rustToolchains: [], nodeVersions: [])

    public var gradleVersions: Set<String> {
        Set(gradleDistributions.compactMap { name in
            name.split(separator: "-").dropFirst().first.map(String.init)
        })
    }

    public var compileSdks: Set<Int> {
        let regex = try? NSRegularExpression(pattern: #"compileSdk(?:Version)?\s*(?:=|\(|\s)\s*\"?(\d{2})"#)
        let text = buildFileText
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex?.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        } ?? [])
    }

    static let skippedDirectories: Set<String> = [
        "node_modules", ".git", "build", "DerivedData", "Pods", ".gradle", ".next", "dist",
        ".build", "target", ".cxx", ".kotlin", ".turbo", "out", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".svelte-kit", ".expo", ".dart_tool", ".wrangler", ".vercel", ".vinext",
    ]
    static let projectMarkers = [
        "package.json", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "Cargo.toml", "Package.swift", "Podfile", "pubspec.yaml", "pyproject.toml", "go.mod",
    ]

    public static func isProjectRoot(_ url: URL) -> Bool {
        let names = Set(PathTools.children(of: url).map(\.lastPathComponent))
        if projectMarkers.contains(where: names.contains) { return true }
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    public static func build(roots: [URL], maxDepth: Int = 6) -> ProjectIndex {
        var repos: [URL] = []
        var loose: [URL] = []
        var distributions: Set<String> = []
        var buildText = ""
        var rust: Set<String> = []
        var node: Set<String> = []

        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        func walk(_ dir: URL, depth: Int, insideProject: Bool) {
            let children = PathTools.children(of: dir)
            let names = Set(children.map(\.lastPathComponent))
            let isRepo = names.contains(".git")
            if isRepo { repos.append(dir) }
            var nowInsideProject = insideProject || isRepo
            if !nowInsideProject, isProjectRoot(dir) {
                loose.append(dir)
                nowInsideProject = true
            }
            for child in children {
                let name = child.lastPathComponent
                if PathTools.isSymlink(child.path) { continue }
                if PathTools.isDirectory(child.path) {
                    guard depth < maxDepth, !skippedDirectories.contains(name) else { continue }
                    // `.claude/worktrees` berisi worktree sesi Claude; folder tersembunyi lain dilewati.
                    if name.hasPrefix("."), name != ".claude" { continue }
                    walk(child, depth: depth + 1, insideProject: nowInsideProject)
                    continue
                }
                switch name {
                case "gradle-wrapper.properties":
                    let text = read(child)
                    if let match = text.range(of: #"gradle-[0-9][0-9A-Za-z.\-]*-(bin|all)"#, options: .regularExpression) {
                        distributions.insert(String(text[match]))
                    }
                case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
                     "libs.versions.toml", "gradle.properties":
                    buildText += read(child) + "\n"
                case "rust-toolchain", "rust-toolchain.toml":
                    let text = read(child)
                    if let match = text.range(of: #"[0-9]+\.[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
                        rust.insert(String(text[match]))
                    }
                case ".nvmrc", ".node-version":
                    let version = read(child).trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                    if !version.isEmpty { node.insert(version) }
                default:
                    break
                }
            }
        }

        for root in roots where PathTools.isDirectory(root.path) {
            walk(root, depth: 0, insideProject: false)
        }

        let repositories = repos.map { Repository(root: $0, lastActivity: lastActivity(ofRepository: $0)) }
        // Proyek tanpa git yang ternyata berada di dalam repo tidak perlu dipindai dua kali.
        let repoPaths = repos.map(\.path)
        let looseOnly = loose.filter { project in
            !repoPaths.contains { PathTools.isSameOrAncestor($0, of: project.path) }
        }
        return ProjectIndex(
            repositories: repositories, looseProjects: looseOnly, gradleDistributions: distributions,
            buildFileText: buildText, rustToolchains: rust, nodeVersions: node
        )
    }

    /// Aktivitas terakhir = commit terakhir atau perubahan index git (add/status/checkout).
    public static func lastActivity(ofRepository root: URL) -> Date? {
        var candidates: [Date] = []
        let log = Toolchain.git(["log", "-1", "--format=%ct"], in: root, timeout: 20)
        if log.ok, let seconds = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            candidates.append(Date(timeIntervalSince1970: seconds))
        }
        let dotGit = root.appendingPathComponent(".git")
        var gitDir = dotGit.path
        if !PathTools.isDirectory(dotGit.path),
           let text = try? String(contentsOf: dotGit, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") { gitDir = root.appendingPathComponent(gitDir).standardizedFileURL.path }
        }
        if let index = PathTools.modificationDate(gitDir + "/index") { candidates.append(index) }
        return candidates.max()
    }
}
