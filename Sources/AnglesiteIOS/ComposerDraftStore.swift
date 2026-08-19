// Sources/AnglesiteIOS/ComposerDraftStore.swift
import Foundation
import CryptoKit
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
    /// The visibility selection to restore alongside the queued send — `nil` for a not-yet-set
    /// composition (defaults to public when absent, matching `MicropubPostVisibility`'s own
    /// absent-defaults-to-public rule).
    public var visibility: String?
    /// The compare-and-swap baseline for a queued *update* — the `{type, properties}` JSON of
    /// the post as it was when editing began — so restoring the draft restores the CAS guard
    /// too, not just the values (#1370 review). `nil` for new posts.
    public var baselineJSON: Data?

    /// Creates a draft snapshot.
    public init(
        siteID: UUID, typeID: String, postURL: URL? = nil,
        values: [String: Value], queuedStatus: String? = nil, visibility: String? = nil, baselineJSON: Data? = nil
    ) {
        self.siteID = siteID
        self.typeID = typeID
        self.postURL = postURL
        self.values = values
        self.queuedStatus = queuedStatus
        self.visibility = visibility
        self.baselineJSON = baselineJSON
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
        editorValues: TypedContentEditor.Values, fieldNames: [String],
        queuedStatus: String? = nil, visibility: String? = nil, baseline: MicropubPost? = nil
    ) {
        var values: [String: Value] = [:]
        for name in fieldNames {
            if let value = editorValues[name] { values[name] = Value(value) }
        }
        self.init(
            siteID: siteID, typeID: typeID, postURL: postURL,
            values: values, queuedStatus: queuedStatus, visibility: visibility,
            baselineJSON: baseline.flatMap(Self.encodeBaseline))
    }

    /// The editor values this draft restores to.
    public var editorValues: TypedContentEditor.Values {
        var out = TypedContentEditor.Values()
        for (name, value) in values { out[name] = value.fieldValue }
        return out
    }

    /// The restored CAS baseline, when one was captured and still decodes.
    public var baseline: MicropubPost? {
        baselineJSON.flatMap(Self.decodeBaseline)
    }

    /// Serializes a post's `{type, properties}` through its `JSONValue` raw form — the same
    /// wire shape `q=source` returns, so the round-trip is lossless for anything the server
    /// can store.
    static func encodeBaseline(_ post: MicropubPost) -> Data? {
        let object: [String: Any] = [
            "type": post.type,
            "properties": post.properties.mapValues { $0.map(\.rawValue) },
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static func decodeBaseline(_ data: Data) -> MicropubPost? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawType = object["type"] as? [Any],
              let rawProperties = object["properties"] as? [String: [Any]]
        else { return nil }
        let type = rawType.compactMap { $0 as? String }
        guard !type.isEmpty else { return nil }
        var properties: [String: [JSONValue]] = [:]
        for (key, values) in rawProperties {
            properties[key] = values.compactMap(JSONValue.from)
        }
        return MicropubPost(type: type, properties: properties)
    }
}

/// Reads and writes composer drafts under Application Support, one file per draft identity —
/// a queued update keyed by its post URL, a new composition keyed by its content type — so a
/// failed "note" send is never silently clobbered by a later "article" composition on the same
/// site (#1370 review; the original single-per-site file lost queued sends that way).
/// Injectable directory so tests point it at a scratch location.
public struct ComposerDraftStore: Sendable {
    private let directory: URL

    /// Creates a store rooted at `directory`, defaulting to the app's Application Support.
    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Anglesite", isDirectory: true)
    }

    /// A draft's stable identity: the post it updates, or — for a not-yet-created post — the
    /// content type it composes. Two different posts (or a post and a new composition) never
    /// share a file.
    static func key(postURL: URL?, typeID: String) -> String {
        postURL.map { "post:\($0.absoluteString)" } ?? "new:\(typeID)"
    }

    private func fileURL(forSite siteID: UUID, key: String) -> URL {
        // Hashed: post URLs aren't filesystem-safe and can exceed name-length limits.
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        return directory.appendingPathComponent(
            "micropub-draft-\(siteID.uuidString)-\(digest).json")
    }

    /// Persists `draft` under its identity, replacing any previous draft of the same identity
    /// only.
    public func save(_ draft: ComposerDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        let key = Self.key(postURL: draft.postURL, typeID: draft.typeID)
        try data.write(to: fileURL(forSite: draft.siteID, key: key), options: .atomic)
    }

    /// The site's in-progress *new* composition of `typeID`, or `nil`. Never returns a queued
    /// update to an existing post — the "New Post" entry point must never silently resume an
    /// unrelated post's pending edit (#1370 review).
    public func loadNewDraft(forSite siteID: UUID, typeID: String) -> ComposerDraft? {
        guard let draft = load(forSite: siteID, key: Self.key(postURL: nil, typeID: typeID)),
              draft.postURL == nil
        else { return nil }
        return draft
    }

    /// The site's queued/in-progress draft for the existing post at `postURL`, or `nil` — how
    /// reopening a post from the list discovers its own pending edit (#1370 review).
    public func loadDraft(forSite siteID: UUID, postURL: URL) -> ComposerDraft? {
        load(forSite: siteID, key: Self.key(postURL: postURL, typeID: ""))
    }

    private func load(forSite siteID: UUID, key: String) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: fileURL(forSite: siteID, key: key)) else {
            return nil
        }
        // Stale-format state restores as a fresh start, never a crash.
        return try? JSONDecoder().decode(ComposerDraft.self, from: data)
    }

    /// Removes the draft with `draft`'s identity (after a successful send, a terminal
    /// rejection, or an explicit discard).
    public func clear(_ draft: ComposerDraft) {
        clear(forSite: draft.siteID, postURL: draft.postURL, typeID: draft.typeID)
    }

    /// Removes the draft for the given identity.
    public func clear(forSite siteID: UUID, postURL: URL?, typeID: String) {
        let key = Self.key(postURL: postURL, typeID: typeID)
        try? FileManager.default.removeItem(at: fileURL(forSite: siteID, key: key))
    }
}
