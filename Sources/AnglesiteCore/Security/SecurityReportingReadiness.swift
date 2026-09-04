import Foundation

/// What Website Settings ▸ Security Reports should offer for a site, given its GitHub repo facts.
///
/// Pure by design: the network reads (repo visibility, private-vulnerability-reporting state)
/// happen in the model layer, and every branch of the decision is unit-testable without fakes.
public enum SecurityReportingReadiness: Sendable, Equatable {
    /// Not yet determined: before a check has ever completed, or a check failed before one ever
    /// succeeded. Deliberately distinct from `notGitHub` — the site may well have a GitHub
    /// remote, the caller just doesn't know its state yet. `evaluate` never returns this case; a
    /// caller assigns it directly when it cannot get as far as calling `evaluate` at all.
    case unknown
    /// No `origin`, an origin `RemoteRepo.parse` doesn't recognize, or a recognized origin hosted
    /// somewhere other than GitHub (e.g. Cloudflare Artifacts, #1266) — this whole security-
    /// reporting flow (advisory form, PVR) is GitHub-specific.
    case notGitHub
    /// The repo's advisory form is already one of the published contacts.
    case alreadyConfigured
    /// Public with private vulnerability reporting on — the form is usable, offer to publish it.
    case ready
    /// Public but private vulnerability reporting is off — offer to enable it, then publish.
    case needsPVR
    /// A private repo: outside reporters cannot reach the advisory form at all.
    case repoPrivate

    /// Precedence: `notGitHub` → `alreadyConfigured` → `repoPrivate` → `needsPVR` → `ready`.
    ///
    /// `alreadyConfigured` deliberately outranks `repoPrivate`: an owner who published the form
    /// and later made the repo private has already done the setup, so the UI should confirm the
    /// channel and warn about visibility rather than re-offer configuration.
    public static func evaluate(
        repo: RemoteRepo?,
        isPrivate: Bool,
        pvrEnabled: Bool,
        contacts: String
    ) -> SecurityReportingReadiness {
        // `RemoteRepo.parse` accepts recognized non-GitHub hosts too (#1266's `RepoHost`), so a
        // nil check alone isn't enough — an Artifacts repo must read as `.notGitHub` here, not
        // fall through to the GitHub-specific PVR/advisory-form logic below.
        guard let repo, repo.host == .github else { return .notGitHub }
        if SecurityReportingAsset.usesAdvisoryForm(contacts, repo: repo) { return .alreadyConfigured }
        if isPrivate { return .repoPrivate }
        return pvrEnabled ? .ready : .needsPVR
    }
}
