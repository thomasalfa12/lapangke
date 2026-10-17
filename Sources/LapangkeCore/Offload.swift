import Foundation

public struct OffloadRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var originalPath: String
    public var destinationPath: String
    public var volumeUUID: String?
    public var volumeName: String
    public var bytes: Int64
    public var date: Date
    /// Path asli diganti symlink ke SSD (tool yang mencari di lokasi lama tetap menemukannya).
    public var symlinked: Bool
}

public enum OffloadStatus: Sendable, Equatable {
    case available
    case volumeMissing
    case destinationMissing

    public var label: String {
        switch self {
        case .available: "Tersedia di SSD"
        case .volumeMissing: "SSD tidak terpasang"
        case .destinationMissing: "Folder di SSD hilang"
        }
    }
}

public enum OffloadError: LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)
    case unsupportedFormat(String)
    case sourceMissing
    case volumeMissing
    case originalOccupied(String)
    case copyFailed(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notEnoughSpace(needed, available): "Ruang SSD kurang: perlu \(needed.bytesText), tersedia \(available.bytesText)."
        case let .unsupportedFormat(format): "Format \(format) tidak aman untuk data dev (symlink & izin file hilang). Format SSD ke APFS, atau pindahkan hanya foto/video."
        case .sourceMissing: "Data asal sudah tidak ada."
        case .volumeMissing: "SSD tidak terpasang."
        case let .originalOccupied(path): "Lokasi asal sudah berisi data baru: \(path.abbreviatingHome)"
        case let .copyFailed(reason): "Gagal menyalin: \(reason)"
        case let .verifyFailed(reason): "Verifikasi salinan gagal (data asal TIDAK dihapus): \(reason)"
        }
    }
}

/// Memindahkan data ke SSD eksternal dengan aman: salin (`ditto`), verifikasi jumlah & ukuran file,
/// baru hapus asalnya. Setiap pemindahan tercatat di Mac dan di SSD (`Lapangke Offload/manifest.json`).
public struct OffloadService: Sendable {
    public var storeURL: URL
    public var guardrail: SafetyGuard
    public var log: ActivityLog
    public var home: URL

