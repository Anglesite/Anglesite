import Foundation

/// One interaction the spam screen held for the owner (#2066): the screening decision from the
/// ledger, joined with the live inbox record so the pane can show who wrote what. `interaction`
/// is `nil` when the Worker's inbox no longer has the id (the sender deleted the source, or it
/// was unverified since) — the decision is still listed so the owner can clear it.
public struct HeldInteraction: Identifiable, Sendable, Equatable {
    public let decision: ScreeningDecision
    public let interaction: ReceivedInteraction?

    public var id: String { decision.interactionID }

    public init(decision: ScreeningDecision, interaction: ReceivedInteraction?) {
        self.decision = decision
        self.interaction = interaction
    }

    /// `p(spam)` as a whole percentage for display, or `nil` for a deterministic rule.
    public var spamPercent: Int? { decision.probabilitySpam.map { Int(($0 * 100).rounded()) } }
    /// ``DecisionAnswer/confidence`` as a whole percentage for display, or `nil`.
    public var confidencePercent: Int? { decision.confidence.map { Int(($0 * 100).rounded()) } }
}

/// The moderation queue plus whether the inbox could be consulted at all. A hold with a `nil`
/// record means two different things depending on `inboxReachable`: the comment really is gone
/// (reachable), or we simply couldn't ask (unreachable) — the pane must not let the owner rule
/// on the second kind, since a ruling is permanent and they can't see what they'd be ruling on.
public struct HeldInteractionLoad: Sendable, Equatable {
    public let items: [HeldInteraction]
    public let inboxReachable: Bool

    public init(items: [HeldInteraction], inboxReachable: Bool) {
        self.items = items
        self.inboxReachable = inboxReachable
    }
}

/// What happened to an owner ruling (``HeldInteractionQueue/rule(_:approved:ledger:publish:)``).
public enum HeldInteractionRulingOutcome: Sendable, Equatable {
    /// Rejected: the ruling is recorded and the comment stays hidden.
    case hidden
    /// Approved and the publish step confirmed the comment is now snapshotted.
    case published
    /// Approved and recorded, but the publish step couldn't confirm the snapshot (offline, no
    /// token, git failure). The ruling stands, so the next inbox sync publishes it.
    case publishFailed
}

/// Builds the moderation queue from the ledger's unresolved holds and the current inbox, and
/// applies the owner's verdicts. Pure apart from the injected ledger and publish step, so the
/// join, the failure distinction and the ruling order are tested without a network client;
/// `ModerationModel` supplies the inputs.
public enum HeldInteractionQueue {
    /// Joins `held` (from ``InteractionScreeningLedger/held()``, already oldest-first) with
    /// `interactions` by id. Order is preserved from `held`; an id absent from `interactions`
    /// yields a ``HeldInteraction`` with a `nil` record rather than being dropped. `nil`
    /// `interactions` means the inbox couldn't be fetched: every item then has a `nil` record and
    /// ``HeldInteractionLoad/inboxReachable`` is `false`.
    public static func build(held: [ScreeningDecision], interactions: [ReceivedInteraction]?) -> HeldInteractionLoad {
        let byID = Dictionary((interactions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = held.map { HeldInteraction(decision: $0, interaction: byID[$0.interactionID]) }
        return HeldInteractionLoad(items: items, inboxReachable: interactions != nil)
    }

    /// Records the owner's verdict, then — only for an approval — runs `publish` and reports
    /// whether it confirmed the snapshot. The ledger write comes first on purpose: the ruling is
    /// the owner's intent and must survive a failed publish, which the next sync then retries.
    ///
    /// - Parameters:
    ///   - id: The held interaction's id.
    ///   - approved: `true` to show the comment, `false` to keep it hidden.
    ///   - ledger: Where the ruling is recorded.
    ///   - publish: Re-runs the inbox sync and returns whether the comment's snapshot now exists.
    /// - Returns: The outcome; `.hidden` never calls `publish`.
    public static func rule(
        _ id: String, approved: Bool, ledger: InteractionScreeningLedger,
        publish: @Sendable () async -> Bool
    ) async -> HeldInteractionRulingOutcome {
        ledger.rule(id, approved: approved)
        guard approved else { return .hidden }
        return await publish() ? .published : .publishFailed
    }
}
