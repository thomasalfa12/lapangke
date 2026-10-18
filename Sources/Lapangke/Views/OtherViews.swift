import AppKit
import LapangkeCore
import ServiceManagement
import SwiftUI

// Halaman Peta Storage ada di StorageMapView.swift.

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
                Button("Atur izin & notifikasi…") { model.showOnboarding = true }
                Toggle("Pulau Lapangke (kabar penting di tengah atas layar)", isOn: Binding(
                    get: { AppServices.shared.islandEnabled }, set: { AppServices.shared.islandEnabled = $0 }))
                Toggle("Notifikasi pintar (ruang menipis, turun drastis, SSD dicolok)", isOn: Binding(
                    get: { AppServices.shared.smartAlertsEnabled }, set: { AppServices.shared.smartAlertsEnabled = $0 }))
                Button("Intip Pulau Lapangke") { AppServices.shared.peek() }
                Button("Buka pengaturan Full Disk Access") { model.openFullDiskAccessSettings() }
                Button("Tampilkan log aktivitas") { model.reveal(AppPaths.activity.path) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
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
