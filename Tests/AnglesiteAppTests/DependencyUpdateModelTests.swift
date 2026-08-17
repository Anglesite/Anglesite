import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// #1440: sheet-facing behavior for bumps held back by a foreign dependency's peer range —
/// the copy is consequence-phrased (never semver/JSON mechanics) and a held-back-only offer
/// set collapses the sheet to a single acknowledge action.
@Suite @MainActor struct DependencyUpdateModelTests {
    private static func heldAstroUpdate(blockers: [DependencyPeerBlocker]) -> DependencyHeldUpdate {
        DependencyHeldUpdate(
            offer: DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^7.1.3"),
            blockers: blockers
        )
    }

    @Test func heldCopyNamesTheBlockerAndTheKeptPackage() {
        let copy = DependencyUpdateModel.heldCopy(for: Self.heldAstroUpdate(
            blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")]))
        #expect(copy.contains("@astrojs/cloudflare"))
        #expect(copy.contains("astro"))
    }

    @Test func heldCopyIsPhrasedAboutConsequencesNotMechanics() {
        let copy = DependencyUpdateModel.heldCopy(for: Self.heldAstroUpdate(
            blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")]))
        // The advisory-UX rule: questions/explanations are about the owner's site, never
        // about git, diffs, semver ranges, or file mechanics.
        #expect(!copy.contains("^6.3.0"))
        #expect(!copy.contains("peerDependencies"))
        #expect(!copy.contains("package.json"))
        #expect(!copy.contains("semver"))
    }

    @Test func heldCopyListsEveryBlocker() {
        let copy = DependencyUpdateModel.heldCopy(for: Self.heldAstroUpdate(blockers: [
            DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0"),
            DependencyPeerBlocker(dependentName: "astro-seo-schema", requiredRange: ">=5.0.0 <7.0.0"),
        ]))
        #expect(copy.contains("@astrojs/cloudflare"))
        #expect(copy.contains("astro-seo-schema"))
    }

    @Test func heldBackOnlyOffersCollapseToAnAcknowledgeAction() {
        let heldOnly = DependencySyncOffers(heldUpdates: [Self.heldAstroUpdate(
            blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")])])
        let model = DependencyUpdateModel(offers: heldOnly, onDecision: { _ in })
        #expect(model.isHeldBackOnly)

        let mixed = DependencySyncOffers(
            updates: [DependencyUpdateOffer(name: "typescript", currentRange: "^5.8.0", offeredRange: "^5.9.3")],
            heldUpdates: heldOnly.heldUpdates)
        #expect(!DependencyUpdateModel(offers: mixed, onDecision: { _ in }).isHeldBackOnly)
    }
}
