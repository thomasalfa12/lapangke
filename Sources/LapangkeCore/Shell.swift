import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

private final class DataBuffer: @unchecked Sendable { var data = Data() }
private final class ProcessHandle: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

public enum Shell {
    /// Menjalankan program tanpa shell (argumen tidak di-interpretasi), dengan batas waktu.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 120
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let errBuffer = DataBuffer()
        let errDone = DispatchSemaphore(value: 0)
        let errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            errBuffer.data = errHandle.readDataToEndOfFile()
            errDone.signal()
        }
        let handle = ProcessHandle(process)
        let watchdog = DispatchWorkItem {
            if handle.process.isRunning { handle.process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        errDone.wait()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBuffer.data, as: UTF8.self)
        )
    }
}

/// Lokasi Xcode & pemanggil tool developer. `xcode-select` di Mac ini bisa menunjuk ke
/// CommandLineTools (tanpa `simctl`), jadi Xcode.app dicari sendiri dan dipasang lewat DEVELOPER_DIR.
public enum Toolchain {
    public static let developerDir: String? = {
        let fm = FileManager.default
        let selected = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected.hasSuffix(".app/Contents/Developer"), fm.fileExists(atPath: selected) { return selected }
        let apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .sorted { lhs, rhs in lhs == "Xcode.app" || (rhs != "Xcode.app" && lhs < rhs) }
        for app in apps {
            let path = "/Applications/\(app)/Contents/Developer"
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }()

    private static var developerEnvironment: [String: String] {
        developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:]
    }

    public static func simctl(_ arguments: [String], timeout: TimeInterval = 120) -> ShellResult? {
        guard developerDir != nil else { return nil }
        return Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, environment: developerEnvironment, timeout: timeout)
    }

    public static func git(_ arguments: [String], in directory: URL, timeout: TimeInterval = 60) -> ShellResult {
        Shell.run("/usr/bin/git", ["-C", directory.path] + arguments, environment: developerEnvironment, timeout: timeout)
    }

    public static func isRunning(_ pattern: String) -> Bool {
        Shell.run("/usr/bin/pgrep", ["-f", pattern], timeout: 10).ok
    }

    public static func isAppRunning(bundleName: String) -> Bool {
        Shell.run("/usr/bin/pgrep", ["-x", bundleName], timeout: 10).ok
    }
}
