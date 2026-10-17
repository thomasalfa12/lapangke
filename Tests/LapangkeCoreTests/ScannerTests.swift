import Foundation
import Testing
@testable import LapangkeCore

@Suite struct ScannerTests {
    @Test func sizeCalculatorCountsFilesAndSkipsSymlinks() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.make("data/a.bin", bytes: 100_000)
        try box.make("data/sub/b.bin", bytes: 50_000)
        let outside = try box.make("outside/big.bin", bytes: 500_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("data/link"), withDestinationURL: outside)
        let size = SizeCalculator.measure(box.home.appendingPathComponent("data"))
        #expect(size.files == 3) // 2 file + symlink-nya sendiri, tanpa isi tujuannya
        #expect(size.logicalBytes < 200_000)
        #expect(size.bytes >= 150_000)
    }

    @Test func mergeKeepsHigherPriorityAndDropsOverlaps() {
        func item(_ path: String, _ bytes: Int64) -> CleanupItem {
            CleanupItem(title: path, detail: "", path: path, bytes: bytes, category: .appCaches, safety: .regenerable, action: .delete)
        }
        let merged = Scanner.merge([
            (20, [item("/h/Library/Caches/Google", 3_000)]),
            (50, [item("/h/Library/Caches/Google/Chrome", 2_900), item("/h/Library/Caches/Homebrew", 100)]),
        ])
        #expect(merged.map(\.path) == ["/h/Library/Caches/Google/Chrome", "/h/Library/Caches/Homebrew"])
    }

    @Test func pathAncestryUsesComponentBoundaries() {
        #expect(PathTools.isSameOrAncestor("/a/b", of: "/a/b/c"))
        #expect(!PathTools.isSameOrAncestor("/a/b", of: "/a/bc"))
        #expect(PathTools.isSameOrAncestor("/a/b", of: "/a/b"))
    }

    @Test func versionComparison() {
        #expect(PathTools.compareVersions("27.0.1", "27.0") == .orderedDescending)
        #expect(PathTools.compareVersions("9.5.0", "10.0") == .orderedAscending)
        #expect(PathTools.compareVersions("8.13", "8.13.0") == .orderedSame)
    }

    @Test func parsesDeviceSupportNames() {
        let modern = DeviceSupportProvider.parse("iPad13,4 27.0.1 (24A446)")
        #expect(modern?.model == "iPad13,4")
        #expect(modern?.version == "27.0.1")
        let legacy = DeviceSupportProvider.parse("17.5 (21F79)")
        #expect(legacy?.model == "")
        #expect(legacy?.version == "17.5")
    }

    @Test func parsesEditorExtensionNames() {
        let platform = EditorExtensionProvider.parse("kilocode.kilo-code-7.2.20-darwin-arm64")
        #expect(platform?.id == "kilocode.kilo-code")
        #expect(platform?.version == "7.2.20")
        let plain = EditorExtensionProvider.parse("svelte.svelte-vscode-110.3.1")
        #expect(plain?.id == "svelte.svelte-vscode")
    }

    @Test func runtimeNames() {
        #expect(SimulatorProvider.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-0") == "iOS 27.0")
    }

    @Test func projectIndexFindsUsedGradleAndToolchainVersions() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.5.0-bin.zip\n"
            .write(to: try box.make("builder/app/gradle/wrapper/gradle-wrapper.properties"), atomically: true, encoding: .utf8)
        try "android { compileSdk = 36\n ndkVersion = \"29.0.14206865\" }"
            .write(to: try box.make("builder/app/app/build.gradle.kts"), atomically: true, encoding: .utf8)
        try "[toolchain]\nchannel = \"1.97.1\"\n".write(to: try box.make("builder/tauri/rust-toolchain.toml"), atomically: true, encoding: .utf8)
        _ = try box.make("builder/tauri/Cargo.toml")
        let index = ProjectIndex.build(roots: [box.home.appendingPathComponent("builder")])
        #expect(index.gradleDistributions == ["gradle-9.5.0-bin"])
        #expect(index.gradleVersions == ["9.5.0"])
        #expect(index.compileSdks == [36])
        #expect(index.buildFileText.contains("29.0.14206865"))
        #expect(index.rustToolchains == ["1.97.1"])
    }

    @Test func gradleProviderKeepsVersionsInUse() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.make(".gradle/caches/9.5.0/a.bin", bytes: 11_000_000)
        try box.make(".gradle/caches/8.9/a.bin", bytes: 11_000_000)
        var index = ProjectIndex.empty
        index.gradleDistributions = ["gradle-9.5.0-bin"]
        let context = ScanContext(home: box.home, devRoots: [], projects: index)
        let items = await GradleProvider().items(in: context)
        let used = try #require(items.first { $0.path.hasSuffix("9.5.0") })
        let unused = try #require(items.first { $0.path.hasSuffix("8.9") })
        #expect(used.safety == .costly && !used.recommended)
        #expect(unused.safety == .regenerable && unused.recommended)
    }

    @Test func projectArtifactsComeOnlyFromGitIgnoredFolders() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let repo = box.home.appendingPathComponent("builder/web")
        try box.make("builder/web/package.json")
        try box.make("builder/web/src/index.ts")
        try box.make("builder/web/node_modules/react/index.js", bytes: 25_000_000)
        try box.make("builder/web/.next/cache/a.bin", bytes: 25_000_000)
        try box.make("builder/web/output/run-1/shot.png", bytes: 120_000_000)
        try box.make("builder/web/vendor-sdk/src/main.c", bytes: 150_000_000) // diabaikan git, tapi berisi kode
        try box.make("builder/web/secrets/key.bin", bytes: 150_000_000)
        try "node_modules/\n.next/\noutput/\nvendor-sdk/\nsecrets/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(Toolchain.git(["init", "-q"], in: repo).ok)

        let index = ProjectIndex.build(roots: [box.home.appendingPathComponent("builder")])
        let context = ScanContext(home: box.home, devRoots: [], projects: index)
        let items = await ProjectArtifactProvider().items(in: context)
        let names = Set(items.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        #expect(names.contains("node_modules"))
        #expect(names.contains(".next"))
        #expect(names.contains("output"))
        #expect(!names.contains("src"))
        #expect(!names.contains("vendor-sdk"))
        #expect(!names.contains("secrets"))
        let output = try #require(items.first { $0.path.hasSuffix("/output") })
        #expect(output.safety == .review && output.action == .trash && !output.recommended)
    }
}

