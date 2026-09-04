import Foundation

/// Top-level entry point for the dependency-sync feature: the fast-path gate
/// (spec §3.1) plus the full 3-way diff, wired together. Never throws — any
/// unreadable/malformed input degrades to "nothing to offer" (spec §7), since
/// this is a diagnostic convenience feature that must never block a site opening.
public enum DependencySyncChecker {
    /// Runs the whole check for one site, returning the offers to surface (empty = nothing to
    /// show). The fast path: when `.site-config`'s `ANGLESITE_VERSION` stamp already matches
    /// `runningAppVersion`, this app version has previously scaffolded or synced the site, so
    /// the package.json reads and 3-way diff are skipped entirely (spec §3.1) — the stamp is
    /// what keeps this cheap enough to run on every site open. Any unreadable or malformed
    /// input degrades to `[]` per the type contract.
    public static func check(
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL,
        runningAppVersion: String
    ) -> DependencySyncOffers {
        let siteConfigURL = sourceDirectory.appendingPathComponent(".site-config")
        if let siteConfigContents = try? String(contentsOf: siteConfigURL, encoding: .utf8),
           let stampedVersion = SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: siteConfigContents),
           stampedVersion == runningAppVersion {
            return DependencySyncOffers()
        }

        guard let sitePackageText = try? String(
                contentsOf: sourceDirectory.appendingPathComponent("package.json"), encoding: .utf8),
              let siteDeps = try? PackageJSONDependencies.extract(from: sitePackageText),
              let templatePackageText = try? String(
                contentsOf: templateDirectory.appendingPathComponent("package.json"), encoding: .utf8),
              let templateSections = try? PackageJSONDependencies.extractSections(from: templatePackageText)
        else { return DependencySyncOffers() }

        var templateDeps = templateSections.dependencies
        templateDeps.merge(templateSections.devDependencies) { _, new in new }

        let baseline = DependencyBaseline.load(from: configDirectory)
        let offers = DependencySync.diff(
            site: siteDeps,
            baseline: baseline,
            template: templateDeps,
            templateDevDependencyNames: Set(templateSections.devDependencies.keys)
        )
        guard !offers.updates.isEmpty else { return offers }

        // #1440: the site's *foreign* dependencies (declared in its package.json but not
        // tracked by the template) may pin a peer range a template bump would violate —
        // e.g. an imported site's own @astrojs/cloudflare requiring the astro major the
        // template just moved past. Such a bump is held for the owner, not auto-offered.
        let untrackedNames = Set(siteDeps.keys).subtracting(templateDeps.keys)
        let foreignPeers = DependencyPeerCheck.foreignPeerRequirements(
            sourceDirectory: sourceDirectory, untrackedDependencyNames: untrackedNames)
        let (allowed, held) = DependencyPeerCheck.partition(
            updates: offers.updates, foreignPeerRequirements: foreignPeers)
        return DependencySyncOffers(updates: allowed, additions: offers.additions, heldUpdates: held)
    }
}
