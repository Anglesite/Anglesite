// Sources/AnglesiteCore/Experiment/ExperimentHistoryStore.swift
import Foundation

/// Per-site record of concluded A/B experiments, at `<configDirectory>/experiment-history.json`
/// (#1270 slice 6). Follows `ProjectConventionsStore`'s precedent (`Config/` is app-owned, not
/// git-tracked) rather than `ChatHistoryStore`'s JSONL shape: a conclude is a rare, one-owner-click
/// event, not a firehose, so the whole history is one JSON array, loaded/rewritten wholesale on
/// each append rather than appended byte-by-byte.
///
/// This is the *observed* half of an experiment's lifecycle — what got learned and decided — kept
/// deliberately separate from `DomainConfig.Experiments`' git-canonical *declared intent* (design
/// doc §2, "Why git-canonical"): a concluded experiment is removed from `anglesite.json` and its
/// outcome appended here instead, so `Source/` never accumulates a growing pile of dead config.
public actor ExperimentHistoryStore {
    /// One concluded experiment's outcome.
    public struct Outcome: Sendable, Codable, Equatable {
        /// What the owner chose to do about the variant, per design doc §5 — "keep" and
        /// "discard" are the same file operation (the variant is removed either way), differing
        /// only in what this records and how the app phrases it back to the owner.
        public enum Decision: String, Sendable, Codable, Equatable {
            case promote, keep, discard
        }

        public let experimentID: String
        public let name: String
        public let decision: Decision
        public let variantName: String
        public let controlVisitors: Int
        public let controlConversions: Int
        public let variantVisitors: Int
        public let variantConversions: Int
        /// The declared experiment's `startedAt`, carried through for the record (`nil` if it was
        /// somehow concluded without ever having a start date).
        public let startedAt: String?
        /// ISO date the experiment concluded.
        public let concludedAt: String

        public init(
            experimentID: String, name: String, decision: Decision, variantName: String,
            controlVisitors: Int, controlConversions: Int, variantVisitors: Int, variantConversions: Int,
            startedAt: String?, concludedAt: String
        ) {
            self.experimentID = experimentID
            self.name = name
            self.decision = decision
            self.variantName = variantName
            self.controlVisitors = controlVisitors
            self.controlConversions = controlConversions
            self.variantVisitors = variantVisitors
            self.variantConversions = variantConversions
            self.startedAt = startedAt
            self.concludedAt = concludedAt
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Points the store at `<configDirectory>/experiment-history.json`. `fileManager` is
    /// injectable for tests.
    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("experiment-history.json")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Every recorded outcome, oldest first. Returns `[]` when the file is missing or fails to
    /// decode — a missing/corrupt history is never worth failing a caller over, matching
    /// `ProjectConventionsStore.load()`'s "derived/best-effort" tolerance.
    public func load() -> [Outcome] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([Outcome].self, from: data)) ?? []
    }

    /// Appends one outcome, creating the `Config/` directory and the file if needed. Best-effort:
    /// a failed write is swallowed, same as `ProjectConventionsStore.save(_:)` — losing a history
    /// record must never be treated as a failure of the conclude action that already succeeded
    /// (the git-side promote/discard and the `anglesite.json` update are the parts that matter).
    public func append(_ outcome: Outcome) {
        var all = load()
        all.append(outcome)
        guard let data = try? encoder.encode(all) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
