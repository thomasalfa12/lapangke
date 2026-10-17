import Foundation
import Testing
@testable import LapangkeCore

/// Home palsu di folder sementara supaya tidak ada satu pun file asli yang tersentuh.
struct Sandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lapangke-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @discardableResult
    func make(_ relative: String, bytes: Int = 4096) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func dir(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite struct SafetyGuardTests {
    @Test func allowsRegenerableCacheInsideHome() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let derived = try box.dir("Library/Developer/Xcode/DerivedData")
        try SafetyGuard(home: box.home).validate(path: derived.path)
    }

    @Test func refusesContainersAndShallowPaths() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let guardrail = SafetyGuard(home: box.home)
        for relative in ["Library", "Library/Caches", "Library/Developer/Xcode", ".gradle", "Downloads", "Documents"] {
            let url = try box.dir(relative)
            #expect(throws: GuardError.self) { try guardrail.validate(path: url.path) }
        }
    }

    @Test func refusesSecretsAndCredentials() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let guardrail = SafetyGuard(home: box.home)
        for relative in ["builder/app/ourbooth-release.jks", "builder/app/release.keystore", "builder/web/.env.local",
                         ".ssh/id_ed25519", "Library/Keychains/login.keychain-db", ".claude/projects/x/memory/a.md",
                         "Library/Mobile Documents/com~apple~CloudDocs/a.txt"] {
            let url = try box.make(relative)
            #expect(throws: GuardError.self, "\(relative) harus dilindungi") { try guardrail.validate(path: url.path) }
        }
    }

    @Test func refusesGitRepositories() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let repo = try box.dir("builder/project")
        _ = try box.dir("builder/project/.git")
        #expect(throws: GuardError.isRepository(repo.path)) { try SafetyGuard(home: box.home).validate(path: repo.path) }
        try SafetyGuard(home: box.home).validate(path: repo.path, allowRepository: true)
    }

    @Test func refusesPathsOutsideHomeAndTraversal() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let guardrail = SafetyGuard(home: box.home)
        #expect(throws: GuardError.self) { try guardrail.validate(path: "/System/Library/CoreServices") }
        #expect(throws: GuardError.self) { try guardrail.validate(path: box.home.path + "/Library/Caches/../../..") }
        #expect(throws: GuardError.self) { try guardrail.validate(path: "relative/path") }
    }

    @Test func symlinkIsRemovableWithoutTouchingTarget() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let target = try box.make("Documents/important.txt")
        let link = box.home.appendingPathComponent("builder/link-to-docs")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        try SafetyGuard(home: box.home).validate(path: link.path)
    }

    @Test func manualAndProtectedItemsAreNeverExecuted() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let url = try box.dir("Library/Developer/Xcode/DerivedData")
        let guardrail = SafetyGuard(home: box.home)
        let keep = CleanupItem(title: "x", detail: "", path: url.path, bytes: 1, category: .xcode, safety: .keep, action: .delete)
        let manual = CleanupItem(title: "x", detail: "", path: url.path, bytes: 1, category: .xcode, safety: .regenerable, action: .manual(instructions: ""))
        let badUDID = CleanupItem(title: "x", detail: "", path: url.path, bytes: 1, category: .simulators, safety: .regenerable, action: .simulatorErase(udid: "; rm -rf ~"))
        #expect(throws: GuardError.self) { try guardrail.validate(keep) }
        #expect(throws: GuardError.self) { try guardrail.validate(manual) }
        #expect(throws: GuardError.self) { try guardrail.validate(badUDID) }
    }

    @Test func recommendationRequiresSafeAutomaticAction() {
        let review = CleanupItem(title: "x", detail: "", path: "/x", bytes: 1, category: .personal, safety: .review, action: .trash, recommended: true)
        let manual = CleanupItem(title: "x", detail: "", path: "/x", bytes: 1, category: .system, safety: .regenerable, action: .manual(instructions: ""), recommended: true)
        #expect(!review.recommended)
        #expect(!manual.recommended)
    }
}
