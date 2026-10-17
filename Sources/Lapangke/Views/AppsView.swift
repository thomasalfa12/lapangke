import AppKit
import LapangkeCore
import SwiftUI

enum AppFilter: String, CaseIterable, Identifiable {
    case suggested = "Saran"
    case rarelyUsed = "Jarang dipakai"
    case largest = "Terbesar"
    case all = "Semua"

    var id: String { rawValue }

    func includes(_ app: InstalledApp) -> Bool {
        switch self {
        case .suggested: app.suggested
        case .rarelyUsed: app.isRemovable && (Formatters.days(since: app.lastActivity).map { $0 > 90 } ?? true)
        case .largest: app.isRemovable
        case .all: app.role != .system || app.bytes > 0
        }
    }
}

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: AppFilter = .suggested
    @State private var detail: InstalledApp?

    var body: some View {
        let apps = model.apps.filter(filter.includes)
        let suggested = model.apps.filter(\.suggested)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tampilkan", selection: $filter) {
                    ForEach(AppFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                if !suggested.isEmpty {
                    Text("\(suggested.count) app disarankan · \(suggested.reduce(0) { $0 + $1.totalBytes }.bytesText)")
                        .foregroundStyle(.secondary)
                }
                Button { Task { await model.loadApps() } } label: { Label("Muat ulang", systemImage: "arrow.clockwise") }
                    .disabled(model.appsLoading)
            }
            .padding()
            Divider()
            if model.appsLoading && model.apps.isEmpty {
                ProgressView("Mengukur aplikasi & datanya…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                ContentUnavailableView(filter == .suggested ? "Tidak ada saran" : "Tidak ada app",
                                       systemImage: "checkmark.circle",
                                       description: Text(filter == .suggested ? "Semua app masih dipakai. Lihat 'Terbesar' untuk app yang paling makan tempat." : ""))
            } else {
                Table(apps) {
                    TableColumn("Aplikasi") { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(app.name).fontWeight(.medium)
                                    if app.suggested { SparkShape().fill(Brand.accentBright).frame(width: 11, height: 11) }
                                }
                                Text(app.advice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    TableColumn("Peran") { app in
                        Text(app.role.label).foregroundStyle(app.role == .nonWork ? .orange : .secondary).help(app.reason)
                    }
                    .width(80)
                    TableColumn("Total") { app in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(app.totalBytes.bytesText).monospacedDigit().fontWeight(.medium)
                            if app.dataBytes > 0 {
                                Text("data \(app.dataBytes.bytesText)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(100)
                    TableColumn("Terakhir dipakai") { app in
                        Text(app.lastActivity?.relativeText ?? "Tidak tercatat").foregroundStyle(.secondary)
                    }
                    .width(140)
                    TableColumn("") { app in
                        if app.isRemovable {
                            Button("Hapus…") { detail = app }.buttonStyle(.link)
                        }
                    }
                    .width(60)
                }
            }
        }
        .navigationTitle("Aplikasi")
        .task { if model.apps.isEmpty { await model.loadApps() } }
        .sheet(item: $detail) { app in
            AppUninstallSheet(app: app).environment(model)
        }
    }
}

/// Rincian satu app: bundle + setiap lokasi datanya, bisa dipilih satu per satu.
struct AppUninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    @State private var includeApp = true
    @State private var selectedData: Set<String> = []

    var running: NSRunningApplication? {
        app.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    var selectedBytes: Int64 {
        (includeApp ? app.bytes : 0) + app.data.filter { selectedData.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.weight(.semibold))
                    Text([app.version.map { "Versi \($0)" }, app.role.label, app.fromAppStore ? "App Store" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(app.totalBytes.bytesText).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Callout(symbol: app.suggested ? "star.fill" : "info.circle.fill", tint: app.suggested ? .orange : .blue, text: app.advice)
            if let running {
                HStack {
                    Label("\(app.name) sedang terbuka. Tutup dulu sebelum menghapus.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Tutup app") { running.terminate() }
                }
                .font(.callout)
            }
            List {
                Toggle(isOn: $includeApp) {
                    row(title: "Aplikasi", detail: app.path.abbreviatingHome, bytes: app.bytes)
                }
                ForEach(app.data) { location in
                    Toggle(isOn: Binding(
                        get: { selectedData.contains(location.path) },
                        set: { on in if on { selectedData.insert(location.path) } else { selectedData.remove(location.path) } }
                    )) {
                        row(title: location.kind, detail: location.path.abbreviatingHome, bytes: location.bytes)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(minHeight: 200)
            Text("Semua yang dipilih masuk Tong Sampah, jadi masih bisa dikembalikan. Ruang baru bebas setelah Tong Sampah dikosongkan.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Batal") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !app.data.isEmpty {
                    Button("Hapus datanya saja") {
                        includeApp = false
                        selectedData = Set(app.data.map(\.path))
                        submit()
                    }
                }
                Button("Pindahkan ke Tong Sampah · \(selectedBytes.bytesText)") { submit() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedBytes == 0 && !includeApp)
            }
        }
        .padding(20)
        .frame(width: 620, height: 540)
        .onAppear { selectedData = Set(app.data.map(\.path)) }
    }

    func row(title: String, detail: String, bytes: Int64) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(bytes.bytesText).monospacedDigit()
        }
    }

    func submit() {
        let paths = (includeApp ? [app.path] : []) + app.data.map(\.path).filter(selectedData.contains)
        guard let first = paths.first else { return }
        let item = CleanupItem(
            title: includeApp ? app.name : "Data \(app.name)", detail: app.advice, path: first, bytes: selectedBytes,
            category: .apps, safety: .review, action: .trash, relatedPaths: Array(paths.dropFirst())
        )
        dismiss()
        model.requestCleanup([item])
    }
}
