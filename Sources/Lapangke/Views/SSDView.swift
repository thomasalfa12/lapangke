import LapangkeCore
import SwiftUI

struct SSDView: View {
    @Environment(AppModel.self) private var model
    @State private var chosenCaches: Set<DevCache> = [.xcodeDerivedData, .gradleHome]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.volumes.isEmpty {
                    emptyState
                } else {
                    ForEach(model.volumes) { volume in VolumeCard(volume: volume) }
                    relocation
                }
                offloads
                guide
            }
            .padding(20)
        }
        .navigationTitle("SSD Eksternal")
        .toolbar {
            ToolbarItem {
                Button { model.refreshVolumes() } label: { Label("Muat ulang", systemImage: "arrow.clockwise") }
            }
        }
    }

    var emptyState: some View {
        Card {
            Label("Belum ada SSD eksternal yang terpasang", systemImage: "externaldrive.badge.questionmark").font(.headline)
            Text("Colokkan SSD; Lapangke otomatis mendeteksinya, memeriksa format & kecepatannya, lalu bisa memindahkan arsip dan cache dev ke sana.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    var relocation: some View {
        Card {
            Text("Cache dev langsung ke SSD").font(.headline)
            Text("Build berikutnya menulis cache ke SSD kerja, bukan ke disk internal. Jika SSD dicabut, Gradle & npm otomatis kembali ke lokasi bawaan; Xcode akan meminta SSD dipasang (atau kembalikan di sini).")
                .font(.callout).foregroundStyle(.secondary)
            if let volume = model.workVolume {
                ForEach(DevCache.allCases) { cache in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(
                            get: { chosenCaches.contains(cache) },
                            set: { on in if on { chosenCaches.insert(cache) } else { chosenCaches.remove(cache) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cache.title)
                                Text(cache.detail).font(.caption).foregroundStyle(.secondary)
                                if let target = model.relocationTargets[cache] {
                                    Label("Aktif: \(target)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Button("Arahkan ke \(volume.name)") { model.applyRelocation(chosenCaches) }
                        .buttonStyle(.borderedProminent)
                        .disabled(chosenCaches.isEmpty || !volume.supportsDevWork)
                    Button("Kembalikan ke Mac") { model.revertRelocation(chosenCaches) }
                        .disabled(model.relocationTargets.isEmpty)
                    if !volume.supportsDevWork {
                        Text("Butuh SSD berformat APFS.").font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                Callout(symbol: "hand.tap", tint: .blue, text: "Pilih salah satu SSD di atas sebagai 'SSD kerja' dulu.")
            }
        }
    }

    var offloads: some View {
        Card {
            Text("Data yang dipindah ke SSD").font(.headline)
            if model.offloads.isEmpty {
                Text("Belum ada. Di Pembersihan, klik kanan item bertanda 'Periksa dulu' (arsip, output, riwayat) › Pindahkan ke SSD.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.offloads) { record in
                let status = model.offloadStatus(record)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.body.weight(.medium))
                        Text("\(record.originalPath.abbreviatingHome) → \(record.volumeName)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("\(record.bytes.bytesText) · \(record.date.relativeText)\(record.symlinked ? " · ditautkan" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(status.label, systemImage: status == .available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(status == .available ? .green : .orange)
                    Menu("Aksi") {
                        Button("Tampilkan di Finder") { model.reveal(record.destinationPath) }
                            .disabled(status != .available)
                        Button("Kembalikan ke Mac") { Task { await model.restore(record) } }
                            .disabled(status != .available || model.busyMessage != nil)
                        Divider()
                        Button("Lupakan catatan (file tidak disentuh)") { model.forget(record) }
                    }
                    .fixedSize()
                }
                Divider()
            }
        }
    }

    var guide: some View {
        Card {
            Text("Panduan: Mac 256 GB + SSD eksternal").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                guideRow("1", "Pakai enclosure NVMe Thunderbolt/USB4 (40 Gbps) + SSD NVMe TLC 1–2 TB. Hindari flashdisk & SSD SATA lama untuk build.")
                guideRow("2", "Format APFS (Encrypted bila berisi kode & keystore). Jangan exFAT untuk data dev.")
                guideRow("3", "Biarkan di disk internal: macOS, app (Xcode, Android Studio), runtime simulator, keychain, dan proyek yang sedang aktif dikerjakan.")
                guideRow("4", "Arahkan ke SSD: DerivedData, Gradle home, arsip .xcarchive, folder output/screenshot, riwayat sesi AI, media, dan proyek lama.")
                guideRow("5", "Sisakan minimal 30–40 GB kosong di disk internal untuk swap & update macOS.")
                guideRow("6", "Selalu Eject sebelum mencabut SSD agar cache tidak rusak.")
            }
        }
    }

    func guideRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.caption.weight(.bold)).frame(width: 18, height: 18).background(.tint.opacity(0.15), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo

    var isWork: Bool { model.settings.workVolumeUUID != nil && model.settings.workVolumeUUID == volume.uuid }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(volume.name).font(.headline)
                        if isWork { Text("SSD kerja").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.15), in: Capsule()) }
                    }
                    Text("\(volume.formatName) · \(volume.busProtocol ?? "koneksi tidak diketahui") · \(volume.solidState == false ? "HDD" : "SSD")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(volume.free.bytesText) kosong dari \(volume.total.bytesText)").font(.callout).monospacedDigit()
            }
            CapacityBar(used: volume.total - volume.free, total: volume.total, warning: volume.total > 0 && Double(volume.free) / Double(volume.total) < 0.1)
            ForEach(volume.advice) { advice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: advice.level == .good ? "checkmark.circle.fill" : advice.level == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(advice.level == .good ? .green : advice.level == .warning ? .orange : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(advice.title).font(.callout.weight(.medium))
                        Text(advice.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let command = advice.command {
                            HStack {
                                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                                Button("Salin") { model.copyPath(command) }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
            if let speed = model.speedResults[volume.id] {
                Label(String(format: "Tulis %.0f MB/s · Baca %.0f MB/s", speed.writeMBps, speed.readMBps), systemImage: "speedometer")
                    .font(.callout.weight(.medium))
            }
            HStack {
                Button(isWork ? "SSD kerja ✓" : "Jadikan SSD kerja") { model.settings.workVolumeUUID = volume.uuid }
                    .disabled(isWork || volume.uuid == nil)
                Button(model.speedTesting == volume.id ? "Menguji…" : "Uji kecepatan (1 GB)") {
                    Task { await model.speedTest(volume) }
                }
                .disabled(model.speedTesting != nil)
                Spacer()
                Button("Tampilkan") { model.reveal(volume.mountPath) }
                Button("Keluarkan") { model.eject(volume) }
            }
        }
    }
}
