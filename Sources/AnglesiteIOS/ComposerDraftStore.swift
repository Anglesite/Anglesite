// Sources/AnglesiteIOS/ComposerDraftStore.swift
import Foundation
import AnglesiteCore

/// One in-progress or queued composition, as plain `Codable` state on disk — the iOS design's
/// §3 restore contract (current draft survives backgrounding/interruption) and §6/§7 offline
/// fallback (a send that failed retryably becomes a locally-queued draft with an explicit
/// "waiting for network" state, retried later). There is no git or working copy on the phone;
/// this file IS the local state.
public struct ComposerDraft: Codable, Equatable, Sendable {
    /// The site the draft belongs to (`AnglesitePackage.Marker.siteID`).
    public var siteID: UUID
    /// The content type's registry id (e.g. `note`, `article`).
    public var typeID: String
    /// The post's canonical URL when editing an existing post; `nil` for a new one.
    public var postURL: URL?
    /// The form's field values at capture time.
    public var values: [String: Value]
    /// The status the pending send should stamp (`draft` for Save, `published` for Publish);
    /// `nil` while merely composing (nothing queued yet).
    public var queuedStatus: String?

    /// Creates a draft snapshot.
    public init(
        siteID: UUID, typeID: String, postURL: URL? = nil,
        values: [String: Value], queuedStatus: String? = nil
    ) {
        self.siteID = siteID
        self.typeID = typeID
        self.postURL = postURL
        self.values = values
        self.queuedStatus = queuedStatus
    }

    /// A `Codable` mirror of `TypedContentEditor.FieldValue` (which is deliberately not
    /// `Codable` itself — its module keeps persistence concerns out of the editor seam).
    public indirect enum Value: Codable, Equatable, Sendable {
        case text(String)
        case flag(Bool)
        case date(Date?)
        case number(Double?)
        case list([String])
        case records([[String: Value]])

        /// Wraps an editor value for persistence.
        public init(_ value: TypedContentEditor.FieldValue) {
            switch value {
            case .text(let s): self = .text(s)
            case .flag(let b): self = .flag(b)
            case .date(let d): self = .date(d)
            case .number(let n): self = .number(n)
            case .list(let l): self = .list(l)
            case .records(let rows): self = .records(rows.map { $0.mapValues(Value.init) })
            }
        }

        /// The editor value this persisted one restores to.
        public var fieldValue: TypedContentEditor.FieldValue {
            switch self {
            case .text(let s): return .text(s)
            case .flag(let b): return .flag(b)
            case .date(let d): return .date(d)
            case .number(let n): return .number(n)
            case .list(let l): return .list(l)
            case .records(let rows): return .records(rows.map { $0.mapValues(\.fieldValue) })
            }
        }
    }

    /// Snapshot of a live editing session's values.
    public init(
        siteID: UUID, typeID: String, postURL: URL?,
        editorValues: TypedContentEditor.Values, fieldNames: [String], queuedStatus: String? = nil
    ) {
        var values: [String: Value] = [:]
        for name in fieldNames {
            if let value = editorValues[name] { values[name] = Value(value) }
        }
        self.init(
            siteID: siteID, typeID: typeID, postURL: postURL,
            values: values, queuedStatus: queuedStatus)
    }

    /// The editor values this draft restores to.
    public var editorValues: TypedContentEditor.Values {
        var out = TypedContentEditor.Values()
        for (name, value) in values { out[name] = value.fieldValue }
        return out
    }
}

/// Reads and writes the single per-site current draft under Application Support — one file per
/// site (`micropub-draft-<siteID>.json`), because the composer edits one post at a time and the
/// restore contract covers "any in-progress draft", singular (§3). Injectable directory so tests
/// point it at a scratch location.
public struct ComposerDraftStore: Sendable {
    private let directory: URL

    /// Creates a store rooted at `directory`, defaulting to the app's Application Support.
    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Anglesite", isDirectory: true)
    }

    private func fileURL(forSite siteID: UUID) -> URL {
        directory.appendingPathComponent("micropub-draft-\(siteID.uuidString).json")
    }

    /// Persists `draft` as its site's current draft, replacing any previous one.
    public func save(_ draft: ComposerDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: fileURL(forSite: draft.siteID), options: .atomic)
    }

    /// The site's current draft, or `nil` when none is stored (or the stored one no longer
    /// decodes — stale-format state restores as a fresh start, never a crash).
    public func load(forSite siteID: UUID) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: fileURL(forSite: siteID)) else { return nil }
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }

    /// Removes the site's current draft (after a successful send, or an explicit discard).
    public func clear(forSite siteID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(forSite: siteID))
    }
}
