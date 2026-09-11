import Foundation
import AnglesiteCore

/// Thin, `Identifiable` model driving the single-package dependency fix sheet — the Security
/// Reports tab's "Update available" action (#975). Holds the already-computed offers and forwards
/// the owner's decision — no comparison/diff logic lives here, that's all in `AnglesiteCore`
/// (`DependencySyncChecker`/`DependencySyncApplier`).
///
/// Since #1962 the site-open dependency check no longer presents this sheet: it applies the
/// template's offers directly and reports through `SiteOpenUpdateNotice` (owner decision D1 —
/// the owner never adjudicates semver ranges). This sheet remains only for the owner-initiated
/// Security Reports path, where the owner has already chosen to act on one specific report.
@MainActor
final class DependencyUpdateModel: Identifiable {
    nonisolated let id = UUID()
    let offers: DependencySyncOffers
    private let onDecision: (_ accepted: Bool) -> Void

    init(offers: DependencySyncOffers, onDecision: @escaping (_ accepted: Bool) -> Void) {
        self.offers = offers
        self.onDecision = onDecision
    }

    func update() { onDecision(true) }
    func skip() { onDecision(false) }

    /// True when there is nothing to actually apply — every offer was held back by a
    /// foreign dependency's peer range (#1440). The sheet then shows a single
    /// acknowledge button instead of Update/Skip.
    var isHeldBackOnly: Bool {
        offers.updates.isEmpty && offers.additions.isEmpty && !offers.heldUpdates.isEmpty
    }
}

extension DependencyUpdateModel {
    /// Sheet copy for one held-back bump (#1440) — shared with the site-open notice via
    /// `DependencySyncCopy` so the two surfaces can't drift.
    static func heldCopy(for held: DependencyHeldUpdate) -> String {
        DependencySyncCopy.heldCopy(for: held)
    }
}
