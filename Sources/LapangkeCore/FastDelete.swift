import Darwin
import Foundation

/// Penghapusan rekursif dengan `fts` (post-order) yang melaporkan byte yang sudah dibebaskan,
/// sehingga folder besar (simulator, node_modules) terlihat bergerak, bukan diam lalu tiba-tiba selesai.
/// Tidak mengikuti symlink (`FTS_PHYSICAL`) dan tidak menyeberang ke volume lain (`FTS_XDEV`).
public enum FastDelete {
    public static func remove(_ path: String, progress: (Int64) -> Void = { _ in }) throws {
        guard let duplicated = strdup(path) else { throw POSIXError(.ENOMEM) }
        defer { free(duplicated) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [duplicated, nil]
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(fts) }

        var freed: Int64 = 0
        var firstError: Int32 = 0
        var lastReport = DispatchTime.now().uptimeNanoseconds
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                continue
            case FTS_DP:
                if rmdir(entry.pointee.fts_accpath) != 0, firstError == 0 { firstError = errno }
            case FTS_DNR, FTS_ERR, FTS_NS:
                if firstError == 0 { firstError = entry.pointee.fts_errno }
            default:
                let blocks = entry.pointee.fts_statp.map { Int64($0.pointee.st_blocks) } ?? 0
                if unlink(entry.pointee.fts_accpath) == 0 {
                    freed += blocks * 512
                } else if firstError == 0 {
                    firstError = errno
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 100_000_000 {
                progress(freed)
                lastReport = now
            }
        }
        progress(freed)
        if firstError != 0 { throw POSIXError(POSIXErrorCode(rawValue: firstError) ?? .EIO) }
    }
}

/// Keadaan pembersihan yang dikirim ke UI selama berjalan.
public struct CleanupProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case deleting, trashing, emptyingTrash, resetting, finishing

        public var label: String {
            switch self {
            case .deleting: "Menghapus"
            case .trashing: "Memindahkan ke Tong Sampah"
            case .emptyingTrash: "Mengosongkan Tong Sampah"
            case .resetting: "Mereset simulator"
            case .finishing: "Merapikan"
            }
        }

        /// Fase tanpa ukuran progres yang bisa diukur (ditampilkan sebagai indeterminate).
        public var isIndeterminate: Bool { self == .resetting || self == .trashing }
    }

    public var itemIndex: Int
    public var itemCount: Int
    public var title: String
    public var phase: Phase
    public var itemDone: Int64
    public var itemTotal: Int64
    /// Byte yang sudah selesai diproses dari semua item (selesai + item berjalan).
    public var processed: Int64
    public var total: Int64

    public init(itemIndex: Int, itemCount: Int, title: String, phase: Phase, itemDone: Int64, itemTotal: Int64, processed: Int64, total: Int64) {
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.title = title
        self.phase = phase
        self.itemDone = itemDone
        self.itemTotal = itemTotal
        self.processed = processed
        self.total = total
    }

    public var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
    public var itemFraction: Double { itemTotal > 0 ? min(1, Double(itemDone) / Double(itemTotal)) : 0 }
}

/// Bendera "berhenti setelah item ini", aman dibaca dari task latar.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}
