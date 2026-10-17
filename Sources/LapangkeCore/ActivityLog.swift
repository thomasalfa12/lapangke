import Foundation

public struct ActivityEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var title: String
    public var path: String
    public var bytes: Int64
    public var success: Bool
    public var message: String

    public init(kind: String, title: String, path: String, bytes: Int64, success: Bool, message: String, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.title = title
        self.path = path
        self.bytes = bytes
        self.success = success
        self.message = message
    }
}

/// Jejak semua aksi (JSON Lines) di ~/Library/Application Support/Lapangke/activity.jsonl.
public struct ActivityLog: Sendable {
    public let url: URL

    public init(url: URL = AppPaths.activity) { self.url = url }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public func append(_ entry: ActivityEntry) {
        guard var data = try? Self.encoder.encode(entry) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    public func load(limit: Int = 500) -> [ActivityEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            try? decoder.decode(ActivityEntry.self, from: Data(line.utf8))
        }.reversed()
    }
}
