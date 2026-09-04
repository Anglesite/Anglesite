import Foundation

/// Ledger for ``StandardSiteGraphPublishCommand``, mirroring ``StandardSitePublishLog``'s shape.
/// Lives in the site's `Config/` directory (app-owned state, not the site's git repo). Keyed on
/// `sourceFile` (a blogroll entry's content-file path), not `path`, since blogroll entries have
/// no routed canonical page the way a post's `path` does.
public struct StandardSiteGraphPublishLog: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceFile: String
        public let uri: String
        public let lastPublishedAt: Date

        public init(sourceFile: String, uri: String, lastPublishedAt: Date) {
            self.sourceFile = sourceFile
            self.uri = uri
            self.lastPublishedAt = lastPublishedAt
        }
    }

    public static let filename = "standard-site-graph-publish.json"
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    private struct Envelope: Codable { let entries: [Entry] }

    public static func load(from configDirectory: URL) -> StandardSiteGraphPublishLog? {
        guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(filename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return StandardSiteGraphPublishLog(entries: envelope.entries)
    }

    public func save(to configDirectory: URL) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(entries: entries))
        try data.write(to: configDirectory.appendingPathComponent(Self.filename), options: .atomic)
    }

    public mutating func record(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.sourceFile == entry.sourceFile }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }
}
