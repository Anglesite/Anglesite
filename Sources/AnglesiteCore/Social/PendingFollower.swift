// Sources/AnglesiteCore/Social/PendingFollower.swift
import Foundation

/// One pending join request against this site's hosted `Group` actor: someone who sent a
/// `Follow` while the actor requires manual approval, awaiting the owner's `Accept`/`Reject`
/// (`davidwkeith/workers` PR #488's bearer-gated `GET <actor>/follow_requests`, closing
/// workers#487 — see
/// `docs/superpowers/specs/2026-08-10-hosted-community-provisioning-moderation-design.md` §6).
///
/// Transient: fetched live from this site's own Worker on every `ModerationModel.reload()`,
/// never written to `Source/` git — unlike ``CommunityMember``/`AnnouncedPost`, which snapshot
/// *confirmed* state, this is a live read of state the Worker alone owns.
public struct PendingFollower: Sendable, Equatable, Identifiable {
    /// The requester's own actor IRI — also this struct's ``id``, since it's the unique key
    /// the Worker itself uses (`followers.actor`).
    public let actor: URL
    /// When the `Follow` was recorded, decoded from the Worker's ISO 8601 `addedAt` string.
    public let addedAt: Date

    public var id: URL { actor }

    public init(actor: URL, addedAt: Date) {
        self.actor = actor
        self.addedAt = addedAt
    }
}
