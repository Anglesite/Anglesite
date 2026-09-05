import Foundation

/// Picks the ``DeployTarget`` conformer a site publishes through (#1682, #1015 slice 3) — the
/// piece that finally makes ``DomainConfig/deployTarget`` load-bearing instead of merely
/// round-tripping through `anglesite.json`.
///
/// The mapping is deliberately lossy in one direction: `nil`, the Cloudflare identifier, and any
/// value this app version doesn't recognize all resolve to ``CloudflareDeployTarget``. That
/// matches ``DomainConfig/deployTarget``'s own documented contract (an open string, not a closed
/// `enum`, so a hand edit or a future app version's value degrades instead of failing the whole
/// document) and preserves slice 1's zero-migration guarantee: every site that exists today has
/// no `deployTarget` key and keeps deploying exactly as before.
///
/// Only the *choice* lives here. Whether a chosen target supports a given feature (Workers,
/// Inbox Capture) is a separate question, answered by the capability gating in #1683 — when that
/// lands with its own `DeployTargetKind`, this factory should switch on that type rather than
/// re-matching the raw strings below.
public enum DeployTargetSelection {
    /// The shape ``DeployCommand`` stores instead of a fixed target: given the site being
    /// deployed, produce the target to publish it through. A closure rather than a direct call so
    /// a caller that already knows its target (``SocialWorkerProvisionCommand``'s Cloudflare-only
    /// deploy, every test) can pin one, and so a test can substitute a conformer built from
    /// literals instead of the Keychain.
    public typealias Resolver = @Sendable (_ siteDirectory: URL) -> any DeployTarget

    /// The conformer named by a persisted ``DomainConfig/deployTarget`` value.
    ///
    /// - Parameter id: The raw declared identifier, exactly as it appears in `anglesite.json` —
    ///   `nil` for a site that predates the field, and possibly a value this app version has
    ///   never heard of (the field is deliberately an open string).
    /// - Returns: ``GitHubPagesDeployTarget`` for ``GitHubPagesDeployTarget/id``;
    ///   ``CloudflareDeployTarget`` for everything else, `nil` included. Conformers are built
    ///   with their production defaults — the Keychain-backed credential sources — so a test
    ///   wanting literal credentials constructs its own instead of calling this.
    public static func target(forID id: String?) -> any DeployTarget {
        switch canonicalID(forDeclared: id) {
        case GitHubPagesDeployTarget.id: return GitHubPagesDeployTarget()
        default: return CloudflareDeployTarget(accountIDSource: CloudflareDeployTarget.defaultAccountIDSource)
        }
    }

    /// The identifier a declared value actually resolves to — the one place that owns *which
    /// identifiers this app version recognizes*.
    ///
    /// ``target(forID:)`` and the Settings picker's read-back
    /// (`PlistEditorModel.loadDeployTargetID`) both delegate here rather than each re-deriving the
    /// "unrecognized → Cloudflare" rule from ``selectableIDs``. Two hand-synchronized copies of
    /// that rule could drift the moment a third conformer lands — and a drifted picker would show
    /// a host the deploy path wouldn't really resolve to, the exact inconsistency this type's
    /// contract promises can't happen.
    ///
    /// - Parameter id: The raw declared identifier from `anglesite.json`, `nil` included.
    /// - Returns: The recognized identifier — ``GitHubPagesDeployTarget/id`` only for an exact
    ///   match, ``CloudflareDeployTarget/id`` for everything else. Always a member of
    ///   ``selectableIDs``, so a caller can hand the result straight to a picker.
    public static func canonicalID(forDeclared id: String?) -> String {
        switch id {
        case GitHubPagesDeployTarget.id: return GitHubPagesDeployTarget.id
        default: return CloudflareDeployTarget.id
        }
    }

    /// The conformer a site declares in its own `Source/anglesite.json`.
    ///
    /// - Parameter sourceDirectory: The site's `Source/` directory — the one holding
    ///   `anglesite.json`, not the `.anglesite` package root.
    /// - Returns: The declared conformer, or ``CloudflareDeployTarget`` when the config is
    ///   absent, unreadable, or declares nothing — mirroring the `(try? …) ?? DomainConfig()`
    ///   read every other declared-config resolver in ``DeployCoordinator`` uses. A corrupt
    ///   `anglesite.json` therefore deploys where it always did rather than refusing to deploy.
    public static func target(sourceDirectory: URL) -> any DeployTarget {
        let config = (try? DomainConfigStore(sourceDirectory: sourceDirectory).load()) ?? DomainConfig()
        return target(forID: config.deployTarget)
    }

    /// ``DeployCommand``'s production default: resolve from whatever the site itself declares.
    public static let fromSiteConfig: Resolver = { siteDirectory in
        target(sourceDirectory: siteDirectory)
    }

    /// The targets the Settings picker offers, in display order — every value
    /// ``canonicalID(forDeclared:)`` can return, and nothing else. Not every string
    /// ``target(forID:)`` tolerates is offerable — a value from a future app version stays
    /// readable (and keeps deploying through Cloudflare) without this app version claiming it can
    /// write it back.
    public static let selectableIDs: [String] = [CloudflareDeployTarget.id, GitHubPagesDeployTarget.id]
}