    public static let folderName = "Lapangke Offload"

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        storeURL: URL = AppPaths.offloads,
        log: ActivityLog = ActivityLog()
    ) {
        self.home = home
        self.storeURL = storeURL
        guardrail = SafetyGuard(home: home)
        self.log = log
    }

    // MARK: Catatan

    public func records() -> [OffloadRecord] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([OffloadRecord].self, from: data)) ?? []
    }

    func save(_ records: [OffloadRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) { try? data.write(to: storeURL, options: .atomic) }
    }

    func writeManifest(on volumeRoot: URL, records: [OffloadRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = volumeRoot.appendingPathComponent(Self.folderName).appendingPathComponent("manifest.json")
        if let data = try? encoder.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    public func status(of record: OffloadRecord) -> OffloadStatus {
        let volumeRoot = Self.volumeRoot(of: record.destinationPath)
        guard PathTools.isDirectory(volumeRoot) else { return .volumeMissing }
        return PathTools.exists(record.destinationPath) ? .available : .destinationMissing
    }

    static func volumeRoot(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return "/" }
        return "/Volumes/\(parts[1])"
    }

    // MARK: Pindah ke SSD

    public func offload(
        _ item: CleanupItem,
        to volume: VolumeInfo,
        symlinkBack: Bool,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> OffloadRecord {
        let source = URL(fileURLWithPath: item.path)
        guard PathTools.exists(source.path), !PathTools.isSymlink(source.path) else { throw OffloadError.sourceMissing }
        try guardrail.validate(path: source.path)
        guard PathTools.isDirectory(volume.mountPath) else { throw OffloadError.volumeMissing }
        if !volume.supportsDevWork, item.category != .personal { throw OffloadError.unsupportedFormat(volume.formatName) }

        let measured = SizeCalculator.measure(source)
        let needed = Int64(Double(measured.logicalBytes) * 1.05) + 50 * MB
        let free = DiskInspector.freeSpace(home: URL(fileURLWithPath: volume.mountPath)).available
        guard free >= needed || volume.free >= needed else {
            throw OffloadError.notEnoughSpace(needed: needed, available: max(free, volume.free))
        }

        let destination = uniqueDestination(for: source, on: URL(fileURLWithPath: volume.mountPath))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Salin dengan ditto (metadata, xattr, symlink ikut). Di exFAT, xattr dilewati agar tidak ada file "._*".
        var arguments = [source.path, destination.path]
        if !volume.supportsDevWork { arguments.insert(contentsOf: ["--norsrc", "--noextattr", "--noacl"], at: 0) }
        let dittoArguments = arguments
        let copyTask = Task.detached { Shell.run("/usr/bin/ditto", dittoArguments, timeout: 6 * 3600) }
        let monitor = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                progress(SizeCalculator.measure(destination).logicalBytes)
            }
        }
        let copy = await copyTask.value
        monitor.cancel()
        guard copy.ok else {
            try? FileManager.default.removeItem(at: destination)
            throw OffloadError.copyFailed(copy.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let copied = SizeCalculator.measure(destination, ignoreAppleDouble: !volume.supportsDevWork)
        let original = SizeCalculator.measure(source)
        guard copied.files == original.files, copied.logicalBytes == original.logicalBytes else {
            throw OffloadError.verifyFailed("asal \(original.files) file/\(original.logicalBytes.bytesText), salinan \(copied.files) file/\(copied.logicalBytes.bytesText). Salinan disimpan di \(destination.path).")
        }

        try FileManager.default.removeItem(at: source)
        if symlinkBack {
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
        }

        let record = OffloadRecord(
            id: UUID(), title: item.title, originalPath: source.path, destinationPath: destination.path,
            volumeUUID: volume.uuid, volumeName: volume.name, bytes: original.bytes, date: Date(), symlinked: symlinkBack
        )
        var all = records()
        all.append(record)
        save(all)
        writeManifest(on: URL(fileURLWithPath: volume.mountPath), records: all.filter { $0.volumeUUID == volume.uuid })
        log.append(ActivityEntry(kind: "Pindah ke SSD", title: item.title, path: source.path, bytes: original.bytes,
                                 success: true, message: "→ \(destination.path)"))
        return record
    }

    // MARK: Kembalikan

    public func restore(_ record: OffloadRecord) async throws {
        guard status(of: record) == .available else { throw OffloadError.volumeMissing }
        let original = URL(fileURLWithPath: record.originalPath)
        let destination = URL(fileURLWithPath: record.destinationPath)
        if PathTools.isSymlink(original.path) {
            try FileManager.default.removeItem(at: original)
        } else if PathTools.exists(original.path) {
            throw OffloadError.originalOccupied(original.path)
        }
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = await Task.detached { Shell.run("/usr/bin/ditto", [destination.path, original.path], timeout: 6 * 3600) }.value
        guard copy.ok else { throw OffloadError.copyFailed(copy.stderr) }
        let back = SizeCalculator.measure(original)
        let source = SizeCalculator.measure(destination, ignoreAppleDouble: true)
        guard back.files == source.files, back.logicalBytes == source.logicalBytes else {
            throw OffloadError.verifyFailed("salinan di Mac tidak sama dengan di SSD; data di SSD tidak dihapus.")
        }
        try FileManager.default.removeItem(at: destination)
        var all = records()
        all.removeAll { $0.id == record.id }
        save(all)
        writeManifest(on: URL(fileURLWithPath: Self.volumeRoot(of: record.destinationPath)), records: all.filter { $0.volumeUUID == record.volumeUUID })
        log.append(ActivityEntry(kind: "Kembalikan dari SSD", title: record.title, path: record.originalPath, bytes: record.bytes,
                                 success: true, message: "← \(record.destinationPath)"))
    }

    /// Hapus catatan tanpa menyentuh file (mis. data di SSD sudah dihapus manual).
    public func forget(_ record: OffloadRecord) {
        var all = records()
        all.removeAll { $0.id == record.id }
        save(all)
    }

    func uniqueDestination(for source: URL, on volume: URL) -> URL {
        let relative = source.path.hasPrefix(home.path + "/") ? String(source.path.dropFirst(home.path.count + 1)) : source.lastPathComponent
        var destination = volume.appendingPathComponent(Self.folderName).appendingPathComponent(relative)
        var counter = 2
        while PathTools.exists(destination.path) {
            destination = volume.appendingPathComponent(Self.folderName).appendingPathComponent("\(relative) (\(counter))")
            counter += 1
        }
        return destination
    }
}
