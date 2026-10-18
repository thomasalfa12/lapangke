import AppKit
import LapangkeCore
import Observation
import SwiftUI

/// Hal yang ditampilkan Pulau Lapangke. Pulau hanya muncul saat ada yang penting.
enum IslandEvent: Equatable {
    case cleaning(CleanupProgress)
    case celebrate(freed: Int64, freeNow: Int64)
    case lowSpace(free: Int64, recommended: Int64)
    case spaceDrop(dropped: Int64, minutes: Int, culprit: String?)
    case ssd(name: String, free: Int64, offloadable: Int64)
    case peek(free: Int64, total: Int64, recommended: Int64)

    /// Peristiwa yang bisa dibuka lebih lebar dengan hover.
    var hasDetail: Bool {
        switch self {
        case .cleaning, .celebrate: false
        default: true
        }
    }
}

@MainActor
@Observable
final class IslandModel {
    var event: IslandEvent?
    var expanded = false
    /// Tindakan dari tombol pulau (dipasang AppServices).
    @ObservationIgnored var onPrimary: ((IslandEvent) -> Void)?
    @ObservationIgnored var onDismiss: (() -> Void)?
    @ObservationIgnored var onExpand: (() -> Void)?
}

/// Panel non-aktif di atas menu bar: tidak mencuri fokus, ikut semua Space & layar penuh.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view yang menerima klik pertama dan hover meski app tidak aktif.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        area = tracking
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class IslandController {
    let model = IslandModel()
    private var panel: IslandPanel?
    private var hosting: IslandHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    var enabled = true

    #if DEBUG
    var debugView: NSView? { panel?.contentView }
    func debugShow(_ event: IslandEvent, expanded: Bool) {
        show(event, autoHide: nil)
        model.expanded = expanded
        layout(animated: false)
        panel?.alphaValue = 1
    }
    #endif

    func show(_ event: IslandEvent, autoHide: TimeInterval? = 8) {
        guard enabled else { return }
        ensurePanel()
        let wasHidden = model.event == nil
        model.event = event
        if case .cleaning = event {} else { model.expanded = false }
        layout(animated: !wasHidden)
        panel?.orderFrontRegardless()
        if wasHidden { panel?.alphaValue = 0; panel?.animator().alphaValue = 1 }
        scheduleHide(after: autoHide)
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, model.event != nil else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.hovering == false else { return }
                self.model.event = nil
                self.model.expanded = false
                self.panel?.orderOut(nil)
            }
        })
    }

    private func scheduleHide(after delay: TimeInterval?) {
        hideTask?.cancel()
        guard let delay else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = IslandPanel()
        let view = IslandHostingView(rootView: AnyView(IslandView(model: model, geometry: geometry())))
        // Ukuran panel ditentukan controller, bukan ukuran ideal SwiftUI.
        view.sizingOptions = []
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onHover = { [weak self] inside in
            guard let self else { return }
            self.hovering = inside
            if inside {
                self.hideTask?.cancel()
                if self.model.event?.hasDetail == true, !self.model.expanded {
                    self.model.expanded = true
                    self.layout(animated: true)
                }
            } else if self.model.event != nil {
                if case .cleaning = self.model.event {} else {
                    self.model.expanded = false
                    self.layout(animated: true)
                    self.scheduleHide(after: 3)
                }
            }
        }
        model.onDismiss = { [weak self] in self?.hide() }
        model.onExpand = { [weak self] in
            guard let self, self.model.event?.hasDetail == true else { return }
            self.hideTask?.cancel()
            self.model.expanded = true
            self.layout(animated: true)
        }
        panel.contentView = view
        self.panel = panel
        hosting = view
    }

    // MARK: Geometri (poni vs menu bar biasa)

    struct Geometry {
        var hasNotch: Bool
        var notchWidth: CGFloat
        var menuBarHeight: CGFloat
    }

    func geometry() -> Geometry {
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let screen else { return Geometry(hasNotch: false, notchWidth: 0, menuBarHeight: 24) }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return Geometry(hasNotch: true, notchWidth: screen.frame.width - left.width - right.width, menuBarHeight: screen.safeAreaInsets.top)
        }
        return Geometry(hasNotch: false, notchWidth: 0, menuBarHeight: menuBar)
    }

    private func layout(animated: Bool) {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let geometry = geometry()
        let size = IslandContent.measure(model: model, geometry: geometry)
        let x = (screen.frame.midX - size.width / 2).rounded()
        // Dengan poni: menempel di tepi atas layar (menyatu dengan poni). Tanpa poni: tepat di bawah menu bar.
        let top = geometry.hasNotch ? screen.frame.maxY : screen.frame.maxY - geometry.menuBarHeight - 8
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        hosting?.rootView = AnyView(IslandView(model: model, geometry: geometry))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.05)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            // Lewat animator dengan durasi 0 agar animasi frame yang masih berjalan ikut dibatalkan.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(frame, display: true)
            }
        }
    }
}

