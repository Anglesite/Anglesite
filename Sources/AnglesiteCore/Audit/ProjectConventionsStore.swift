// Sources/AnglesiteCore/Audit/ProjectConventionsStore.swift
import Foundation

/// Per-site persistence for `ProjectConventions`, at `<configDirectory>/conventions.json`.
/// Follows `ChatHistoryStore`'s precedent: `Config/` is app-owned and not git-tracked. Unlike
/// `ChatHistoryStore` (append-only JSONL), this is a single whole-value JSON file — there's one
/// current `ProjectConventions`, not a history of them.
public actor ProjectConventionsStore {
    private let store: CodableFileStore<ProjectConventions>

    /// Points the store at `<configDirectory>/conventions.json`. Encoding uses sorted keys
    /// (deliberately *not* `.prettyPrinted`, unlike `CodableFileStore.json`'s default — taking
    /// that default would reformat every existing `conventions.json` on next write) and ISO 8601
    /// dates so successive saves of equal values are byte-identical (stable for change-detection
    /// and debugging); `fileManager` is injectable for tests.
    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.store = .json(
            fileURL: configDirectory.appendingPathComponent("conventions.json"),
            fileManager: fileManager,
            outputFormatting: [.sortedKeys]
        )
    }

    /// The stored conventions, or `nil` when the file is absent or undecodable. Both collapse
    /// to `nil` deliberately: conventions are a derived cache, so a missing or stale-schema file
    /// just means "re-extract from the site source" — never an error worth surfacing.
    public func load() -> ProjectConventions? {
        try? store.load()
    }

    /// Persists `conventions` atomically, creating the `Config/` directory if needed. Failures
    /// are swallowed for the same reason ``load()`` returns `nil`: the file is a re-derivable
    /// cache, and a failed write must never break the feature that triggered the extraction.
    public func save(_ conventions: ProjectConventions) {
        try? store.save(conventions)
    }
}
