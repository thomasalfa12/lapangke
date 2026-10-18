import AppKit
import LapangkeCore
import SwiftUI

/// Satu kotak di treemap: folder hasil pemetaan, volume sistem, bagian tak terbaca, atau ruang kosong.
struct MapTile: Identifiable, Hashable {
    enum Kind: Hashable { case folder, file, system, unmapped, free, others }

    var id: String
    var name: String
    var path: String?
    var bytes: Int64
    var unreadable: Int
    var node: MapNode?
    var kind: Kind
    var detail: String?

    var canOpen: Bool { node?.children?.isEmpty == false }
}

struct StorageMapView: View {
    @Environment(AppModel.self) private var model
    @State private var trail: [MapNode] = []
    @State private var hovered: String? = StorageMapView.initialHover
    @State private var pointer: CGPoint = StorageMapView.initialPointer
    /// Hanya untuk snapshot debug: tampilkan tooltip tanpa kursor sungguhan.
    nonisolated(unsafe) static var initialHover: String?
    nonisolated(unsafe) static var initialPointer: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let map = model.storageMap {
                let tiles = tiles(for: map)
                let parentBytes = tiles.reduce(0) { $0 + $1.bytes }
                HStack(alignment: .top, spacing: 18) {
                    treemap(tiles, parentBytes: parentBytes)
                    legend(tiles, parentBytes: parentBytes)
                        .frame(width: 290)
                }
                .padding(20)
            } else if model.isMapping {
                ProgressView(model.mapStatus.isEmpty ? "Memetakan…" : model.mapStatus).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Belum ada peta", systemImage: "square.grid.3x3.square")
                } description: {
                    Text("Peta menunjukkan folder mana yang paling besar, termasuk yang bukan cache.")
                } actions: {
                    Button("Petakan sekarang") { Task { await model.buildMap() } }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .navigationTitle("Peta Storage")
    }