// MARK: - Tampilan

/// Bentuk pulau: kapsul penuh saat ringkas, kartu radius 28 saat terbuka; tanpa sudut atas bila menempel di poni.
struct IslandView: View {
    @Bindable var model: IslandModel
    let geometry: IslandController.Geometry

    var body: some View {
        let mode = model.mode
        ZStack(alignment: .top) {
            background(mode)
            IslandContent(model: model, geometry: geometry)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture {
            // Klik pada kapsul ringkas membuka detailnya (cadangan bila hover tidak terdeteksi).
            if mode == .compact, model.event?.hasDetail == true { model.onExpand?() }
        }
    }

    @ViewBuilder
    func background(_ mode: IslandModel.Mode) -> some View {
        let radius: CGFloat = mode == .compact ? 999 : 28
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: geometry.hasNotch ? 0 : radius, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: geometry.hasNotch ? 0 : radius, style: .continuous
        )
        shape.fill(Color.black)
            .overlay(shape.stroke(Color.white.opacity(geometry.hasNotch ? 0 : 0.1), lineWidth: 1))
    }
}

extension IslandModel {
    enum Mode { case compact, expanded, cleaning, celebrate }

    var mode: Mode {
        switch event {
        case .cleaning: .cleaning
        case .celebrate: .celebrate
        default: expanded ? .expanded : .compact
        }
    }
}

/// Isi pulau. Ukurannya mengikuti isi (diukur controller), jadi tidak ada ruang kosong.
struct IslandContent: View {
    let model: IslandModel
    let geometry: IslandController.Geometry

    static let cardWidth: CGFloat = 400

