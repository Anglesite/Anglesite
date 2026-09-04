import Foundation

/// The closed set of publish destinations the app knows how to reason about, resolved from
/// `DomainConfig.deployTarget`'s open string (#1683).
///
/// Deliberately **not** `RawRepresentable`: that protocol's `init?(rawValue:)` is failable and
/// lossless by contract, and generic code written against it assumes an unrecognized raw value
/// yields `nil`. This classifier is the opposite — total and lossy on purpose, because
/// `deployTarget` is an open string precisely so a file written by a newer app degrades rather
/// than failing to decode (see `DomainConfig.deployTarget`). Anything unrecognized, and the
/// absent case, resolve to ``cloudflare``, matching both that field's documented "nil means
/// cloudflare" contract and `DeployTargetSelection`'s conformer fallback: a site whose
/// declaration this build can't interpret keeps the behavior it had before the declaration
/// existed.
///
/// This is a *capability classifier*, not a conformer factory — it answers "what kind of host is
/// this site on," which `DeployTargetCapabilities` then turns into feature availability. Building
/// the actual `DeployTarget` to publish through is a separate concern.
public enum DeployTargetKind: Sendable, Equatable, CaseIterable {
    /// Cloudflare Pages + Workers — the default, and the only target with a Workers runtime.
    case cloudflare
    /// GitHub Pages — static hosting only (`GitHubPagesDeployTarget`).
    case githubPages

    /// Classifies a `DomainConfig.deployTarget` value. Matching is exact against each conformer's
    /// `id`, so a case variation (`"GitHubPages"`) is treated as unrecognized rather than guessed
    /// at — the identifiers are written by the app, and silently accepting near-misses would make
    /// a typo in a hand-edited `anglesite.json` invisible.
    public init(identifier: String?) {
        switch identifier {
        case GitHubPagesDeployTarget.id:
            self = .githubPages
        default:
            self = .cloudflare
        }
    }
}
