import AppKit
import LapangkeCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.start() }
    }
}

struct LapangkeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppServices.shared.model

    var body: some Scene {
        Window("Lapangke", id: "main") {
            ContentView()
                .environment(model)
                .tint(Brand.accent)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1140, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Pindai Ulang") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
            }
        }

        MenuBarExtra {
            MenuBarPanel().environment(model).tint(Brand.accent)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .tint(Brand.accent)
        }
    }
}

/// Cincin pengukur di menu bar + ruang kosong. Sekaligus menyimpan aksi buka-jendela untuk layanan.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let used = model.totalBytes > 0 ? Double(model.totalBytes - model.freeBytes) / Double(model.totalBytes) : 0
        Image(nsImage: MenuBarIcon.make(usedFraction: used, low: model.isLowOnSpace))
        Text(model.freeBytes.bytesText)
            .task { AppServices.shared.openMainWindow = { openWindow(id: "main") } }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Pane.allCases, selection: Binding($model.pane)) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .badge(badge(for: pane))
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    BrandMark(size: 30)
                    Text("Lapangke").font(.system(size: 18, weight: .bold)).tracking(-0.4).foregroundStyle(Brand.ink)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                BannerStack()
                Group {
                    switch model.pane {
                    case .overview: OverviewView()
                    case .cleanup: CleanupView()
                    case .map: StorageMapView()
                    case .apps: AppsView()
                    case .ssd: SSDView()
                    case .history: HistoryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environment(model).tint(Brand.accent)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingCleanup != nil },
            set: { if !$0 && !model.isCleaning { model.pendingCleanup = nil } }
        )) {
            ConfirmCleanupSheet().environment(model)
        }
        .task {
            AppServices.shared.openMainWindow = { openWindow(id: "main") }
            if model.report == nil { await model.scan() }
        }
        #if DEBUG
        .task { await Snapshotter.runIfRequested(model: model) }
        #endif
    }

    func badge(for pane: Pane) -> Text? {
        switch pane {
        case .cleanup:
            guard let bytes = model.report?.recommendedBytes, bytes > 0 else { return nil }
            return Text(bytes.bytesText)
        case .ssd:
            return model.volumes.isEmpty ? nil : Text("\(model.volumes.count)")
        default:
            return nil
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Macintosh HD").font(.caption.weight(.semibold))
            CapacityBar(used: model.totalBytes - model.freeBytes, total: model.totalBytes, warning: model.isLowOnSpace)
            Text("\(model.freeBytes.bytesText) kosong dari \(model.totalBytes.bytesText)")
                .font(.caption).foregroundStyle(model.isLowOnSpace ? .red : .secondary)
        }
        .padding(12)
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BrandMark(size: 34)
                VStack(alignment: .leading) {
                    Text("\(model.freeBytes.bytesText) kosong").font(.headline)
                    Text("dari \(model.totalBytes.bytesText)").font(.caption).foregroundStyle(.secondary)
                }
            }
            CapacityBar(used: model.totalBytes - model.freeBytes, total: model.totalBytes, warning: model.isLowOnSpace)
            if model.isLowOnSpace {
                Callout(symbol: "exclamationmark.triangle.fill", tint: .red,
                        text: "Ruang di bawah \(model.settings.lowSpaceWarningGB) GB. Build Xcode/Gradle bisa gagal.")
            }
            if let report = model.report {
                LabeledContent("Rekomendasi siap dibersihkan", value: report.recommendedBytes.bytesText)
                Text("Pindaian \(report.startedAt.relativeText)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.volumes) { volume in
                Label("\(volume.name): \(volume.free.bytesText) kosong", systemImage: "externaldrive.fill")
                    .font(.callout)
            }
            Divider()
            HStack {
                Button("Buka Lapangke") { open(.overview) }
                Spacer()
                Button(model.isScanning ? "Memindai…" : "Pindai") {
                    Task { await model.scan() }
                }
                .disabled(model.isScanning)
                Button("Bersihkan…") {
                    open(.cleanup)
                    model.filter = .recommended
                    model.selectRecommended()
                    model.requestCleanup(model.selectedItems)
                }
                .buttonStyle(PillButtonStyle())
                .disabled((model.report?.recommendedBytes ?? 0) == 0)
            }
            HStack {
                Button {
                    AppServices.shared.peek()
                } label: {
                    Label("Intip Pulau Lapangke", systemImage: "capsule.fill")
                }
                .buttonStyle(.borderless).font(.caption)
                Spacer()
                Button("Keluar") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    func open(_ pane: Pane) {
        model.pane = pane
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