    // MARK: Kepala & breadcrumb

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    crumb("Seluruh disk", active: trail.isEmpty) { trail = [] }
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, node in
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        crumb(node.name, active: index == trail.count - 1) { trail = Array(trail.prefix(index + 1)) }
                    }
                }
                if let map = model.storageMap {
                    Text("Dipetakan \(map.createdAt.relativeText) · \(Int(map.duration)) dtk · arahkan kursor untuk detail, klik untuk masuk")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isMapping {
                ProgressView().controlSize(.small)
                Text(model.mapStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !trail.isEmpty {
                Button { trail.removeLast() } label: { Label("Kembali", systemImage: "chevron.left") }
            }
            Button(model.storageMap == nil ? "Petakan sekarang" : "Petakan ulang") {
                trail = []
                Task { await model.buildMap() }
            }
            .disabled(model.isMapping)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    func crumb(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(active ? .title3.weight(.bold) : .title3)
                .foregroundStyle(active ? Brand.ink : Brand.accent)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!active)
    }

    // MARK: Data

    func tiles(for map: StorageMap) -> [MapTile] {
        if let current = trail.last {
            var tiles = (current.children ?? []).map(tile(from:))
            let shown = tiles.reduce(0) { $0 + $1.bytes }
            if current.bytes - shown > 50 * MB {
                tiles.append(MapTile(id: current.path + "#rest", name: "File & folder kecil lain", path: current.path,
                                     bytes: current.bytes - shown, unreadable: 0, node: nil, kind: .others,
                                     detail: "Gabungan isi yang terlalu kecil untuk ditampilkan sendiri."))
            }
            return grouped(tiles)
        }
        var tiles = map.roots.map(tile(from:))
        if let disk = model.report?.disk {
            for volume in disk.apfsVolumes where volume.role != "Data" && volume.bytes > 200 * MB {
                let name = switch volume.role {
                case "VM": "Swap memori (VM)"
                case "Preboot": "Preboot macOS"
                case "System": "macOS (System)"
                case "Recovery": "Recovery"
                default: volume.name
                }
                tiles.append(MapTile(id: "apfs:\(volume.role)", name: name, path: nil, bytes: volume.bytes, unreadable: 0, node: nil,
                                     kind: .system, detail: "Volume sistem terpisah, dikelola macOS."))
            }
            let dataBytes = disk.apfsVolumes.first { $0.role == "Data" }?.bytes ?? 0
            let mapped = map.roots.reduce(0) { $0 + $1.bytes }
            if dataBytes - mapped > GB {
                tiles.append(MapTile(id: "unmapped", name: "Tidak terbaca", path: nil, bytes: dataBytes - mapped, unreadable: 1, node: nil,
                                     kind: .unmapped, detail: "Data yang tidak bisa dibaca tanpa Full Disk Access (Containers, Tong Sampah, Mail, Messages) dan file sistem lain."))
            }
            tiles.append(MapTile(id: "free", name: "Ruang kosong", path: nil, bytes: disk.available, unreadable: 0, node: nil,
                                 kind: .free, detail: "Ruang yang masih bisa dipakai."))
        }
        return tiles.sorted { $0.bytes > $1.bytes }
    }

    func tile(from node: MapNode) -> MapTile {
        let isFile = node.children == nil && (node.name as NSString).pathExtension.count > 0
        return MapTile(id: node.path, name: node.name, path: node.path, bytes: node.bytes, unreadable: node.unreadable,
                       node: node, kind: isFile ? .file : .folder, detail: nil)
    }

    /// Batasi jumlah kotak agar tetap terbaca; sisanya digabung.
    func grouped(_ tiles: [MapTile]) -> [MapTile] {
        let sorted = tiles.sorted { $0.bytes > $1.bytes }
        guard sorted.count > 36 else { return sorted }
        let rest = sorted.dropFirst(35)
        return Array(sorted.prefix(35)) + [MapTile(id: "rest", name: "\(rest.count) lainnya", path: nil,
                                                    bytes: rest.reduce(0) { $0 + $1.bytes }, unreadable: 0, node: nil,
                                                    kind: .others, detail: "Folder kecil yang digabung.")]
    }

    static let palette: [Color] = [Brand.sky, Brand.lavender, Brand.peach, Brand.lime, Brand.dynamic(light: 0xD8F0F6, dark: 0x173138),
                                   Brand.wash, Brand.dynamic(light: 0xFFF1C9, dark: 0x3A321C)]

    func fill(for tile: MapTile, index: Int) -> AnyShapeStyle {
        switch tile.kind {
        case .system: AnyShapeStyle(Brand.dynamic(light: 0xE6EAEF, dark: 0x262B31))
        case .unmapped: AnyShapeStyle(Brand.dynamic(light: 0xF1E4E8, dark: 0x3A2730))
        case .free: AnyShapeStyle(Brand.dynamic(light: 0xFFFFFF, dark: 0x101820))
        case .others: AnyShapeStyle(Brand.dynamic(light: 0xEEF2F6, dark: 0x1D232A))
        case .folder, .file: AnyShapeStyle(Self.palette[index % Self.palette.count])
        }
    }

    // MARK: Treemap

    func treemap(_ tiles: [MapTile], parentBytes: Int64) -> some View {
        GeometryReader { proxy in
            let rects = Treemap.squarify(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let rect = rects[index].insetBy(dx: 2, dy: 2)
                    if rect.width > 1, rect.height > 1 {
                        tileView(tile, index: index, size: rect.size)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .onHover { inside in
                                if inside { hovered = tile.id } else if hovered == tile.id { hovered = nil }
                            }
                            .onTapGesture { open(tile) }
                            .contextMenu { menu(for: tile) }
                    }
                }
                if let id = hovered, let tile = tiles.first(where: { $0.id == id }) {
                    tooltip(tile, parentBytes: parentBytes)
                        .fixedSize()
                        .offset(tooltipOffset(in: proxy.size))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onContinuousHover { phase in
                if case let .active(location) = phase { pointer = location }
            }
            .animation(.smooth(duration: 0.25), value: trail.count)
        }
        .frame(minHeight: 360)
    }

    func tileView(_ tile: MapTile, index: Int, size: CGSize) -> some View {
        let isHovered = hovered == tile.id
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: index == 0 ? 4 : 12,
                                           bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(fill(for: tile, index: index))
            if tile.kind == .free {
                shape.strokeBorder(Brand.ok.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if isHovered { shape.strokeBorder(Brand.accent, lineWidth: 2.5) }
            if size.width > 74, size.height > 38 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let symbol = symbol(for: tile) { Image(systemName: symbol).font(.caption2.weight(.bold)) }
                        Text(tile.name).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Text(tile.bytes.bytesText).font(size.height > 60 ? .title3.weight(.bold) : .caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(tile.kind == .free ? Brand.ok : Brand.ink)
                .padding(10)
            }
        }
        .scaleEffect(isHovered ? 1.012 : 1)
        .shadow(color: Brand.ink.opacity(isHovered ? 0.18 : 0), radius: 10, y: 4)
        .animation(.smooth(duration: 0.15), value: isHovered)
        .contentShape(shape)
    }

    func symbol(for tile: MapTile) -> String? {
        switch tile.kind {
        case .system: "gearshape.fill"
        case .unmapped: "lock.fill"
        case .free: "sparkles"
        case .file: "doc.fill"
        case .others: "ellipsis"
        case .folder: tile.unreadable > 0 ? "lock.fill" : nil
        }
    }

    func tooltip(_ tile: MapTile, parentBytes: Int64) -> some View {
        let total = model.report?.disk.total ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(tile.name).font(.headline).foregroundStyle(Brand.ink)
            if let path = tile.path, tile.kind == .folder || tile.kind == .file {
                Text(path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            Text(tile.bytes.bytesText).font(.system(size: 22, weight: .bold)).tracking(-0.4).foregroundStyle(Brand.accent)
            HStack(spacing: 10) {
                if parentBytes > 0 {
                    Label("\(percent(tile.bytes, of: parentBytes)) dari \(trail.last?.name ?? "disk terpakai")", systemImage: "chart.pie.fill")
                }
                if total > 0, !trail.isEmpty || tile.kind != .free {
                    Label("\(percent(tile.bytes, of: total)) disk", systemImage: "internaldrive")
                }
            }
            .font(.caption).foregroundStyle(Brand.ink2)
            if let detail = tile.detail {
                Text(detail).font(.caption).foregroundStyle(Brand.ink2).frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tile.unreadable > 0, tile.kind == .folder {
                Label("\(tile.unreadable) folder tidak terbaca — beri Full Disk Access", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(Brand.warn)
            }
            if tile.canOpen {
                Label("Klik untuk membuka · klik kanan untuk opsi", systemImage: "cursorarrow.click").font(.caption2).foregroundStyle(.tertiary)
            } else if tile.path != nil, tile.kind == .folder || tile.kind == .file {
                Label("Klik untuk tampilkan di Finder", systemImage: "cursorarrow.click").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: ExpressiveShape(radius: 16, small: 4))
        .overlay(ExpressiveShape(radius: 16, small: 4).stroke(Brand.ink.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
    }

    /// Kartu info mengikuti kursor, berpindah sisi bila mendekati tepi.
    func tooltipOffset(in size: CGSize) -> CGSize {
        let width: CGFloat = 290
        let height: CGFloat = 170
        var x = pointer.x + 16
        var y = pointer.y + 16
        if x + width > size.width { x = pointer.x - width - 12 }
        if y + height > size.height { y = max(0, pointer.y - height - 12) }
        return CGSize(width: max(0, x), height: y)
    }

    func percent(_ bytes: Int64, of total: Int64) -> String {
        guard total > 0 else { return "–" }
        let value = Double(bytes) / Double(total) * 100
        return value < 1 ? "<1%" : String(format: "%.0f%%", value)
    }

    func open(_ tile: MapTile) {
        if let node = tile.node, tile.canOpen {
            hovered = nil
            trail.append(node)
        } else if let path = tile.path, tile.kind == .folder || tile.kind == .file {
            model.reveal(path)
        }
    }

    @ViewBuilder
    func menu(for tile: MapTile) -> some View {
        if tile.canOpen { Button("Buka \(tile.name)") { open(tile) } }
        if let path = tile.path, tile.kind == .folder || tile.kind == .file {
            Button("Tampilkan di Finder") { model.reveal(path) }
            Button("Salin path") { model.copyPath(path) }
            Button("Cari di Pembersihan") {
                model.search = path.abbreviatingHome
                model.filter = .all
                model.categoryFilter = nil
                model.pane = .cleanup
            }
        }
    }

    // MARK: Legenda

    func legend(_ tiles: [MapTile], parentBytes: Int64) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(trail.last?.name ?? "Isi disk").font(.headline).foregroundStyle(Brand.ink).padding(.bottom, 6)
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    legendRow(tile, index: index, parentBytes: parentBytes)
                }
            }
        }
    }

    func legendRow(_ tile: MapTile, index: Int, parentBytes: Int64) -> some View {
        let share = Double(tile.bytes) / Double(max(parentBytes, 1))
        return Button { open(tile) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill(for: tile, index: index))
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.ink.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(tile.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(tile.bytes.bytesText).monospacedDigit().foregroundStyle(Brand.ink2)
                    }
                    ShareBar(share: share)
                }
            }
            .font(.callout)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(hovered == tile.id ? Brand.wash : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = tile.id } else if hovered == tile.id { hovered = nil }
        }
        .contextMenu { menu(for: tile) }
    }
}

struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Brand.accentBright.opacity(0.55)).frame(width: max(2, proxy.size.width * share))
        }
        .frame(height: 4)
    }
}
