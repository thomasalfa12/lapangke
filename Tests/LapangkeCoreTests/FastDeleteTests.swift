import Foundation
import Testing
@testable import LapangkeCore

@Suite struct FastDeleteTests {
    @Test func removesTreeReportsProgressAndKeepsSymlinkTargets() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        for index in 0..<40 { try box.make("Library/Caches/big/sub\(index % 4)/file\(index).bin", bytes: 64_000) }
        let outside = try box.make("Documents/keep.txt", bytes: 10_000)
        let root = box.home.appendingPathComponent("Library/Caches/big")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-documents"), withDestinationURL: outside.deletingLastPathComponent())

        var reports: [Int64] = []
        try FastDelete.remove(root.path) { reports.append($0) }

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: outside.path), "target symlink di luar folder tidak boleh ikut terhapus")
        #expect(reports.last.map { $0 >= 40 * 64_000 } == true)
        #expect(reports == reports.sorted(), "progres tidak boleh mundur")
    }

    @Test func cleanerReportsProgressAndStopsAfterCurrentItem() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        var items: [CleanupItem] = []
        for name in ["a", "b", "c"] {
            try box.make("Library/Caches/\(name)/blob.bin", bytes: 200_000)
            items.append(CleanupItem(title: name, detail: "", path: box.home.appendingPathComponent("Library/Caches/\(name)").path,
                                     bytes: 200_000, category: .appCaches, safety: .regenerable, action: .delete))
        }
        final class Box: @unchecked Sendable { var states: [CleanupProgress] = [] }
        let seen = Box()
        let stop = StopFlag()
        let cleaner = Cleaner(home: box.home, log: ActivityLog(url: box.home.appendingPathComponent("a.jsonl")))
        let outcomes = await cleaner.run(items, stop: stop) { state in
            seen.states.append(state)
            // Minta berhenti saat item pertama berjalan: item kedua & ketiga tidak boleh disentuh.
            if state.itemIndex == 0 { stop.set() }
        }
        #expect(outcomes.count == 1)
        #expect(!FileManager.default.fileExists(atPath: items[0].path))
        #expect(FileManager.default.fileExists(atPath: items[1].path))
        #expect(seen.states.contains { $0.phase == .deleting })
        #expect(seen.states.last?.processed == 200_000)
        #expect(seen.states.last?.total == 600_000)
    }
}

@Suite struct TreemapTests {
    @Test func areasAreProportionalAndTilesStayInside() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [120, 16, 11, 6, 3, 2.6, 0.5, 0]
        let rects = Treemap.squarify(values, in: bounds)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            let expected = value / total * Double(bounds.width * bounds.height)
            #expect(abs(Double(rect.width * rect.height) - expected) < 1, "luas \(value)")
            if value > 0 { #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect)) }
        }
        #expect(rects.last == .zero)
        // Tidak ada dua kotak yang saling tumpang tindih.
        for i in rects.indices where values[i] > 0 {
            for j in rects.indices where j > i && values[j] > 0 {
                #expect(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height < 0.5)
            }
        }
    }

    @Test func mapperBuildsThreeLevels() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.make("a/b/c/d/file.bin", bytes: 6_000_000)
        try box.make("a/top.bin", bytes: 6_000_000)
        let root = StorageMapper.mapTree(box.home)
        let a = try #require(root.children?.first { $0.name == "a" }, "\(root.children?.map { "\($0.name)=\($0.bytes)" } ?? []) root=\(root.bytes) path=\(root.path)")
        let b = try #require(a.children?.first { $0.name == "b" })
        let c = try #require(b.children?.first { $0.name == "c" })
        #expect(a.bytes >= 12_000_000)
        #expect(c.bytes >= 6_000_000)
        #expect(c.children == nil, "berhenti di level 3")
        #expect(a.children?.contains { $0.name == "top.bin" } == false, "file di level 2 bukan node")
    }
}
