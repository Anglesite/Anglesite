// Sources/AnglesiteCore/Audit/FlagReport.swift
import Foundation

/// One open abuse report against this site's hosted `Group` actor: an inbound `Flag` activity a
/// remote peer sent, awaiting the owner's dismissal (`davidwkeith/workers` PR #500, closing
/// workers#489 — the `GET <actor>/reports` bearer-gated listing, see
/// `docs/superpowers/specs/2026-08-18-activitypub-flag-report-review-design.md`).
///
/// Transient, like ``PendingFollower``: fetched live from this site's own Worker on every
/// `ModerationModel.reload()`, never written to `Source/` git — the Worker alone owns report
/// state (open vs. resolved).
public struct FlagReport: Sendable, Equatable, Identifiable {
    /// The `Flag` activity's own AS2 `id` — not this struct's ``id`` for display purposes, but
    /// the exact value a dismissal must echo back as `Ignore`'s `object`
    /// (``CommunityMembershipClient/resolveReport(activityID:)``).
    public let activityID: String
    /// The reporting peer's actor IRI, when the Worker's stored `Flag.actor` resolved to one — a
    /// bare string or an embedded object's `id` (AS2 permits either). `nil` for a malformed or
    /// missing `actor`; the UI must still show the report rather than dropping it, since the
    /// *target* and *reason* are usually enough for the owner to act on.
    public let reporter: URL?
    /// The reported content or actor's IRI. `Flag.object` can be a bare IRI, an embedded object,
    /// or an array of either (AS2 leaves this to the sender) — this is the first one that
    /// resolves to a URL. `nil` means none did, in which case dismissing is still possible but
    /// acting on the target (``CommunityMembershipClient/remove(target:)``) is not.
    public let target: URL?
    /// The reporter's free-text reason, from `Flag.content`. `nil` when the peer sent none.
    public let reason: String?
    /// When the `Flag` was received, decoded from the Worker's `published` field if present.
    /// `nil` when absent or unparseable — the Worker already returns reports newest-first, so
    /// list order doesn't depend on this.
    public let receivedAt: Date?

    public var id: String { activityID }

    public init(activityID: String, reporter: URL?, target: URL?, reason: String?, receivedAt: Date?) {
        self.activityID = activityID
        self.reporter = reporter
        self.target = target
        self.reason = reason
        self.receivedAt = receivedAt
    }
}
