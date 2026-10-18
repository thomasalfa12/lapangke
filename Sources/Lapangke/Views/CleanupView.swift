import LapangkeCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.visibleItems
        let groups = Dictionary(grouping: items, by: \.category)

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Picker("Tampilkan", selection: $model.filter) {
                        ForEach(ItemFilter.allCases) { filter in
                            Text("\(filter.rawValue)  \(model.count(for: filter))").tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .controlSize(.large)
                if !model.categoryTotals.isEmpty { CategoryChips() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            Button { model.selectRecommended() } label: { Label("Pilih rekomendasi", systemImage: "checkmark.circle") }
                .disabled((model.report?.recommendedItems.isEmpty ?? true))
            Button { model.selection.removeAll() } label: { Label("Kosongkan", systemImage: "xmark.circle") }
                .disabled(model.selection.isEmpty)
            Button("Bersihkan…") { model.requestCleanup(model.selectedItems) }
                .buttonStyle(PillButtonStyle())
                .disabled(model.selectedItems.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Kategori sebagai chip yang bisa digeser, lengkap dengan ukurannya pada filter aktif.
struct CategoryChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.categoryTotals
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Semua kategori", symbol: "square.grid.2x2", bytes: totals.reduce(0) { $0 + $1.1 }, selected: model.categoryFilter == nil) {
                    model.categoryFilter = nil
                }
                ForEach(totals, id: \.0) { category, bytes in
                    chip(title: category.title, symbol: category.symbol, bytes: bytes, selected: model.categoryFilter == category) {
                        model.categoryFilter = model.categoryFilter == category ? nil : category
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    func chip(title: String, symbol: String, bytes: Int64, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.callout)
                Text(title).font(.callout.weight(.medium))
                Text(bytes.bytesText).font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.22) : Brand.accent.opacity(0.1), in: Capsule())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Brand.ink)
            .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Brand.wash), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: selected)
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

        VStack(alignment: .leading, spacing: 16) {
            if !model.outcomes.isEmpty {
                result
            } else if model.isCleaning, let state = model.cleanState {
                CleanupProgressPanel(state: state, startedAt: model.cleanStartedAt ?? Date(), stopRequested: model.stopRequested) {
                    model.requestStop()
                }
            } else {
                HStack(spacing: 14) {
                    Sticker(symbol: "sparkles", background: Brand.limeSticker, foreground: Color(hex: 0x304313), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Konfirmasi pembersihan").font(.title2.weight(.semibold)).foregroundStyle(Brand.ink)
                        Text("Ruang yang langsung bebas: \(immediate.bytesText) · \(items.count) item").font(.callout).foregroundStyle(Brand.ink2)
                    }
                }
                ForEach(model.cleanWarnings, id: \.self) { warning in
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Brand.warn, text: warning)
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
                HStack {
                    Spacer()
                    Button("Batal") { model.pendingCleanup = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Bersihkan \(items.count) item") {
                        Task { await model.performCleanup() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 540)
        .interactiveDismissDisabled(model.isCleaning)
    }

    var result: some View {
        let freed = model.outcomes.reduce(0) { $0 + $1.freedBytes }
        let failed = model.outcomes.filter { !$0.success }
        let trashed = model.outcomes.filter { $0.success && $0.item.action == .trash }.reduce(0) { $0 + $1.item.bytes }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    FlowerShape().fill(Brand.flower).frame(width: 72, height: 72).rotationEffect(.degrees(12))
                    SparkShape().fill(Brand.accent).frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("+\(freed.bytesText) lega").font(.system(size: 30, weight: .bold)).tracking(-0.8).foregroundStyle(Brand.ink)
                    Text("Ruang kosong sekarang \(model.freeBytes.bytesText)").font(.callout).foregroundStyle(Brand.ink2)
                }
            }
            if trashed > 0 {
                Callout(symbol: "trash", tint: Brand.accent, text: "\(trashed.bytesText) ada di Tong Sampah dan baru benar-benar lega setelah Tong Sampah dikosongkan.")
            }
            if model.stopRequested {
                Callout(symbol: "pause.circle.fill", tint: Brand.warn, text: "Dihentikan sesuai permintaan. Item yang belum diproses tetap di tempatnya.")
            }
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
                Button("Selesai") { model.pendingCleanup = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// Progres pembersihan yang selalu terlihat hidup: cincin total, bar per item, waktu berjalan,
/// dan spark berputar. Fase tanpa ukuran (reset simulator) memakai animasi indeterminate.
struct CleanupProgressPanel: View {
    let state: CleanupProgress
    let startedAt: Date
    let stopRequested: Bool
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Brand.wash, lineWidth: 16)
                Circle()
                    .trim(from: 0, to: max(0.02, state.fraction))
                    .stroke(AngularGradient(colors: [Brand.cyan, Brand.accentBright, Brand.accent, Brand.cyan], center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.4), value: state.fraction)
                TimelineView(.animation) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360
                    SparkShape().fill(Brand.accentBright.opacity(0.9)).frame(width: 22, height: 22)
                        .offset(y: -78).rotationEffect(.degrees(angle))
                }
                VStack(spacing: 2) {
                    Text(state.processed.bytesText).font(.system(size: 30, weight: .bold)).tracking(-0.8)
                        .foregroundStyle(Brand.ink).contentTransition(.numericText()).animation(.smooth, value: state.processed)
                    Text("dari \(state.total.bytesText)").font(.callout).foregroundStyle(Brand.ink2)
                }
            }
            .frame(width: 170, height: 170)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.phase.label).font(.caption.weight(.bold)).tracking(1).textCase(.uppercase).foregroundStyle(Brand.accent)
                    Spacer()
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Item \(min(state.itemIndex + 1, state.itemCount)) dari \(state.itemCount) · \(Self.elapsed(since: startedAt, now: context.date))")
                            .font(.caption).monospacedDigit().foregroundStyle(Brand.ink2)
                    }
                }
                Text(state.title).font(.headline).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.middle)
                if state.phase.isIndeterminate {
                    BrandProgressBar(fraction: nil)
                    Text(state.phase == .resetting ? "Simulator sedang di-reset lewat Xcode. Biasanya 10–60 detik; Lapangke tetap bekerja." : "Memindahkan ke Tong Sampah…")
                        .font(.caption).foregroundStyle(Brand.ink2)
                } else {
                    BrandProgressBar(fraction: state.itemFraction)
                    Text("\(state.itemDone.bytesText) dari \(state.itemTotal.bytesText) pada item ini")
                        .font(.caption).monospacedDigit().foregroundStyle(Brand.ink2)
                }
            }
            .padding(16)
            .background(Brand.wash, in: ExpressiveShape(radius: 20, small: 6))

            HStack {
                Text("Aman ditinggal. Progres juga tampil di Pulau Lapangke di atas layar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(stopRequested ? "Berhenti setelah item ini…" : "Hentikan setelah item ini", action: stop)
                    .disabled(stopRequested)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Bar progres bergradien brand. `fraction` nil = indeterminate (kilau bergerak terus).
struct BrandProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.accent.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [Brand.cyan, Brand.accentBright, Brand.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, proxy.size.width * fraction))
                        .animation(.smooth(duration: 0.3), value: fraction)
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule()
                            .fill(LinearGradient(colors: [Brand.cyan.opacity(0), Brand.accentBright, Brand.cyan.opacity(0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * 0.35)
                            .offset(x: (proxy.size.width * 1.35) * phase - proxy.size.width * 0.35)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 8)
    }
}
