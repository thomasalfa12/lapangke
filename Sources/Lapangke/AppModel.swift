import AppKit
import LapangkeCore
import Observation
import ServiceManagement
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview, cleanup, map, apps, ssd, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Ringkasan"
        case .cleanup: "Pembersihan"
        case .map: "Peta Storage"
        case .apps: "Aplikasi"
        case .ssd: "SSD Eksternal"
        case .history: "Riwayat"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .map: "square.grid.3x3.square"
        case .apps: "square.grid.2x2"
        case .ssd: "externaldrive"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum ItemFilter: String, CaseIterable, Identifiable {
    case recommended = "Rekomendasi"
    case deletable = "Bisa dibersihkan"
    case review = "Periksa dulu"
    case all = "Semua"

    var id: String { rawValue }

    func includes(_ item: CleanupItem) -> Bool {
        switch self {
        case .recommended: item.recommended
        case .deletable: item.isSelectable
        case .review: item.safety == .review
        case .all: true
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var pane: Pane = .overview
    var settings = LapangkeSettings.load() {
        didSet { settings.save() }
    }

    // Pindai
    var report: ScanReport?
    var isScanning = false
    var scanStatus = ""

    // Pembersihan
    var selection: Set<String> = []
    var filter: ItemFilter = .recommended
    var categoryFilter: ItemCategory?
    var search = ""
    var pendingCleanup: [CleanupItem]?
    var isCleaning = false
    var cleanProgress = 0.0
    var cleanCurrent = ""
    var outcomes: [CleanupOutcome] = []

    // Disk & SSD
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var volumes: [VolumeInfo] = []
    var offloads: [OffloadRecord] = []
    var relocationTargets: [DevCache: String] = [:]
    var speedResults: [String: VolumeService.SpeedResult] = [:]
    var speedTesting: String?
    var busyMessage: String?
    var errorMessage: String?
    var noticeMessage: String?

    // Lainnya
    var activity: [ActivityEntry] = []
    var apps: [InstalledApp] = []
    var appsLoading = false
    var storageMap: StorageMap?
    var isMapping = false
    var mapStatus = ""

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        report = Self.loadCachedReport()
        selection = Set(report?.recommendedItems.map(\.id) ?? [])
        storageMap = StorageMapper.load()
        refreshFreeSpace()
        refreshVolumes()
        offloads = OffloadService().records()
        activity = ActivityLog().load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFreeSpace() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
    }

    // MARK: Turunan

    var isLowOnSpace: Bool { freeBytes < Int64(settings.lowSpaceWarningGB) * GB }
    var workVolume: VolumeInfo? { volumes.first { $0.uuid != nil && $0.uuid == settings.workVolumeUUID } }

    var visibleItems: [CleanupItem] {
        guard let report else { return [] }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return report.items.filter { item in
            filter.includes(item)
                && (categoryFilter == nil || item.category == categoryFilter)
                && (query.isEmpty || item.title.lowercased().contains(query) || item.path.lowercased().contains(query))
        }
    }

    var selectedItems: [CleanupItem] {
        report?.items.filter { selection.contains($0.id) && $0.isSelectable } ?? []
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    // MARK: Pindai

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "Memulai…"
        let settings = settings
        let report = await Task.detached(priority: .userInitiated) {
            await Scanner(settings: settings).run { message in
                Task { @MainActor in self.scanStatus = message }
            }
        }.value
        self.report = report
        selection = Set(report.recommendedItems.map(\.id))
        isScanning = false
        scanStatus = ""
        refreshFreeSpace()
        Self.cacheReport(report)
    }

    func selectRecommended() {
        selection = Set(report?.recommendedItems.map(\.id) ?? [])
    }

    func toggle(_ item: CleanupItem) {
        guard item.isSelectable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    // MARK: Bersihkan

    func requestCleanup(_ items: [CleanupItem]) {
        let actionable = items.filter(\.isSelectable)
        guard !actionable.isEmpty else { return }
        outcomes = []
        pendingCleanup = actionable
    }

    func performCleanup() async {
        guard let items = pendingCleanup, !isCleaning else { return }
        isCleaning = true
        cleanProgress = 0
        let results = await Task.detached(priority: .userInitiated) {
            await Cleaner().run(items) { done, total, current in
                Task { @MainActor in
                    self.cleanProgress = total == 0 ? 1 : Double(done) / Double(total)
                    self.cleanCurrent = current
                }
            }
        }.value
        outcomes = await retryAppBundlesWithFinder(results)
        isCleaning = false
        if items.contains(where: { $0.category == .apps }) { Task { await loadApps() } }
        let done = Set(outcomes.filter(\.success).map(\.id))
        report?.items.removeAll { done.contains($0.id) }
        selection.subtract(done)
        if let report { Self.cacheReport(report) }
        refreshFreeSpace()
        activity = ActivityLog().load()
    }

    /// App dari App Store dimiliki root: FileManager tidak boleh memindahkannya, tetapi Finder boleh
    /// (macOS meminta password admin). Sisa datanya sudah diproses Cleaner.
    func retryAppBundlesWithFinder(_ results: [CleanupOutcome]) async -> [CleanupOutcome] {
        var updated = results
        for (index, outcome) in results.enumerated() where !outcome.success && outcome.item.path.hasSuffix(".app") {
            do {
                try SafetyGuard().validate(path: outcome.item.path, allowApplicationBundle: true)
                _ = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: outcome.item.path)])
                let failed = Cleaner().processRelated(outcome.item) {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil)
                }
                updated[index].success = failed.isEmpty
                updated[index].message = failed.isEmpty ? "Dipindah ke Tong Sampah lewat Finder" : "App terhapus; sebagian data dilewati"
            } catch {
                updated[index].message = "Tidak bisa dihapus: \(error.localizedDescription)"
            }
        }
        return updated
    }

    // MARK: Disk & SSD

    func refreshFreeSpace() {
        let space = DiskInspector.freeSpace()
        freeBytes = space.available
        totalBytes = space.total
    }

    func refreshVolumes() {
        Task {
            let volumes = await Task.detached { VolumeService.externalVolumes() }.value
            let targets = await Task.detached { RelocationService().currentTargets() }.value
            self.volumes = volumes
            relocationTargets = targets
            offloads = OffloadService().records()
            if settings.workVolumeUUID == nil, volumes.count == 1, let only = volumes.first, only.supportsDevWork {
                settings.workVolumeUUID = only.uuid
            }
        }
    }

    func offloadStatus(_ record: OffloadRecord) -> OffloadStatus { OffloadService().status(of: record) }

    func offload(_ item: CleanupItem) async {
        guard let volume = workVolume else {
            errorMessage = "Pilih SSD kerja dulu di bagian SSD Eksternal."
            return
        }
        let symlink = [.projects, .xcode, .aiTools, .android, .toolchains].contains(item.category)
        busyMessage = "Memindahkan \(item.title) ke \(volume.name)…"
        do {
            let record = try await Task.detached {
                try await OffloadService().offload(item, to: volume, symlinkBack: symlink) { copied in
                    Task { @MainActor in
                        self.busyMessage = "Memindahkan \(item.title): \(copied.bytesText) dari \(item.bytes.bytesText)…"
                    }
                }
            }.value
            report?.items.removeAll { $0.id == item.id }
            selection.remove(item.id)
            noticeMessage = "\(record.title) dipindah ke \(volume.name)\(record.symlinked ? " (lokasi lama jadi tautan ke SSD)" : "")."
        } catch {
            errorMessage = error.localizedDescription
        }
        busyMessage = nil
        refreshFreeSpace()
        refreshVolumes()
        activity = ActivityLog().load()
    }

    func restore(_ record: OffloadRecord) async {
        busyMessage = "Mengembalikan \(record.title) ke Mac…"
        do {
            try await Task.detached { try await OffloadService().restore(record) }.value
            noticeMessage = "\(record.title) sudah kembali ke lokasi asalnya."
        } catch {
            errorMessage = error.localizedDescription
        }
        busyMessage = nil
        refreshFreeSpace()
        refreshVolumes()
        activity = ActivityLog().load()
    }

    func forget(_ record: OffloadRecord) {
        OffloadService().forget(record)
        offloads = OffloadService().records()
    }

    func speedTest(_ volume: VolumeInfo) async {
        speedTesting = volume.id
        do {
            let result = try await Task.detached { try VolumeService.speedTest(at: URL(fileURLWithPath: volume.mountPath)) }.value
            speedResults[volume.id] = result
        } catch {
            errorMessage = "Uji kecepatan gagal: \(error.localizedDescription)"
        }
        speedTesting = nil
    }

    func eject(_ volume: VolumeInfo) {
        let result = VolumeService.eject(volume)
        if !result.ok { errorMessage = "Gagal mengeluarkan: \(result.stderr)" }
        refreshVolumes()
    }

    func applyRelocation(_ caches: Set<DevCache>) {
        guard let volume = workVolume else { return }
        do {
            try RelocationService().apply(caches, volume: volume)
            noticeMessage = "Cache dev diarahkan ke \(volume.name). Buka terminal baru agar Gradle/npm memakainya."
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshVolumes()
    }

    func revertRelocation(_ caches: Set<DevCache>) {
        do {
            try RelocationService().revert(caches)
            noticeMessage = "Cache dev kembali ke lokasi bawaan di Mac."
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshVolumes()
    }

    // MARK: Aplikasi & peta

    func loadApps() async {
        guard !appsLoading else { return }
        appsLoading = true
        apps = await Task.detached { await InstalledApps.list() }.value
        appsLoading = false
    }

    func buildMap() async {
        guard !isMapping else { return }
        isMapping = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map = await Task.detached(priority: .userInitiated) {
            await StorageMapper.map(roots: StorageMapper.defaultRoots(home: home)) { message in
                Task { @MainActor in self.mapStatus = message }
            }
        }.value
        StorageMapper.save(map)
        storageMap = map
        isMapping = false
        mapStatus = ""
    }

    // MARK: Sistem

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Gagal mengubah 'buka saat login': \(error.localizedDescription)"
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if PathTools.exists(path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: Cache laporan

    static func cacheReport(_ report: ScanReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { try? data.write(to: AppPaths.lastReport, options: .atomic) }
    }

    static func loadCachedReport() -> ScanReport? {
        guard let data = try? Data(contentsOf: AppPaths.lastReport) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanReport.self, from: data)
    }
}
