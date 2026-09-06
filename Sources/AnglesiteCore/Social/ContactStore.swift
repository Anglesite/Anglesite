import Foundation

/// Per-site contact store persisted to `<configDirectory>/contacts.json` (#966) — app-owned
/// state that must never enter the site's git repo, alongside `chat-history.jsonl` and
/// `ActorProfileCache`'s file. A full-file JSON envelope (like `ActorProfileCache`), not
/// append-only JSONL (like `ChatHistoryStore`): contacts are edited and deleted, not just
/// appended.
public actor ContactStore {
    public static let filename = "contacts.json"

    private struct Envelope: Codable, Sendable { let contacts: [Contact] }

    private let store: CodableFileStore<Envelope>

    /// The file this store reads and writes.
    public var fileURL: URL { store.url }

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.store = CodableFileStore(
            fileURL: configDirectory.appendingPathComponent(Self.filename),
            fileManager: fileManager,
            encode: { value in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(value)
            },
            decode: { data in
                guard !data.isEmpty else { return Envelope(contacts: []) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(Envelope.self, from: data)
            }
        )
    }

    /// A missing file is the normal first-run state (`[]`, no error). A file that exists but
    /// fails to decode throws instead of discarding silently: unlike `ActorProfileCache` (a
    /// disposable, re-fetchable cache), a contact list is owner-curated data, and silently
    /// showing zero contacts risks the owner believing the list was lost and re-entering it.
    public func load() throws -> [Contact] {
        guard let envelope = try store.load() else { return [] }
        return envelope.contacts.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Adds a contact, replacing any existing entry with the same `me` identity (comparing via
    /// `normalizedIdentityKey(for:)`, so `https://x.example` and `https://x.example/` collide).
    public func add(_ contact: Contact) throws {
        var contacts = try load()
        contacts.removeAll {
            normalizedIdentityKey(for: $0.me) == normalizedIdentityKey(for: contact.me)
        }
        contacts.append(contact)
        try write(contacts)
    }

    /// Replaces the contact matching `contact.id`, wherever its `me` moved to — this is the
    /// rekey path for editing an existing entry's URL.
    public func update(_ contact: Contact) throws {
        var contacts = try load()
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
        try write(contacts)
    }

    public func remove(id: UUID) throws {
        var contacts = try load()
        contacts.removeAll { $0.id == id }
        try write(contacts)
    }

    /// Forward-looking hook for #963's authenticated-read allowlist — not called from anywhere
    /// in this feature, but the store is the source of truth #963 will read from.
    public func knownMeURLs() throws -> Set<String> {
        Set(try load().map { normalizedIdentityKey(for: $0.me) })
    }

    private func write(_ contacts: [Contact]) throws {
        try store.save(Envelope(contacts: contacts))
    }
}
