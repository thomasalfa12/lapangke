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
