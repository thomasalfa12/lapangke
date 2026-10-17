import AppKit
import LapangkeCore
import ServiceManagement
import SwiftUI

// MARK: - Peta storage

struct StorageMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Peta penyimpanan").font(.headline)
                    if let map = model.storageMap {
                        Text("Dipetakan \(map.createdAt.relativeText) · \(Int(map.duration)) dtk").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Menelusuri home, Applications, Library, aset macOS, dan Homebrew (±1 menit).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isMapping {
                    ProgressView().controlSize(.small)
                    Text(model.mapStatus).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.storageMap == nil ? "Petakan sekarang" : "Petakan ulang") { Task { await model.buildMap() } }
                    .disabled(model.isMapping)
            }
            .padding()
            Divider()
            if let map = model.storageMap {
                let largest = map.roots.first?.bytes ?? 1
                List(map.roots, children: \.children) { node in
                    HStack(spacing: 10) {
                        Text(node.name).lineLimit(1)
                        if node.unreadable > 0 {
                            Image(systemName: "lock.fill").foregroundStyle(.orange)
                                .help("\(node.unreadable) folder tidak terbaca — aktifkan Full Disk Access")
                        }
                        Spacer()
                        GeometryReader { proxy in
                            Capsule().fill(.tint.opacity(0.6))
                                .frame(width: max(2, proxy.size.width * Double(node.bytes) / Double(max(largest, 1))))
                        }
                        .frame(width: 160, height: 6)
                        Text(node.bytes.bytesText).monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                    .contextMenu {
                        Button("Tampilkan di Finder") { model.reveal(node.path) }
                        Button("Salin path") { model.copyPath(node.path) }
                    }
                }
            } else {
                ContentUnavailableView("Belum ada peta", systemImage: "square.grid.3x3.square",
                                       description: Text("Peta menunjukkan folder mana yang paling besar, termasuk yang bukan cache."))
            }
        }
        .navigationTitle("Peta Storage")
    }
}

// Halaman Aplikasi ada di AppsView.swift.

// MARK: - Riwayat

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView("Belum ada aktivitas", systemImage: "clock",
                                       description: Text("Semua penghapusan & pemindahan tercatat di sini."))
            } else {
                List(model.activity) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(entry.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.kind): \(entry.title)").font(.body.weight(.medium))
                            Text(entry.path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if !entry.message.isEmpty { Text(entry.message).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(entry.bytes.bytesText).monospacedDigit()
                            Text(entry.date.relativeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Riwayat")
    }
}

// MARK: - Pengaturan

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Folder proyek") {
                ForEach(model.settings.devRoots, id: \.self) { root in
                    HStack {
                        Text(root).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            model.settings.devRoots.removeAll { $0 == root }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Tambah folder…") { addRoot() }
                Text("Lapangke mencari repo git & artefak build di folder ini. Folder lain tidak pernah dipindai sebagai proyek.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Penilaian") {
                Stepper("Proyek dianggap tidak aktif setelah \(model.settings.inactiveDays) hari",
                        value: $model.settings.inactiveDays, in: 3...180, step: 1)
                Stepper("Peringatan bila ruang kosong < \(model.settings.lowSpaceWarningGB) GB",
                        value: $model.settings.lowSpaceWarningGB, in: 5...100, step: 5)
            }
            Section("Sistem") {
                Toggle("Buka Lapangke saat login (ikon menu bar)", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Button("Buka pengaturan Full Disk Access") { model.openFullDiskAccessSettings() }
                Button("Tampilkan log aktivitas") { model.reveal(AppPaths.activity.path) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Tambahkan"
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            if !model.settings.devRoots.contains(path) { model.settings.devRoots.append(path) }
        }
    }
}
