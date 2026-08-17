import Foundation
import AnglesiteCore

/// Thin, `Identifiable` model driving the dependency-update-offer sheet
/// (spec §5, #1108). Holds the already-computed offers (bumps and new-package
/// additions) and forwards the user's decision — no comparison/diff logic
/// lives here, that's all in `AnglesiteCore`
/// (`DependencySyncChecker`/`DependencySyncApplier`).
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
    /// Sheet copy for one held-back bump (#1440). Framed around consequences to the site —
    /// same guiding principle as `ScriptSyncModel.rowCopy` — never around semver ranges or
    /// package.json mechanics: the owner came here to publish a website, not to adjudicate
    /// a dependency graph.
    static func heldCopy(for held: DependencyHeldUpdate) -> String {
        let names = held.blockers.map(\.dependentName)
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
        let verb = names.count == 1 ? "isn't" : "aren't"
        return "This site also uses \(list), which \(verb) ready for the newer \(held.offer.name) yet. "
            + "Updating \(held.offer.name) now would stop parts of this site from working, so "
            + "Anglesite is keeping it as it is."
    }
}
