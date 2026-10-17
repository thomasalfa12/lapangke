import Foundation
import Testing
@testable import LapangkeCore

@Suite struct GeneralUserTests {
    @Test func appDataMatchesBundleIDAndExactNameOnly() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for relative in [
            "Library/Application Support/com.spotify.client/a", "Library/Caches/com.spotify.client/a",
            "Library/Application Support/Spotify/a", "Library/Containers/com.spotify.client.Widget/a",
            "Library/Group Containers/2FNC3A47ZF.com.spotify.client/a", "Library/Saved Application State/com.spotify.client.savedState/a",
            "Library/Application Support/Google/a", "Library/Caches/com.spotify.clientx/a",
        ] { try box.make(relative) }
        let found = Set(InstalledApps.dataLocations(bundleID: "com.spotify.client", name: "Spotify", home: box.home).map {
            String($0.path.dropFirst(box.home.path.count + 1))
        })
        #expect(found == [
            "Library/Application Support/com.spotify.client", "Library/Caches/com.spotify.client",
            "Library/Application Support/Spotify", "Library/Containers/com.spotify.client.Widget",
            "Library/Group Containers/2FNC3A47ZF.com.spotify.client", "Library/Saved Application State/com.spotify.client.savedState",
        ])
        // Folder vendor bersama tidak pernah dicocokkan dari nama.
        #expect(InstalledApps.dataLocations(bundleID: nil, name: "Google", home: box.home).isEmpty)
    }

    func app(role: AppRole, lastUsedDaysAgo: Int?, bytes: Int64 = 500 * MB) -> InstalledApp {
        let now = Date()
        return InstalledApp(
            name: "X", path: "/Applications/X.app", bundleID: "x.y", executable: "X", version: "1", categoryType: nil,
            bytes: bytes, data: [], lastUsed: lastUsedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
            useCount: 3, fromAppStore: false, role: role, reason: "", suggested: false, advice: ""
        )
    }

    @Test func adviceSuggestsUnusedAppsButNotSystemOrActive() {
        let now = Date()
        #expect(InstalledApps.advise(app(role: .nonWork, lastUsedDaysAgo: 40), now: now).0)
        #expect(InstalledApps.advise(app(role: .other, lastUsedDaysAgo: 120), now: now).0)
        #expect(InstalledApps.advise(app(role: .work, lastUsedDaysAgo: 200), now: now).0)
        #expect(!InstalledApps.advise(app(role: .work, lastUsedDaysAgo: 2), now: now).0)
        #expect(!InstalledApps.advise(app(role: .other, lastUsedDaysAgo: 10), now: now).0)
        #expect(!InstalledApps.advise(app(role: .system, lastUsedDaysAgo: nil), now: now).0)
    }

    @Test func largeFileFinderSkipsLibraryHiddenAndProjects() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.make("Movies/Trip/holiday.mov", bytes: 6_000_000)
        try box.make("Documents/notes.txt", bytes: 1_000)
        try box.make("Library/Caches/big.bin", bytes: 6_000_000)
        try box.make(".hidden/big.bin", bytes: 6_000_000)
        try box.make("builder/app/output/render.mp4", bytes: 6_000_000)
        let context = ScanContext(home: box.home, devRoots: [box.home.appendingPathComponent("builder")])
        let items = LargeFileFinder.find(in: context, threshold: 5_000_000)
        #expect(items.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["holiday.mov"], "\(items.map(\.path)) roots=\(LargeFileFinder.roots(in: context).map(\.lastPathComponent))")
        #expect(items.first?.safety == .review && items.first?.action == .trash && items.first?.recommended == false)
        #expect(items.first?.detail.hasPrefix("Video") == true)
    }

    @Test func mergeTreatsRelatedPathsAsOwned() {
        let app = CleanupItem(title: "Spotify", detail: "", path: "/Applications/Spotify.app", bytes: 900, category: .apps,
                              safety: .review, action: .trash, relatedPaths: ["/h/Library/Caches/com.spotify.client"])
        let cache = CleanupItem(title: "Cache", detail: "", path: "/h/Library/Caches/com.spotify.client", bytes: 600,
                                category: .appCaches, safety: .regenerable, action: .delete)
        let merged = Scanner.merge([(60, [app]), (20, [cache])])
        #expect(merged.map(\.title) == ["Spotify"])
    }

    @Test func relatedPathsStillPassTheGuard() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let cache = try box.make("Library/Caches/com.example.app/blob")
        let secret = try box.make("builder/app/release.jks")
        let main = try box.dir("Library/Application Support/com.example.app")
        let item = CleanupItem(title: "x", detail: "", path: main.path, bytes: 1, category: .apps, safety: .review, action: .delete,
                               relatedPaths: [cache.deletingLastPathComponent().path, secret.path])
        let outcome = Cleaner(home: box.home, log: ActivityLog(url: box.home.appendingPathComponent("a.jsonl"))).perform(item)
        #expect(!outcome.success)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }
}
