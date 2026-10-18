import Foundation

public struct CleanupOutcome: Sendable, Identifiable, Hashable {
    public var id: String { item.id }
    public var item: CleanupItem
    public var success: Bool
    public var freedBytes: Int64
    public var message: String
}

/// Menjalankan aksi pembersihan satu per satu. Setiap item divalidasi ulang oleh `SafetyGuard`
/// tepat sebelum dieksekusi, dan setiap hasil dicatat ke log aktivitas.
public struct Cleaner: Sendable {
    public var guardrail: SafetyGuard
    public var log: ActivityLog
    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, log: ActivityLog = ActivityLog()) {
        self.home = home
        guardrail = SafetyGuard(home: home)
        self.log = log
    }

    /// Peringatan yang perlu ditampilkan sebelum menjalankan item ini.
    public static func preflightWarnings(for items: [CleanupItem]) -> [String] {
        var warnings: [String] = []
        let touchesXcode = items.contains { $0.category == .xcode || $0.category == .simulators }
        if touchesXcode, Toolchain.isAppRunning(bundleName: "Xcode") {
            warnings.append("Xcode sedang terbuka. Sebaiknya tutup Xcode dulu agar DerivedData/simulator tidak dipakai saat dihapus.")
        }
        if items.contains(where: { $0.path.contains("/.gradle/") }),
           Toolchain.isRunning("GradleDaemon") {
            warnings.append("Gradle daemon sedang berjalan dan akan dihentikan sebelum cache Gradle dihapus.")
        }
        let trashed = items.filter { $0.action == .trash }.reduce(0) { $0 + $1.bytes }
        if trashed > 0 {
            warnings.append("\(trashed.bytesText) dipindah ke Tong Sampah: ruangnya baru bebas setelah Tong Sampah dikosongkan.")
        }
        return warnings
    }

    /// Menjalankan item satu per satu. `progress` dipanggil saat item berganti dan, untuk penghapusan
    /// folder, ±10× per detik selama item berjalan. `stop` diperiksa sebelum tiap item dimulai.
    public func run(
        _ items: [CleanupItem],
        stop: StopFlag = StopFlag(),
        progress: @escaping @Sendable (CleanupProgress) -> Void = { _ in }
    ) async -> [CleanupOutcome] {
        if items.contains(where: { $0.path.contains("/.gradle/") }) {
            Shell.run("/usr/bin/pkill", ["-f", "GradleDaemon"], timeout: 10)
        }
        let total = items.reduce(0) { $0 + $1.bytes }
        var processedBefore: Int64 = 0
        var outcomes: [CleanupOutcome] = []
        for (index, item) in items.enumerated() {
            if stop.isSet { break }
            let base = processedBefore
            let report: @Sendable (CleanupProgress.Phase, Int64) -> Void = { phase, done in
                progress(CleanupProgress(
                    itemIndex: index, itemCount: items.count, title: item.title, phase: phase,
                    itemDone: min(done, item.bytes), itemTotal: item.bytes,
                    processed: base + min(done, item.bytes), total: total
                ))
            }
            let outcome = perform(item, report: report)
            processedBefore += item.bytes
            report(.finishing, item.bytes)
            outcomes.append(outcome)
            log.append(ActivityEntry(
                kind: item.action.verb, title: item.title, path: item.path, bytes: outcome.freedBytes,
                success: outcome.success, message: outcome.message
            ))
        }
        return outcomes
    }

    func perform(_ item: CleanupItem, report: (CleanupProgress.Phase, Int64) -> Void = { _, _ in }) -> CleanupOutcome {
        do {
            try guardrail.validate(item)
        } catch {
            return CleanupOutcome(item: item, success: false, freedBytes: 0, message: error.localizedDescription)
        }
        let fm = FileManager.default
        do {
            switch item.action {
            case .delete:
                report(.deleting, 0)
                var freedMain: Int64 = 0
                try FastDelete.remove(item.path) { bytes in
                    freedMain = bytes
                    report(.deleting, bytes)
                }
                let failed = processRelated(item) { path in
                    try FastDelete.remove(path) { report(.deleting, freedMain + $0) }
                }
                return CleanupOutcome(item: item, success: failed.isEmpty, freedBytes: failed.isEmpty ? item.bytes : 0,
                                      message: failed.isEmpty ? "Dihapus" : "Sebagian dilewati: \(failed.joined(separator: ", "))")
            case .trash:
                report(.trashing, 0)
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                let failed = processRelated(item) { try fm.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }
                return CleanupOutcome(item: item, success: failed.isEmpty, freedBytes: 0,
                                      message: failed.isEmpty ? "Dipindah ke Tong Sampah" : "Sebagian dilewati: \(failed.joined(separator: ", "))")
            case .emptyTrash:
                var failures = 0
                var freed: Int64 = 0
                report(.emptyingTrash, 0)
                for child in PathTools.children(of: URL(fileURLWithPath: item.path)) {
                    do {
                        try guardrail.validate(path: child.path, allowRepository: true)
                        let before = freed
                        try FastDelete.remove(child.path) { bytes in
                            freed = before + bytes
                            report(.emptyingTrash, freed)
                        }
                    } catch {
                        failures += 1
                    }
                }
                let message = failures == 0 ? "Tong Sampah dikosongkan" : "\(failures) item tidak bisa dihapus (butuh Full Disk Access?)"
                return CleanupOutcome(item: item, success: failures == 0, freedBytes: failures == 0 ? item.bytes : freed, message: message)
            case let .simulatorErase(udid):
                report(.resetting, 0)
                _ = Toolchain.simctl(["shutdown", udid], timeout: 60)
                return simctl(["erase", udid], item: item, success: "Simulator di-reset")
            case let .simulatorDelete(udid):
                report(.resetting, 0)
                return simctl(["delete", udid], item: item, success: "Simulator dihapus")
            case let .simulatorRuntimeDelete(identifier):
                report(.resetting, 0)
                return simctl(["runtime", "delete", identifier], item: item, success: "Runtime dihapus", timeout: 600)
            case .manual:
                return CleanupOutcome(item: item, success: false, freedBytes: 0, message: "Butuh langkah manual")
            }
        } catch {
            return CleanupOutcome(item: item, success: false, freedBytes: 0, message: Self.describe(error, path: item.path))
        }
    }

    /// Path terkait (sisa data app) divalidasi satu per satu; yang gagal dilaporkan, bukan menggagalkan semuanya.
    public func processRelated(_ item: CleanupItem, _ action: (String) throws -> Void) -> [String] {
        var failed: [String] = []
        for path in item.relatedPaths ?? [] where PathTools.exists(path) {
            do {
                try guardrail.validate(path: path)
                try action(path)
            } catch {
                failed.append((path as NSString).lastPathComponent)
            }
        }
        return failed
    }

    func simctl(_ arguments: [String], item: CleanupItem, success: String, timeout: TimeInterval = 180) -> CleanupOutcome {
        guard let result = Toolchain.simctl(arguments, timeout: timeout) else {
            return CleanupOutcome(item: item, success: false, freedBytes: 0, message: "Xcode tidak ditemukan")
        }
        if result.ok { return CleanupOutcome(item: item, success: true, freedBytes: item.bytes, message: success) }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanupOutcome(item: item, success: false, freedBytes: 0, message: reason.isEmpty ? "simctl gagal" : reason)
    }

    static func describe(_ error: Error, path: String) -> String {
        if let posix = error as? POSIXError, posix.code == .EPERM || posix.code == .EACCES {
            return "Sebagian file tidak boleh dihapus (izin). Aktifkan Full Disk Access untuk Lapangke, atau tutup app yang memakainya."
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
            return path.hasSuffix(".app")
                ? "Butuh izin admin. Hapus lewat Finder (seret ke Tong Sampah) atau Launchpad."
                : "Tidak ada izin. Aktifkan Full Disk Access untuk Lapangke."
        }
        return nsError.localizedDescription
    }
}
