import Foundation

/// Canonical encode + atomic-write + decode-with-recovery for a single `Codable` value backed by
/// one file on disk.
///
/// Extracted per #1819 from 19 hand-rolled `*Store` types in this module that each repeated the
/// same encoder-configure / encode / atomic-write / decode sequence, with encoder settings (date
/// strategy, key ordering, pretty-print) drifting slightly between them. `CodableFileStore` is the
/// mechanical file-I/O primitive only — validation, actor isolation, and default-value policy stay
/// with each call site, since those vary by store (e.g. ``RedirectsStore`` validates before every
/// save; ``ProjectConventionsStore`` treats its file as a re-derivable cache).
///
/// Use ``json(fileURL:fileManager:outputFormatting:dateEncodingStrategy:dateDecodingStrategy:migrate:)``
/// or ``plist(fileURL:fileManager:outputFormat:migrate:)`` for the two formats already in use across
/// Core; the memberwise initializer accepts a custom `encode`/`decode` pair for anything else.
public struct CodableFileStore<Value: Codable & Sendable>: Sendable {
    /// Rewrites raw file bytes before they reach `decode`, for a format-version bump that changes
    /// the on-disk shape (e.g. `AnnotationStore`'s versioned wrapper). Runs only when a file
    /// exists; never sees a missing file.
    public typealias Migrate = @Sendable (Data) throws -> Data

    private let fileURL: URL
    private let fileManager: FileManager
    private let encode: @Sendable (Value) throws -> Data
    private let decode: @Sendable (Data) throws -> Value
    private let migrate: Migrate?

    /// The file this store reads and writes.
    public var url: URL { fileURL }

    /// Creates a store with a custom encode/decode pair. Prefer ``json(fileURL:fileManager:outputFormatting:dateEncodingStrategy:dateDecodingStrategy:migrate:)``
    /// or ``plist(fileURL:fileManager:outputFormat:migrate:)`` unless neither format fits.
    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encode: @escaping @Sendable (Value) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Value,
        migrate: Migrate? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encode = encode
        self.decode = decode
        self.migrate = migrate
    }

    /// Whether the backing file currently exists.
    public func exists() -> Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    /// Reads and decodes the file, or `nil` when it doesn't exist.
    ///
    /// - Throws: Whatever `Data(contentsOf:)`, `migrate`, or `decode` throw — a corrupt or
    ///   unreadable *existing* file is still an error here. Use ``loadOrDefault(_:)`` at call
    ///   sites where a decode failure should fall back to a default instead.
    public func load() throws -> Value? {
        guard exists() else { return nil }
        var data = try Data(contentsOf: fileURL)
        if let migrate { data = try migrate(data) }
        return try decode(data)
    }

    /// Reads and decodes the file, falling back to `default()` when it's missing, unreadable, or
    /// fails to decode (including a `migrate` failure). Never throws.
    ///
    /// Matches the recovery behavior several existing stores already hand-roll (e.g.
    /// `SiteConfigStore.load()`, `ProjectConventionsStore.load()`) for files whose fields are all
    /// optional, or that are re-derivable caches — a file written by a newer or older build, or a
    /// corrupted one, must never block the caller.
    public func loadOrDefault(_ default: @autoclosure () -> Value) -> Value {
        guard exists(), var data = try? Data(contentsOf: fileURL) else { return `default`() }
        if let migrate {
            guard let migrated = try? migrate(data) else { return `default`() }
            data = migrated
        }
        return (try? decode(data)) ?? `default`()
    }

    /// Encodes `value` and writes it atomically, creating the parent directory first if needed.
    public func save(_ value: Value) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension CodableFileStore {
    /// A store using the JSON encoding most of Core's git-tracked/state stores already use by
    /// hand: pretty-printed, sorted keys (stable, minimal diffs for git-tracked files), ISO 8601
    /// dates.
    public static func json(
        fileURL: URL,
        fileManager: FileManager = .default,
        outputFormatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys],
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .iso8601,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601,
        migrate: Migrate? = nil
    ) -> CodableFileStore<Value> {
        CodableFileStore(
            fileURL: fileURL,
            fileManager: fileManager,
            encode: { value in
                let encoder = JSONEncoder()
                encoder.outputFormatting = outputFormatting
                encoder.dateEncodingStrategy = dateEncodingStrategy
                return try encoder.encode(value)
            },
            decode: { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = dateDecodingStrategy
                return try decoder.decode(Value.self, from: data)
            },
            migrate: migrate
        )
    }

    /// A store using `PropertyListEncoder`/`PropertyListDecoder`, matching `SiteConfigStore`'s
    /// `settings.plist`.
    public static func plist(
        fileURL: URL,
        fileManager: FileManager = .default,
        outputFormat: PropertyListSerialization.PropertyListFormat = .xml,
        migrate: Migrate? = nil
    ) -> CodableFileStore<Value> {
        CodableFileStore(
            fileURL: fileURL,
            fileManager: fileManager,
            encode: { value in
                let encoder = PropertyListEncoder()
                encoder.outputFormat = outputFormat
                return try encoder.encode(value)
            },
            decode: { data in
                try PropertyListDecoder().decode(Value.self, from: data)
            },
            migrate: migrate
        )
    }
}
