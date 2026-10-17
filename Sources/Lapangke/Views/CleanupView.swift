import LapangkeCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.visibleItems
        let groups = Dictionary(grouping: items, by: \.category)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Tampilkan", selection: $model.filter) {
                    ForEach(ItemFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Picker("Kategori", selection: $model.categoryFilter) {
                    Text("Semua kategori").tag(ItemCategory?.none)
                    ForEach(ItemCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
                }
                .frame(maxWidth: 220)
                Spacer()
                Button("Pilih rekomendasi") { model.selectRecommended() }
                Button("Kosongkan pilihan") { model.selection.removeAll() }
                    .disabled(model.selection.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()

            if model.report == nil {
                ContentUnavailableView("Belum dipindai", systemImage: "magnifyingglass", description: Text("Jalankan pindai dari Ringkasan."))
            } else if items.isEmpty {
                ContentUnavailableView("Tidak ada item", systemImage: "checkmark.circle", description: Text("Tidak ada yang cocok dengan filter ini."))
            } else {
                List {
                    ForEach(ItemCategory.allCases.filter { groups[$0] != nil }) { category in
                        let entries = groups[category] ?? []
                        Section {
                            ForEach(entries) { item in ItemRow(item: item) }
                        } header: {
                            HStack {
                                Label(category.title, systemImage: category.symbol)
                                Spacer()
                                Text(entries.filter(\.isSelectable).reduce(0) { $0 + $1.bytes }.bytesText).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.search, prompt: "Cari nama atau path")
        .navigationTitle("Pembersihan")
        .safeAreaInset(edge: .bottom) { footer }
    }

    var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) item dipilih").font(.headline).foregroundStyle(Brand.ink)
                Text("\(model.selectedBytes.bytesText) akan dibersihkan").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Bersihkan…") { model.requestCleanup(model.selectedItems) }
                .buttonStyle(PillButtonStyle())
                .disabled(model.selectedItems.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem
    @State private var showInstructions = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selection.contains(item.id) }, set: { _ in model.toggle(item) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isSelectable)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                    SafetyBadge(safety: item.safety)
                    if item.recommended {
                        SparkShape().fill(Brand.accentBright).frame(width: 11, height: 11).help("Direkomendasikan")
                    }
                }
                Text(item.detail.components(separatedBy: "\n").first ?? item.detail)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(item.displayPath)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                ForEach(item.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if let instructions = item.action.instructions, showInstructions {
                    Callout(symbol: "hand.point.right.fill", tint: .blue, text: instructions)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.bytes.bytesText).font(.body.monospacedDigit().weight(.semibold))
                if let date = item.lastActivity {
                    Text(date.relativeText).font(.caption).foregroundStyle(.secondary)
                }
                if !item.action.isAutomatic {
                    Button(showInstructions ? "Tutup panduan" : "Cara membersihkan") { showInstructions.toggle() }
                        .buttonStyle(.link).font(.caption)
                } else if item.isSelectable {
                    Text(item.action.verb).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal(item.path) }
        .contextMenu {
            Button("Tampilkan di Finder") { model.reveal(item.path) }
            Button("Salin path") { model.copyPath(item.path) }
            if item.offloadable {
                Divider()
                Button(model.workVolume.map { "Pindahkan ke \($0.name)" } ?? "Pindahkan ke SSD (pilih SSD kerja dulu)") {
                    Task { await model.offload(item) }
                }
                .disabled(model.workVolume == nil || model.busyMessage != nil)
            }
            if item.isSelectable {
                Divider()
                Button("\(item.action.verb) sekarang…") { model.requestCleanup([item]) }
            }
        }
    }
}

struct ConfirmCleanupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.pendingCleanup ?? []
        let groups = Dictionary(grouping: items, by: { $0.action.verb })
        let immediate = items.filter(\.action.freesSpaceImmediately).reduce(0) { $0 + $1.bytes }

        VStack(alignment: .leading, spacing: 14) {
            if model.outcomes.isEmpty {
                Text(model.isCleaning ? "Membersihkan…" : "Konfirmasi pembersihan").font(.title2.weight(.semibold))
                if model.isCleaning {
                    ProgressView(value: model.cleanProgress) { Text(model.cleanCurrent).font(.caption) }
                } else {
                    Text("Ruang yang langsung bebas: \(immediate.bytesText)").font(.headline)
                    ForEach(Cleaner.preflightWarnings(for: items), id: \.self) { warning in
                        Callout(symbol: "exclamationmark.triangle.fill", tint: .orange, text: warning)
                    }
                    List {
                        ForEach(groups.keys.sorted(), id: \.self) { verb in
                            let entries = groups[verb] ?? []
                            Section("\(verb) · \(entries.reduce(0) { $0 + $1.bytes }.bytesText)") {
                                ForEach(entries) { item in
                                    HStack {
                                        Text(item.title).lineLimit(1)
                                        Spacer()
                                        SafetyBadge(safety: item.safety)
                                        Text(item.bytes.bytesText).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 220)
                }
                HStack {
                    Spacer()
                    Button("Batal") { model.pendingCleanup = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCleaning)
                    Button("Bersihkan \(items.count) item", role: .destructive) {
                        Task { await model.performCleanup() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCleaning)
                }
            } else {
                result
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }

    var result: some View {
        let freed = model.outcomes.reduce(0) { $0 + $1.freedBytes }
        let failed = model.outcomes.filter { !$0.success }
        return VStack(alignment: .leading, spacing: 12) {
            Label("Selesai — \(freed.bytesText) dibebaskan", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text("Ruang kosong sekarang: \(model.freeBytes.bytesText)").font(.headline)
            if !failed.isEmpty {
                Text("\(failed.count) item dilewati:").font(.subheadline.weight(.semibold))
                List(failed) { outcome in
                    VStack(alignment: .leading) {
                        Text(outcome.item.title)
                        Text(outcome.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer()
            }
            HStack {
                Spacer()
                Button("Pindai ulang") {
                    model.pendingCleanup = nil
                    Task { await model.scan() }
                }
                Button("Tutup") { model.pendingCleanup = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