@Suite struct RelocationTests {
    @Test func zshenvBlockIsIdempotentAndPreservesUserContent() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let zshenv = box.home.appendingPathComponent(".zshenv")
        try "export PATH=\"$HOME/bin:$PATH\"\n".write(to: zshenv, atomically: true, encoding: .utf8)
        let service = RelocationService(home: box.home, defaultsDomain: "id.thomasalfa.lapangke.tests")
        try service.writeExports([.gradleHome: "/Volumes/Dev/Lapangke Dev/gradle.noindex"])
        try service.writeExports([.gradleHome: "/Volumes/Dev/Lapangke Dev/gradle.noindex", .npmCache: "/Volumes/Dev/Lapangke Dev/npm-cache.noindex"])
        let text = try String(contentsOf: zshenv, encoding: .utf8)
        #expect(text.hasPrefix("export PATH=\"$HOME/bin:$PATH\"\n"))
        #expect(text.components(separatedBy: RelocationService.beginMarker).count == 2)
        #expect(text.contains("if [ -d \"/Volumes/Dev/Lapangke Dev\" ]; then"))
        #expect(service.managedExports() == [.gradleHome: "/Volumes/Dev/Lapangke Dev/gradle.noindex", .npmCache: "/Volumes/Dev/Lapangke Dev/npm-cache.noindex"])
        try service.writeExports([:])
        #expect(try String(contentsOf: zshenv, encoding: .utf8) == "export PATH=\"$HOME/bin:$PATH\"\n")
    }
}

@Suite struct OffloadTests {
    @Test func offloadCopiesVerifiesLinksAndRestores() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let volumeRoot = try box.dir("FakeSSD")
        try box.make("builder/app/output/run-1/a.png", bytes: 300_000)
        try box.make("builder/app/output/run-2/b.png", bytes: 200_000)
        let source = box.home.appendingPathComponent("builder/app/output")
        let service = OffloadService(home: box.home, storeURL: box.home.appendingPathComponent("offloads.json"),
                                     log: ActivityLog(url: box.home.appendingPathComponent("activity.jsonl")))
        let volume = VolumeInfo(name: "FakeSSD", mountPath: volumeRoot.path, uuid: "TEST", formatName: "APFS", fsType: "apfs",
                                isInternal: false, isEjectable: true, total: 10 * GB, free: 10 * GB, busProtocol: "USB",
                                solidState: true, ownersEnabled: true, encrypted: true, smart: nil, deviceIdentifier: nil)
        let item = CleanupItem(title: "output", detail: "", path: source.path, bytes: 500_000, category: .projects,
                               safety: .review, action: .trash, offloadable: true)

        let record = try await service.offload(item, to: volume, symlinkBack: true)
        #expect(PathTools.isSymlink(source.path))
        #expect(FileManager.default.fileExists(atPath: record.destinationPath + "/run-1/a.png"))
        #expect(FileManager.default.fileExists(atPath: source.path + "/run-2/b.png")) // lewat symlink
        #expect(service.records().count == 1)
        #expect(FileManager.default.fileExists(atPath: volumeRoot.path + "/Lapangke Offload/manifest.json"))

        try await service.restore(record)
        #expect(!PathTools.isSymlink(source.path))
        #expect(FileManager.default.fileExists(atPath: source.path + "/run-1/a.png"))
        #expect(!FileManager.default.fileExists(atPath: record.destinationPath))
        #expect(service.records().isEmpty)
    }

    @Test func offloadRefusesDevDataOnExFAT() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.make("builder/app/output/a.png")
        let volume = VolumeInfo(name: "Stick", mountPath: try box.dir("Stick").path, uuid: "X", formatName: "ExFAT", fsType: "exfat",
                                isInternal: false, isEjectable: true, total: GB, free: GB, busProtocol: "USB", solidState: true,
                                ownersEnabled: nil, encrypted: false, smart: nil, deviceIdentifier: nil)
        let item = CleanupItem(title: "output", detail: "", path: box.home.appendingPathComponent("builder/app/output").path,
                               bytes: 1, category: .projects, safety: .review, action: .trash)
        let service = OffloadService(home: box.home, storeURL: box.home.appendingPathComponent("o.json"),
                                     log: ActivityLog(url: box.home.appendingPathComponent("a.jsonl")))
        await #expect(throws: OffloadError.self) { try await service.offload(item, to: volume, symlinkBack: false) }
    }
}
