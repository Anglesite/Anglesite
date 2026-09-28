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

/// Builds the moderation queue from the ledger's unresolved holds and the current inbox.
/// Pure, so the join and ordering are tested without a ledger file or a network client;
/// `ModerationModel` supplies both inputs and calls ``InteractionScreeningLedger/rule(_:approved:at:)``
/// on the owner's verdict.
public enum HeldInteractionQueue {
    /// Joins `held` (from ``InteractionScreeningLedger/held()``, already oldest-first) with
    /// `interactions` by id. Order is preserved from `held`; an id absent from `interactions`
    /// yields a ``HeldInteraction`` with a `nil` record rather than being dropped.
    public static func build(held: [ScreeningDecision], interactions: [ReceivedInteraction]) -> [HeldInteraction] {
        let byID = Dictionary(interactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return held.map { HeldInteraction(decision: $0, interaction: byID[$0.interactionID]) }
    }
}
