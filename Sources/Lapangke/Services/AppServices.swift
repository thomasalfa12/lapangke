import AppKit
import LapangkeCore
import Observation
@preconcurrency import UserNotifications

/// Penghubung model, Pulau Lapangke, notifikasi, dan pengawas latar. Satu instans selama app hidup.
@MainActor
final class AppServices: NSObject {
    static let shared = AppServices()

    let model = AppModel()
    let island = IslandController()
    let notifications = NotificationService()
    /// Diisi oleh scene SwiftUI agar jendela utama bisa dibuka dari menu bar, pulau, atau notifikasi.
    var openMainWindow: (() -> Void)?

    private var timer: Timer?
    private var samples: [(date: Date, free: Int64)] = []
    private var baseline: [String: Int64] = [:]
    private var knownVolumes: Set<String> = []
    private var started = false

    private let defaults = UserDefaults.standard
    private static let lowAlertKey = "lastLowSpaceAlert"
    private static let dropAlertKey = "lastSpaceDropAlert"
    private static let snoozeKey = "alertsSnoozedUntil"

    var smartAlertsEnabled: Bool {
        get { defaults.object(forKey: "smartAlertsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "smartAlertsEnabled") }
    }

    var islandEnabled: Bool {
        get { defaults.object(forKey: "islandEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "islandEnabled")
            island.enabled = newValue
            if !newValue { island.hide() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        island.enabled = islandEnabled
        island.model.onPrimary = { [weak self] event in self?.handle(event) }
        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.configure()

        model.onCleanupFinished = { [weak self] freed, failed in
            guard let self else { return }
            self.island.show(.celebrate(freed: freed, freeNow: self.model.freeBytes), autoHide: 4.5)
            if !NSApp.isActive { self.notifications.cleanupDone(freed: freed, failed: failed) }
        }
        observeCleaning()

        knownVolumes = Set(model.volumes.map(\.id))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            Task { @MainActor in self?.volumeMounted(path: path) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task {
            baseline = await Task.detached { Self.measureHotspots() }.value
            await tick()
        }
    }

    // MARK: Progres pembersihan → pulau

    private func observeCleaning() {
        withObservationTracking {
            _ = model.cleanState
            _ = model.isCleaning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.isCleaning, let state = self.model.cleanState {
                    self.island.show(.cleaning(state), autoHide: nil)
                }
                self.observeCleaning()
            }
        }
    }

    // MARK: Pengawas

    func tick() async {
        model.refreshFreeSpace()
        let free = model.freeBytes
        let now = Date()
        samples.append((now, free))
        samples.removeAll { now.timeIntervalSince($0.date) > 2 * 3600 }
        guard smartAlertsEnabled, !isSnoozed(now) else { return }

        // Ruang menipis: paling sering sekali per 6 jam, dengan angka rekomendasi yang segar.
        let threshold = Int64(model.settings.lowSpaceWarningGB) * GB
        if free < threshold, elapsed(since: Self.lowAlertKey, now: now) > 6 * 3600 {
            defaults.set(now, forKey: Self.lowAlertKey)
            if (model.report.map { now.timeIntervalSince($0.startedAt) > 6 * 3600 } ?? true), !model.isScanning {
                await model.scan()
            }
            let recommended = model.report?.recommendedBytes ?? 0
            island.show(.lowSpace(free: model.freeBytes, recommended: recommended), autoHide: 12)
            notifications.lowSpace(free: model.freeBytes, recommended: recommended)
        }

        // Ruang turun drastis (≥ 8 GB dalam ±1 jam): cari folder yang paling membesar.
        if let past = samples.first(where: { now.timeIntervalSince($0.date) <= 70 * 60 }),
           past.free - free >= 8 * GB, elapsed(since: Self.dropAlertKey, now: now) > 2 * 3600 {
            defaults.set(now, forKey: Self.dropAlertKey)
            let before = baseline
            let current = await Task.detached { Self.measureHotspots() }.value
            let culprit = current.map { ($0.key, $0.value - (before[$0.key] ?? $0.value)) }.max { $0.1 < $1.1 }
            baseline = current
            let label = culprit.flatMap { $0.1 > GB ? "\(Self.hotspotNames[$0.0] ?? $0.0) (+\($0.1.bytesText))" : nil }
            let minutes = max(1, Int(now.timeIntervalSince(past.date) / 60))
            island.show(.spaceDrop(dropped: past.free - free, minutes: minutes, culprit: label), autoHide: 12)
            notifications.spaceDrop(dropped: past.free - free, minutes: minutes, culprit: label)
        }
    }

    private func volumeMounted(path: String?) {
        model.refreshVolumes()
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard smartAlertsEnabled, let volume = model.volumes.first(where: { $0.mountPath == path }) ?? model.volumes.first(where: { !knownVolumes.contains($0.id) }) else { return }
            knownVolumes.insert(volume.id)
            let offloadable = model.report?.items.filter(\.offloadable).reduce(0) { $0 + $1.bytes } ?? 0
            island.show(.ssd(name: volume.name, free: volume.free, offloadable: offloadable), autoHide: 10)
            notifications.ssdConnected(name: volume.name, free: volume.free, offloadable: offloadable)
        }
    }

    func peek() {
        island.show(.peek(free: model.freeBytes, total: model.totalBytes, recommended: model.report?.recommendedBytes ?? 0), autoHide: 6)
    }

    private func isSnoozed(_ now: Date) -> Bool {
        (defaults.object(forKey: Self.snoozeKey) as? Date).map { $0 > now } ?? false
    }

    private func elapsed(since key: String, now: Date) -> TimeInterval {
        (defaults.object(forKey: key) as? Date).map { now.timeIntervalSince($0) } ?? .infinity
    }

    nonisolated static let hotspotNames: [String: String] = [
        "Library/Developer/Xcode/DerivedData": "DerivedData Xcode",
        "Library/Developer/CoreSimulator/Devices": "Simulator iOS",
        "Downloads": "Unduhan",
        ".gradle": "Gradle",
        "Library/Caches": "Cache app",
        "Movies": "Movies",
        "Library/Containers/com.docker.docker": "Docker",
    ]

    nonisolated static func measureHotspots() -> [String: Int64] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [String: Int64] = [:]
        for relative in hotspotNames.keys {
            let url = home.appendingPathComponent(relative)
            if PathTools.exists(url.path) { result[relative] = SizeCalculator.measure(url).bytes }
        }
        return result
    }

    // MARK: Aksi dari pulau & notifikasi

    func handle(_ event: IslandEvent) {
        island.hide()
        switch event {
        case .lowSpace(_, let recommended), .peek(_, _, let recommended):
            bringToFront(.overview)
            if recommended > 0, let items = model.report?.recommendedItems {
                model.selectRecommended()
                model.requestCleanup(items)
            } else if model.report == nil || recommended == 0 {
                Task { await model.scan() }
            }
        case .spaceDrop:
            bringToFront(.map)
            Task { await model.buildMap() }
        case .ssd:
            bringToFront(.ssd)
        case .cleaning, .celebrate:
            bringToFront(.cleanup)
        }
    }

    func handle(_ action: NotificationService.Action) {
        switch action {
        case .review:
            handle(IslandEvent.lowSpace(free: model.freeBytes, recommended: model.report?.recommendedBytes ?? 0))
        case .snooze:
            defaults.set(Date().addingTimeInterval(24 * 3600), forKey: Self.snoozeKey)
        case .showDrop:
            handle(IslandEvent.spaceDrop(dropped: 0, minutes: 0, culprit: nil))
        case .openSSD:
            bringToFront(.ssd)
        case .open:
            bringToFront(model.pane)
        }
    }

    func bringToFront(_ pane: Pane) {
        model.pane = pane
        NSApp.activate(ignoringOtherApps: true)
        // Jendela yang masih ada cukup dimunculkan; bila sudah ditutup, buka lewat scene SwiftUI.
        if let window = NSApp.windows.first(where: { $0.title == "Lapangke" && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// Notifikasi sistem dengan tombol aksi. Hanya aktif di app ber-bundle (bukan biner debug).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String { case review, snooze, showDrop, openSSD, open }

    var onAction: ((Action) -> Void)?
    private(set) var status: UNAuthorizationStatus = .notDetermined

    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let review = UNNotificationAction(identifier: Action.review.rawValue, title: "Tinjau & bersihkan", options: [.foreground])
        let snooze = UNNotificationAction(identifier: Action.snooze.rawValue, title: "Ingatkan besok")
        let showDrop = UNNotificationAction(identifier: Action.showDrop.rawValue, title: "Lihat penyebabnya", options: [.foreground])
        let openSSD = UNNotificationAction(identifier: Action.openSSD.rawValue, title: "Pindahkan ke SSD", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "LOW_SPACE", actions: [review, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "SPACE_DROP", actions: [showDrop, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "SSD", actions: [openSSD], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DONE", actions: [], intentIdentifiers: []),
        ])
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard let center else { return }
        status = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return granted
    }

    func lowSpace(free: Int64, recommended: Int64) {
        post(id: "low-space", category: "LOW_SPACE", title: "Sisa \(free.bytesText) di Mac Anda",
             body: recommended > 0 ? "\(recommended.bytesText) cache & sisa build bisa dibersihkan dengan aman sebelum build berikutnya gagal." : "Ruang menipis. Buka Lapangke untuk melihat yang aman dihapus.")
    }

    func spaceDrop(dropped: Int64, minutes: Int, culprit: String?) {
        post(id: "space-drop", category: "SPACE_DROP", title: "Ruang turun \(dropped.bytesText) dalam \(minutes) menit",
             body: culprit.map { "Kemungkinan besar dari \($0)." } ?? "Lihat folder yang membesar di Peta Storage.")
    }

    func ssdConnected(name: String, free: Int64, offloadable: Int64) {
        post(id: "ssd", category: "SSD", title: "SSD \(name) terpasang",
             body: offloadable > 0 ? "\(free.bytesText) kosong. \(offloadable.bytesText) arsip & file besar bisa dipindah ke sini." : "\(free.bytesText) kosong dan siap dipakai.")
    }

    func cleanupDone(freed: Int64, failed: Int) {
        post(id: "done", category: "DONE", title: "+\(freed.bytesText) lega",
             body: failed == 0 ? "Pembersihan selesai." : "Pembersihan selesai; \(failed) item dilewati.")
    }

    private func post(id: String, category: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        content.threadIdentifier = "lapangke"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            let action: Action = switch identifier {
            case Action.review.rawValue: .review
            case Action.snooze.rawValue: .snooze
            case Action.showDrop.rawValue: .showDrop
            case Action.openSSD.rawValue: .openSSD
            default: category == "LOW_SPACE" ? .review : category == "SPACE_DROP" ? .showDrop : category == "SSD" ? .openSSD : .open
            }
            self.onAction?(action)
        }
    }
}
