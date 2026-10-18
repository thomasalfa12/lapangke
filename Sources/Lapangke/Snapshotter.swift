#if DEBUG
import AppKit
import LapangkeCore
import SwiftUI

/// Hanya build debug: `LAPANGKE_SNAPSHOT_DIR=/tmp/x .build/debug/Lapangke` merender tiap halaman
/// ke PNG (tanpa izin Screen Recording), membuka lembar konfirmasi tanpa menjalankannya, lalu keluar.
@MainActor
enum Snapshotter {
    static func runIfRequested(model: AppModel) async {
        guard let directory = ProcessInfo.processInfo.environment["LAPANGKE_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: directory)
        if ProcessInfo.processInfo.environment["LAPANGKE_SNAPSHOT_LIGHT"] != nil { NSApp.appearance = NSAppearance(named: .aqua) }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.showOnboarding = false
        while model.isScanning || model.report == nil { try? await Task.sleep(for: .milliseconds(500)) }
        // Mode materi website: tampilan setelah setup selesai (izin Full Disk Access sudah diberikan).
        if ProcessInfo.processInfo.environment["LAPANGKE_SNAPSHOT_LIGHT"] != nil { model.report?.disk.hasFullDiskAccess = true }
        await model.loadApps()
        if model.storageMap == nil { await model.buildMap() }

        for pane in Pane.allCases {
            model.pane = pane
            try? await Task.sleep(for: .seconds(2))
            capture(mainWindow()?.contentView, to: output.appendingPathComponent("\(pane.rawValue).png"))
        }

        model.pane = .cleanup
        model.filter = .all
        try? await Task.sleep(for: .seconds(1))
        capture(mainWindow()?.contentView, to: output.appendingPathComponent("cleanup-all.png"))

        model.pane = .overview
        model.requestCleanup(model.report?.recommendedItems ?? [])
        try? await Task.sleep(for: .seconds(2))
        capture(mainWindow()?.attachedSheet?.contentView, to: output.appendingPathComponent("confirm-sheet.png"))
        model.pendingCleanup = nil

        let panel = NSHostingView(rootView: MenuBarPanel().environment(model))
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: panel.fittingSize.height)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        window.orderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        capture(panel, to: output.appendingPathComponent("menubar.png"))

        // Peta dengan tooltip hover (tile terbesar).
        if let map = model.storageMap, let first = map.roots.max(by: { $0.bytes < $1.bytes }) {
            StorageMapView.initialHover = first.path
            StorageMapView.initialPointer = CGPoint(x: 260, y: 140)
            model.pane = .overview
            try? await Task.sleep(for: .seconds(1))
            model.pane = .map
            try? await Task.sleep(for: .seconds(2))
            capture(mainWindow()?.contentView, to: output.appendingPathComponent("map-hover.png"))
            StorageMapView.initialHover = nil
        }

        // Panel progres di tengah penghapusan (keadaan contoh, tidak menghapus apa pun).
        if let items = model.report?.recommendedItems, !items.isEmpty {
            model.pendingCleanup = items
            model.isCleaning = true
            model.cleanStartedAt = Date().addingTimeInterval(-37)
            let total = items.reduce(0) { $0 + $1.bytes }
            model.cleanState = CleanupProgress(itemIndex: 6, itemCount: items.count, title: items[min(6, items.count - 1)].title,
                                               phase: .deleting, itemDone: 180_000_000, itemTotal: 431_000_000,
                                               processed: total * 46 / 100, total: total)
            try? await Task.sleep(for: .seconds(2))
            capture(mainWindow()?.attachedSheet?.contentView, to: output.appendingPathComponent("progress-sheet.png"))
            model.isCleaning = false
            model.cleanState = nil
            model.pendingCleanup = nil
            try? await Task.sleep(for: .seconds(1))
        }

        // Panduan izin.
        model.showOnboarding = true
        try? await Task.sleep(for: .seconds(2))
        capture(mainWindow()?.attachedSheet?.contentView, to: output.appendingPathComponent("onboarding.png"))
        model.showOnboarding = false
        try? await Task.sleep(for: .seconds(1))

        // Pulau Lapangke di setiap keadaan.
        let island = AppServices.shared.island
        island.enabled = true
        let events: [(String, IslandEvent, Bool)] = [
            ("island-low-compact", .lowSpace(free: 9_250_000_000, recommended: 10_140_000_000), false),
            ("island-low-expanded", .lowSpace(free: 9_250_000_000, recommended: 10_140_000_000), true),
            ("island-cleaning", .cleaning(CleanupProgress(itemIndex: 6, itemCount: 39, title: "Cache Google Chrome", phase: .deleting,
                                                          itemDone: 1_200_000_000, itemTotal: 2_910_000_000, processed: 4_660_000_000, total: 10_140_000_000)), false),
            ("island-celebrate", .celebrate(freed: 10_140_000_000, freeNow: 19_390_000_000), false),
            ("island-drop-expanded", .spaceDrop(dropped: 9_200_000_000, minutes: 52, culprit: "Simulator iOS (+8,3 GB)"), true),
            ("island-ssd-expanded", .ssd(name: "Samsung T7", free: 912_000_000_000, offloadable: 15_600_000_000), true),
        ]
        for (name, event, expanded) in events {
            island.debugShow(event, expanded: expanded)
            try? await Task.sleep(for: .seconds(1.2))
            capture(island.debugView, to: output.appendingPathComponent("\(name).png"))
        }
        island.hide()
        exit(0)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == "Lapangke" } ?? NSApp.windows.first { $0.isVisible }
    }

    static func capture(_ view: NSView?, to url: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