    /// Ukuran panel = ukuran ideal isi untuk mode saat ini.
    @MainActor
    static func measure(model: IslandModel, geometry: IslandController.Geometry) -> CGSize {
        let controller = NSHostingController(rootView: IslandContent(model: model, geometry: geometry).sizing(model.mode, geometry: geometry))
        let size = controller.sizeThatFits(in: CGSize(width: 900, height: 600))
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    var body: some View {
        switch model.mode {
        case .compact: compact
        case .expanded: expanded
        case .cleaning: cleaning
        case .celebrate: celebrate
        }
    }

    // MARK: Isi per peristiwa

    struct Info {
        var glyph: Glyph
        var compactTitle: String
        var compactTrailing: String?
        var compactChip: String?
        var title: String
        var subtitle: String
        var detail: String
        var action: String
    }

    enum Glyph {
        case ring(Double, Color)
        case symbol(String, Color)
    }

    var info: Info? {
        switch model.event {
        case let .lowSpace(free, recommended):
            let total = Self.totalDisk
            return Info(glyph: .ring(total > 0 ? Double(total - free) / Double(total) : 0.95, Color(hex: 0xFF7A66)),
                        compactTitle: "Sisa \(free.bytesText)",
                        compactChip: recommended > 0 ? "Bersihkan \(recommended.bytesText)" : "Ruang menipis",
                        title: "Ruang Mac menipis", subtitle: "Sisa \(free.bytesText)\(total > 0 ? " dari \(total.bytesText)" : "")",
                        detail: recommended > 0 ? "Build Xcode atau Gradle bisa gagal. \(recommended.bytesText) cache & sisa build aman dibersihkan." : "Pindai untuk melihat apa saja yang aman dihapus.",
                        action: recommended > 0 ? "Bersihkan \(recommended.bytesText)" : "Pindai sekarang")
        case let .spaceDrop(dropped, minutes, culprit):
            return Info(glyph: .symbol("arrow.down.right", Color(hex: 0xF0B14A)),
                        compactTitle: "Turun \(dropped.bytesText)", compactTrailing: "\(minutes) mnt",
                        title: "Ruang turun \(dropped.bytesText)", subtitle: "dalam \(minutes) menit terakhir",
                        detail: culprit.map { "Kemungkinan besar dari \($0)." } ?? "Lihat folder yang membesar di Peta Storage.",
                        action: "Lihat penyebabnya")
        case let .ssd(name, free, offloadable):
            return Info(glyph: .symbol("externaldrive.fill", Brand.cyan),
                        compactTitle: name, compactTrailing: "\(free.bytesText) kosong",
                        title: "\(name) terpasang", subtitle: "\(free.bytesText) kosong · siap dipakai",
                        detail: offloadable > 0 ? "\(offloadable.bytesText) arsip & file besar bisa dipindah ke SSD ini." : "Bisa dipakai untuk cache dev, arsip, dan file besar.",
                        action: "Buka SSD Eksternal")
        case let .peek(free, total, recommended):
            return Info(glyph: .ring(total > 0 ? Double(total - free) / Double(total) : 0, Brand.cyan),
                        compactTitle: "\(free.bytesText) kosong", compactTrailing: "dari \(total.bytesText)",
                        title: "Macintosh HD", subtitle: "\(free.bytesText) kosong dari \(total.bytesText)",
                        detail: recommended > 0 ? "\(recommended.bytesText) siap dibersihkan dengan aman." : "Mac Anda lega. Belum ada yang perlu dibersihkan.",
                        action: recommended > 0 ? "Bersihkan \(recommended.bytesText)" : "Buka Lapangke")
        default:
            return nil
        }
    }

    nonisolated(unsafe) static var totalDisk: Int64 = DiskInspector.freeSpace().total

    @ViewBuilder
    func glyph(_ glyph: Glyph, size: CGFloat) -> some View {
        switch glyph {
        case let .ring(fraction, tint):
            IslandRing(fraction: fraction, tint: tint, size: size, spinning: false)
        case let .symbol(name, tint):
            Image(systemName: name)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.2), in: Circle())
        }
    }

    // MARK: Ringkas

    @ViewBuilder
    var compact: some View {
        if let info {
            if geometry.hasNotch {
                // Isi di kiri & kanan poni; tengahnya kosong (tertutup poni).
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        glyph(info.glyph, size: 18)
                        Text(info.compactTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: 150, alignment: .leading)
                    Color.clear.frame(width: geometry.notchWidth)
                    Text(info.compactChip ?? info.compactTrailing ?? "").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 150, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: geometry.menuBarHeight)
            } else {
                HStack(spacing: 10) {
                    glyph(info.glyph, size: 20)
                    Text(info.compactTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let trailing = info.compactTrailing {
                        Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    if let chip = info.compactChip {
                        Text(chip).font(.system(size: 11, weight: .bold)).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, info.compactChip == nil ? 16 : 8)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Terbuka

    @ViewBuilder
    var expanded: some View {
        if let info {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    glyph(info.glyph, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text(info.subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { model.onDismiss?() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22).background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Tutup")
                }
                Text(info.detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Nanti") { model.onDismiss?() }.buttonStyle(IslandButtonStyle(prominent: false))
                    Button(info.action) { if let event = model.event { model.onPrimary?(event) } }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                }
            }
            .padding(.top, geometry.hasNotch ? geometry.menuBarHeight + 8 : 16)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    // MARK: Membersihkan

    @ViewBuilder
    var cleaning: some View {
        if case let .cleaning(state) = model.event {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        IslandRing(fraction: state.fraction, tint: Brand.cyan, size: 34, spinning: true)
                        Text("\(Int(state.fraction * 100))").font(.system(size: 10, weight: .bold)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(state.phase.label)…").font(.system(size: 14, weight: .bold))
                        Text("\(state.processed.bytesText) dari \(state.total.bytesText)").font(.system(size: 12, weight: .medium))
                            .monospacedDigit().foregroundStyle(.white.opacity(0.6)).contentTransition(.numericText())
                    }
                    Spacer(minLength: 8)
                    Text("\(min(state.itemIndex + 1, state.itemCount))/\(state.itemCount)").font(.system(size: 12, weight: .semibold))
                        .monospacedDigit().foregroundStyle(.white.opacity(0.6))
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(LinearGradient(colors: [Brand.cyan, Color(hex: 0x1F8CF0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, proxy.size.width * state.fraction))
                            .animation(.smooth(duration: 0.4), value: state.fraction)
                    }
                }
                .frame(height: 6)
                Text(state.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, geometry.hasNotch ? geometry.menuBarHeight + 8 : 14)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    // MARK: Perayaan

    @ViewBuilder
    var celebrate: some View {
        if case let .celebrate(freed, freeNow) = model.event {
            HStack(spacing: 12) {
                IslandSparkBurst()
                VStack(alignment: .leading, spacing: 1) {
                    Text("+\(freed.bytesText) lega").font(.system(size: 16, weight: .bold)).tracking(-0.3)
                    Text("Sekarang \(freeNow.bytesText) kosong").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 22)
            .padding(.top, geometry.hasNotch ? geometry.menuBarHeight + 6 : 8)
            .padding(.bottom, 8)
        }
    }

    /// Lebar tetap untuk kartu, lebar ideal untuk kapsul.
    @ViewBuilder
    func sizing(_ mode: IslandModel.Mode, geometry: IslandController.Geometry) -> some View {
        switch mode {
        case .compact, .celebrate: self.fixedSize()
        case .expanded: self.frame(width: Self.cardWidth).fixedSize(horizontal: false, vertical: true)
        case .cleaning: self.frame(width: Self.cardWidth - 20).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color(hex: 0x0064AF) : .white)
            .background(prominent ? Color.white : Color.white.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

struct IslandRing: View {
    let fraction: Double
    let tint: Color
    let size: CGFloat
    let spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 * 360 : 0
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: size * 0.16)
                Circle().trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if spinning {
                    Circle().trim(from: 0, to: 0.12)
                        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                        .rotationEffect(.degrees(angle - 90))
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.4), value: fraction)
    }
}

/// Ledakan spark kecil saat pembersihan selesai.
struct IslandSparkBurst: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let t = min(1, context.date.timeIntervalSince(start) / 1.2)
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) / 6 * 2 * .pi
                    SparkShape().fill(index.isMultiple(of: 2) ? Brand.cyan : Color(hex: 0xDCEDA7))
                        .frame(width: 9 * (1 - t * 0.6), height: 9 * (1 - t * 0.6))
                        .offset(x: cos(angle) * 14 * t, y: sin(angle) * 14 * t)
                        .opacity(1 - t * 0.7)
                }
                FlowerShape().fill(Color.white).frame(width: 24, height: 24).rotationEffect(.degrees(12 + t * 40))
                SparkShape().fill(Color(hex: 0x0064AF)).frame(width: 11, height: 11)
            }
        }
        .frame(width: 38, height: 38)
        .onAppear { start = Date() }
    }
}

// MARK: - Ikon menu bar hidup

enum MenuBarIcon {
    /// Cincin template 18 pt: isi = bagian disk yang terpakai; bila ruang menipis, ada tanda seru di tengah.
    static func make(usedFraction: Double, low: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2.2, dy: 2.2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.4
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let arc = NSBezierPath()
            let fraction = max(0.04, min(1, usedFraction))
            arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            if low {
                let bar = NSBezierPath(roundedRect: NSRect(x: center.x - 0.9, y: center.y - 0.6, width: 1.8, height: 4.2), xRadius: 0.9, yRadius: 0.9)
                NSColor.black.setFill()
                bar.fill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 0.95, y: center.y - 3.1, width: 1.9, height: 1.9)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
