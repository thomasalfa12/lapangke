import Foundation
import LapangkeCore

/// Mode terminal: `Lapangke --report` (hanya membaca, tidak pernah menghapus apa pun).
enum CLI {
    static let flags: Set<String> = ["--report", "--json", "--volumes", "--map", "--help", "--all"]

    static func run(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--help") {
            print("""
            Lapangke — bikin storage Mac lapang lagi (bonus pintar untuk developer iOS & Android)

              Lapangke                 buka app
              Lapangke --report        pindai & tampilkan rekomendasi (read-only)
              Lapangke --report --all  tampilkan semua item
              Lapangke --json          laporan dalam JSON
              Lapangke --volumes       info SSD eksternal & saran
              Lapangke --map           peta penyimpanan per folder
            """)
            return 0
        }
        if arguments.contains("--volumes") {
            printVolumes()
            return 0
        }
        if arguments.contains("--map") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let map = await StorageMapper.map(roots: StorageMapper.defaultRoots(home: home)) { status($0) }
            StorageMapper.save(map)
            printMap(map)
            return 0
        }

        let json = arguments.contains("--json")
        let report = await Scanner(settings: LapangkeSettings.load()).run { message in
            if !json { status(message) }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            printReport(report, all: arguments.contains("--all"))
        }
        return 0
    }

    static func status(_ message: String) {
        FileHandle.standardError.write(Data("· \(message)\n".utf8))
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func lpad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func printReport(_ report: ScanReport, all: Bool) {
        let disk = report.disk
        print("\nLAPANGKE · \(Date().formatted(date: .abbreviated, time: .shortened)) · pindai \(String(format: "%.0f", report.duration)) dtk")
        print("Disk internal: \(disk.available.bytesText) kosong dari \(disk.total.bytesText) (+\(disk.purgeable.bytesText) purgeable)")
        if let smart = disk.smart {
            let written = smart.dataWrittenBytes.map { String(format: "%.0f TB", Double($0) / 1e12) } ?? "?"
            print("Kesehatan SSD: aus \(smart.percentageUsed.map { "\($0)%" } ?? "?") · total ditulis \(written) · swap \(disk.swapUsed.bytesText)")
        }
        print("Full Disk Access: \(disk.hasFullDiskAccess ? "aktif" : "BELUM — sebagian folder tidak terbaca")\n")

        for safety in Safety.allCases {
            print("  \(pad(safety.label, 22)) \(lpad(report.total(safety).bytesText, 10))")
        }
        print("  \(pad("→ Rekomendasi Lapangke", 22)) \(lpad(report.recommendedBytes.bytesText, 10))\n")

        for category in ItemCategory.allCases {
            let items = report.items.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let deletable = items.filter(\.safety.isDeletable).reduce(0) { $0 + $1.bytes }
            print("■ \(category.title) — \(deletable.bytesText) bisa dibersihkan")
            for item in (all ? items : Array(items.prefix(12))) {
                let mark = item.recommended ? "✓" : " "
                print("  \(mark) \(lpad(item.bytes.bytesText, 9))  \(pad(item.safety.label, 19)) \(item.title)")
                if all { print("      \(item.displayPath)") }
                for warning in item.warnings { print("      ⚠︎ \(warning)") }
            }
            if !all, items.count > 12 { print("    … \(items.count - 12) item lain (pakai --all)") }
            print("")
        }
        for note in report.notes { print("ℹ︎ \(note)") }
        print("\n✓ = dipilih otomatis oleh 'Rekomendasi'. Mode terminal tidak menghapus apa pun; pakai app Lapangke untuk membersihkan.")
    }

    static func printVolumes() {
        let volumes = VolumeService.externalVolumes()
        if volumes.isEmpty {
            print("Tidak ada SSD/disk eksternal yang terpasang.")
            return
        }
        for volume in volumes {
            print("\n■ \(volume.name)  \(volume.mountPath)")
            print("  \(volume.formatName) · \(volume.busProtocol ?? "?") · \(volume.free.bytesText) kosong dari \(volume.total.bytesText)")
            for advice in volume.advice {
                let icon = switch advice.level { case .good: "✓"; case .info: "•"; case .warning: "⚠︎" }
                print("  \(icon) \(advice.title): \(advice.detail)")
                if let command = advice.command { print("      $ \(command)") }
            }
        }
    }

    static func printMap(_ map: StorageMap) {
        for root in map.roots {
            print("\n■ \(root.name) — \(root.bytes.bytesText)\(root.unreadable > 0 ? " (\(root.unreadable) folder tak terbaca)" : "")")
            for child in (root.children ?? []).prefix(15) {
                print("  \(lpad(child.bytes.bytesText, 9))  \(child.name)\(child.unreadable > 0 ? "  [\(child.unreadable) tak terbaca]" : "")")
                for grandchild in (child.children ?? []).prefix(4) {
                    print("      \(lpad(grandchild.bytes.bytesText, 9))  \(grandchild.name)")
                }
            }
        }
    }
}
