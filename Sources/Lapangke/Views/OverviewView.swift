import LapangkeCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let report = model.report {
                    if !report.disk.hasFullDiskAccess { fullDiskAccessBanner }
                    recommendation(report)
                    totals(report)
                    HStack(alignment: .top, spacing: 16) {
                        categories(report)
                        health(report.disk)
                    }
                    ForEach(report.notes, id: \.self) { note in
                        Callout(symbol: "info.circle.fill", tint: .blue, text: note)
                    }
                } else if model.isScanning {
                    ProgressView(model.scanStatus).frame(maxWidth: .infinity).padding(40)
                } else {
                    ContentUnavailableView {
                        Label("Belum dipindai", systemImage: "magnifyingglass")
                    } description: {
                        Text("Lapangke membaca folder Xcode, Android, proyek, dan cache untuk menilai mana yang aman dihapus.")
                    } actions: {
                        Button("Pindai sekarang") { Task { await model.scan() } }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Ringkasan")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.scan() }
                } label: {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Pindai ulang", systemImage: "arrow.clockwise")
                    }
                }
                .help("Pindai ulang (⌘R)")
                .disabled(model.isScanning)
            }
        }
    }

    var header: some View {
        Card(fill: Brand.wash) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MACINTOSH HD").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Brand.accent)
                    Text("\(model.freeBytes.bytesText) kosong dari \(model.totalBytes.bytesText)")
                        .font(.system(size: 30, weight: .bold)).tracking(-0.8)
                        .foregroundStyle(model.isLowOnSpace ? Brand.bad : Brand.ink)
                }
                Spacer()
                if model.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let report = model.report {
                    Text("Dipindai \(report.startedAt.relativeText) · \(Int(report.duration)) dtk")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CapacityBar(used: model.totalBytes - model.freeBytes, total: model.totalBytes, warning: model.isLowOnSpace)
        }
    }

    var fullDiskAccessBanner: some View {
        Card(fill: Brand.peach) {
            HStack(alignment: .top, spacing: 14) {
                Sticker(symbol: "lock.shield", background: Brand.ink)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Beri Lapangke akses penuh ke disk").font(.headline).foregroundStyle(Brand.ink)
                    Text("Tanpa Full Disk Access, Tong Sampah, Containers, dan media WhatsApp/Telegram tidak terlihat (bisa puluhan GB). Klik tombol di bawah, lalu seret Lapangke dari Finder ke daftar Full Disk Access dan nyalakan.")
                        .font(.callout).foregroundStyle(Brand.ink2)
                    Button("Buka pengaturan Full Disk Access") { model.openFullDiskAccessSettings() }
                        .buttonStyle(PillButtonStyle(background: Brand.ink))
                }
            }
        }
    }

    func recommendation(_ report: ScanReport) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Sticker(symbol: "sparkles", background: Brand.limeSticker, foreground: Color(hex: 0x304313), size: 54)
            VStack(alignment: .leading, spacing: 6) {
                Text("SIAP DIBERSIHKAN").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Color(hex: 0x7FD0F5))
                Text(report.recommendedBytes.bytesText).font(.system(size: 40, weight: .bold)).tracking(-1.2).foregroundStyle(.white)
                Text("\(report.recommendedItems.count) item yang dibuat ulang otomatis (cache, file sementara, build lama, sisa app). Tidak ada dokumen, foto, kode, atau rilis yang ikut.")
                    .font(.callout).foregroundStyle(Color(hex: 0xC8E6FF)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(spacing: 10) {
                Button("Bersihkan rekomendasi") {
                    model.selectRecommended()
                    model.requestCleanup(report.recommendedItems)
                }
                .buttonStyle(PillButtonStyle(background: .white, foreground: Color(hex: 0x0064AF)))
                .disabled(report.recommendedItems.isEmpty)
                Button("Lihat rinciannya") {
                    model.filter = .recommended
                    model.categoryFilter = nil
                    model.pane = .cleanup
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .underline()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Ornamen di overlay agar tidak ikut menentukan tinggi kartu.
            Brand.stage
                .overlay(alignment: .topTrailing) {
                    FlowerShape().fill(Color(hex: 0x0D4A7C)).frame(width: 220, height: 220).rotationEffect(.degrees(12)).offset(x: 60, y: -70)
                }
                .overlay(alignment: .topTrailing) {
                    SparkShape().fill(Color(hex: 0x2A6AA3)).frame(width: 26, height: 26).offset(x: -240, y: 22)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 40, bottomLeadingRadius: 16, bottomTrailingRadius: 40, topTrailingRadius: 16, style: .continuous))
        }
    }

    func totals(_ report: ScanReport) -> some View {
        HStack(spacing: 12) {
            ForEach(Array([Safety.regenerable, .costly, .review, .managed].enumerated()), id: \.element) { index, safety in
                StatTile(title: safety.label, value: report.total(safety).bytesText, caption: safety.summary, tint: safety.tint,
                         wash: safety.wash, small: index.isMultiple(of: 2) ? 22 : 6)
                    .onTapGesture {
                        model.filter = safety == .review ? .review : (safety == .managed ? .all : .deletable)
                        model.categoryFilter = nil
                        model.pane = .cleanup
                    }
            }
        }
    }

    func categories(_ report: ScanReport) -> some View {
        let rows = ItemCategory.allCases
            .map { ($0, report.total($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let largest = rows.first?.1 ?? 1
        return Card {
            Text("Bisa dibersihkan per kategori").font(.headline).foregroundStyle(Brand.ink)
            ForEach(rows, id: \.0) { category, bytes in
                Button {
                    model.categoryFilter = category
                    model.filter = .deletable
                    model.pane = .cleanup
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol).frame(width: 20).foregroundStyle(Brand.accent)
                        Text(category.title).frame(width: 150, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(LinearGradient(colors: [Brand.cyan, Brand.accentBright], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, proxy.size.width * Double(bytes) / Double(max(largest, 1))))
                        }
                        .frame(height: 8)
                        Text(bytes.bytesText).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    func health(_ disk: DiskSnapshot) -> some View {
        Card {
            Text("Kesehatan Mac").font(.headline).foregroundStyle(Brand.ink)
            if let smart = disk.smart {
                if let percent = smart.percentageUsed { row("Keausan SSD internal", "\(percent)%") }
                if let written = smart.dataWrittenBytes {
                    row("Total data ditulis", String(format: "%.0f TB", Double(written) / 1e12))
                }
            }
            row("Swap terpakai", disk.swapUsed.bytesText)
            row("RAM", disk.physicalMemory.memoryText)
            row("Purgeable (dibebaskan macOS)", disk.purgeable.bytesText)
            if disk.swapUsed > disk.physicalMemory / 2 {
                Callout(symbol: "memorychip", tint: Brand.warn,
                        text: "Swap besar: macOS memakai SSD sebagai RAM saat Xcode, Gradle, simulator, dan browser jalan bersamaan. Ini memakan ruang (volume VM) dan mempercepat keausan SSD. Di Mac berikutnya, RAM lebih penting daripada storage internal.")
            }
        }
        .frame(maxWidth: 360)
    }

    func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
    }
}
