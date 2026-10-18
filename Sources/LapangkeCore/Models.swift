import Foundation

// MARK: - Keamanan

/// Seberapa aman sebuah data dihapus. Urutannya dari paling aman.
public enum Safety: Int, Codable, Sendable, CaseIterable, Comparable {
    /// Dibuat ulang otomatis tanpa kehilangan apa pun (DerivedData, folder build lama).
    case regenerable = 0
    /// Aman, tetapi perlu unduh/build ulang yang makan waktu & kuota (cache Gradle, simulator aktif).
    case costly = 1
    /// Mungkin bernilai (arsip rilis, riwayat chat, media). Selalu lewat Tong Sampah.
    case review = 2
    /// Penting atau sedang dipakai. Tidak bisa dihapus dari Lapangke.
    case keep = 3
    /// Dikelola macOS/app lain. Lapangke hanya menunjukkan cara resminya.
    case managed = 4

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .regenerable: "Aman"
        case .costly: "Aman · unduh ulang"
        case .review: "Periksa dulu"
        case .keep: "Penting"
        case .managed: "Dikelola sistem"
        }
    }

    public var summary: String {
        switch self {
        case .regenerable: "Dibuat ulang otomatis oleh tool-nya. Tidak ada data yang hilang."
        case .costly: "Aman dihapus, tapi akan diunduh atau di-build ulang (butuh waktu & internet)."
        case .review: "Bisa berisi data bernilai. Masuk Tong Sampah dulu, atau pindahkan ke SSD."
        case .keep: "Sedang dipakai atau penting. Lapangke tidak akan menghapusnya."
        case .managed: "Dikelola macOS atau app lain. Ikuti cara resmi yang dijelaskan."
        }
    }

    public var isDeletable: Bool { self <= .review }
}

// MARK: - Kategori

public enum ItemCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case xcode, simulators, android, projects, toolchains, aiTools, appCaches, apps, personal, system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xcode: "Xcode"
        case .simulators: "Simulator iOS"
        case .android: "Android & Gradle"
        case .projects: "Artefak proyek"
        case .toolchains: "Paket & toolchain"
        case .aiTools: "Tool AI & editor"
        case .appCaches: "Cache app & browser"
        case .apps: "Aplikasi jarang dipakai"
        case .personal: "File pribadi"
        case .system: "Sistem macOS"
        }
    }

    public var symbol: String {
        switch self {
        case .xcode: "hammer"
        case .simulators: "ipad.and.iphone"
        case .android: "square.stack.3d.up"
        case .projects: "folder.badge.gearshape"
        case .toolchains: "shippingbox"
        case .aiTools: "sparkles"
        case .appCaches: "globe"
        case .apps: "gamecontroller"
        case .personal: "photo.on.rectangle"
        case .system: "gearshape.2"
        }
    }
}

// MARK: - Aksi

public enum CleanupAction: Codable, Sendable, Hashable {
    /// Hapus permanen. Hanya untuk data yang bisa dibuat ulang.
    case delete
    /// Pindah ke Tong Sampah (bisa dipulihkan, ruang belum bebas sampai dikosongkan).
    case trash
    /// Kosongkan isi ~/.Trash.
    case emptyTrash
    case simulatorErase(udid: String)
    case simulatorDelete(udid: String)
    case simulatorRuntimeDelete(identifier: String)
    /// Tidak bisa otomatis: tampilkan panduan.
    case manual(instructions: String)

    public var verb: String {
        switch self {
        case .delete: "Hapus permanen"
        case .trash: "Pindah ke Tong Sampah"
        case .emptyTrash: "Kosongkan Tong Sampah"
        case .simulatorErase: "Reset simulator"
        case .simulatorDelete: "Hapus simulator"
        case .simulatorRuntimeDelete: "Hapus runtime simulator"
        case .manual: "Panduan"
        }
    }

    public var isAutomatic: Bool {
        if case .manual = self { return false }
        return true
    }

    /// Apakah ruang disk langsung bebas setelah aksi ini.
    public var freesSpaceImmediately: Bool {
        switch self {
        case .trash, .manual: false
        default: true
        }
    }

    public var instructions: String? {
        if case let .manual(text) = self { return text }
        return nil
    }
}

// MARK: - Item

public struct CleanupItem: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public var title: String
    public var detail: String
    public var path: String
    public var bytes: Int64
    public var category: ItemCategory
    public var safety: Safety
    public var action: CleanupAction
    /// Dipilih otomatis oleh tombol "Rekomendasi".
    public var recommended: Bool
    public var lastActivity: Date?
    /// Boleh dipindah ke SSD eksternal (bukan dihapus).
    public var offloadable: Bool
    public var warnings: [String]
    /// Path lain yang ikut diproses bersama `path` (mis. sisa data saat uninstall app).
    public var relatedPaths: [String]?

    public init(
        title: String,
        detail: String,
        path: String,
        bytes: Int64,
        category: ItemCategory,
        safety: Safety,
        action: CleanupAction,
        recommended: Bool = false,
        lastActivity: Date? = nil,
        offloadable: Bool = false,
        warnings: [String] = [],
        relatedPaths: [String]? = nil
    ) {
        self.title = title
        self.detail = detail
        self.path = path
        self.bytes = bytes
        self.category = category
        self.safety = safety
        self.action = action
        // Hanya data yang memang boleh dihapus otomatis yang bisa direkomendasikan.
        self.recommended = recommended && safety <= .costly && action.isAutomatic
        self.lastActivity = lastActivity
        self.offloadable = offloadable
        self.warnings = warnings
        self.relatedPaths = relatedPaths
    }

    public var isSelectable: Bool { safety.isDeletable && action.isAutomatic }
    public var displayPath: String { path.abbreviatingHome }
}

// MARK: - Laporan

public struct ScanReport: Codable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    public var items: [CleanupItem]
    public var disk: DiskSnapshot
    public var notes: [String]

    public init(startedAt: Date, duration: TimeInterval, items: [CleanupItem], disk: DiskSnapshot, notes: [String]) {
        self.startedAt = startedAt
        self.duration = duration
        self.items = items
        self.disk = disk
        self.notes = notes
    }

    public func total(_ safety: Safety) -> Int64 {
        items.filter { $0.safety == safety }.reduce(0) { $0 + $1.bytes }
    }

    public func total(_ category: ItemCategory) -> Int64 {
        items.filter { $0.category == category && $0.safety.isDeletable }.reduce(0) { $0 + $1.bytes }
    }

    public var recommendedItems: [CleanupItem] { items.filter(\.recommended) }
    public var recommendedBytes: Int64 { recommendedItems.reduce(0) { $0 + $1.bytes } }
}

// MARK: - Format

public extension Int64 {
    var bytesText: String { format(style: .file) }
    /// RAM ditulis biner (8 GB, bukan 8,59 GB).
    var memoryText: String { format(style: .memory) }

    private func format(style: ByteCountFormatter.CountStyle) -> String {
        if self == 0 { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: self)
    }
}

public extension String {
    /// `/Users/x/Library` → `~/Library`
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}

public enum Formatters {
    public static let locale = Locale(identifier: "id_ID")

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    public static func monthYear(year: Int, month: Int) -> String {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: c) else { return "\(month)/\(year)" }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date).capitalized(with: locale)
    }

    public static func days(since date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return Int(now.timeIntervalSince(date) / 86_400)
    }
}

public let MB: Int64 = 1_000_000
public let GB: Int64 = 1_000_000_000
