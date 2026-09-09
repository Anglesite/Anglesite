import Foundation

/// Owner-facing names for the app-owned files the site-open migration touches — framed around
/// what the file *does for the site*, never its path (CLAUDE.md "The app advises; it does not
/// delegate the decision"; owner decision D1). A handful of files carry a consequence worth
/// naming; everything else rolls up into a generic group so the owner never reads ~40 raw paths.
public enum AppOwnedFileDescription {
    /// The plain-language name for one app-owned relative path, or `nil` when it belongs to the
    /// generic "site framework" group.
    public static func name(for relativePath: String) -> String? {
        switch relativePath {
        case "scripts/pre-deploy-check.ts": return "Security check"
        case "scripts/edge-artifacts.ts": return "AI-crawler and content-licensing signals"
        case "scripts/csp.ts": return "Content security policy"
        case "scripts/well-known.ts": return "Well-known site files"
        case "scripts/redirects.ts": return "Redirects"
        default: return nil
        }
    }

    /// The owner-facing line for a set of paths: named files first (sorted), then one rolled-up
    /// count for the rest — e.g. `["Security check", "Redirects", "3 site framework files"]`.
    public static func summary(for relativePaths: [String]) -> [String] {
        let named = relativePaths.compactMap(name(for:)).sorted()
        let unnamed = relativePaths.filter { name(for: $0) == nil }.count
        var lines = named
        if unnamed > 0 {
            lines.append(unnamed == 1 ? "1 site framework file" : "\(unnamed) site framework files")
        }
        return lines
    }
}

/// The non-blocking notice shown after a site opens and the app has applied the updates it
/// maintains (#1962) — replacing the two blocking sheets ("Site Scripts Customized",
/// "Dependency Updates Available") that used to ask the owner to adjudicate scripts and semver.
/// The primary line is phrased about the site; the technical detail (which files, which
/// packages) sits behind a Details disclosure for the curious. Built here, in `AnglesiteCore`,
/// so the wording is unit-tested off the hosted app target.
public struct SiteOpenUpdateNotice: Sendable, Equatable {
    /// The one sentence the banner shows.
    public let message: String
    /// The Details disclosure's lines, in display order.
    public let details: [String]

    /// Memberwise, for tests and previews.
    public init(message: String, details: [String]) {
        self.message = message
        self.details = details
    }

    /// Builds the notice for one site open, or `nil` when there is nothing to tell the owner
    /// (nothing written, and no dependency update applied or held back).
    ///
    /// - Parameters:
    ///   - migration: What `ExistingSiteMigration.run` wrote.
    ///   - dependencyOffers: The `DependencySyncChecker` offers that were applied this open
    ///     (bumps and additions land; held-back bumps are reported as kept, #1440), or `nil`
    ///     when no check ran.
    public static func build(
        migration: ExistingSiteMigration.Report,
        dependencyOffers: DependencySyncOffers?
    ) -> SiteOpenUpdateNotice? {
        var details: [String] = []

        if !migration.restoredPaths.isEmpty {
            details.append("Restored, because this copy had been changed: "
                + AppOwnedFileDescription.summary(for: migration.restoredPaths).joined(separator: ", ") + ".")
        }
        if !migration.refreshedPaths.isEmpty {
            details.append("Updated: "
                + AppOwnedFileDescription.summary(for: migration.refreshedPaths).joined(separator: ", ") + ".")
        }
        if !migration.failedPaths.isEmpty {
            let count = migration.failedPaths.count
            details.append(count == 1
                ? "1 file couldn't be updated and will be retried the next time this site opens."
                : "\(count) files couldn't be updated and will be retried the next time this site opens.")
        }

        let dependenciesApplied = (dependencyOffers?.updates.count ?? 0) + (dependencyOffers?.additions.count ?? 0)
        if let offers = dependencyOffers {
            let updatedNames = (offers.updates.map(\.name) + offers.additions.map(\.name)).sorted()
            if !updatedNames.isEmpty {
                details.append("Updated the site's building blocks: " + updatedNames.joined(separator: ", ") + ".")
            }
            for held in offers.heldUpdates {
                details.append(DependencySyncCopy.heldCopy(for: held))
            }
        }

        if migration.securityTxtPreserved {
            details.append("Your hand-written security contact file was left as yours to maintain.")
        }
        if !migration.committed {
            details.append("The changes are on disk but couldn't be recorded in the site's history yet — Anglesite will retry the next time this site opens.")
        }

        let wroteSomething = !migration.isEmpty || dependenciesApplied > 0
        let heldOnly = !wroteSomething && !(dependencyOffers?.heldUpdates.isEmpty ?? true)
        guard wroteSomething || heldOnly || !migration.failedPaths.isEmpty else { return nil }

        let message: String
        if wroteSomething {
            message = dependenciesApplied > 0
                ? "Anglesite updated the parts of this site it maintains. Your site will rebuild."
                : "Anglesite updated the parts of this site it maintains."
        } else if heldOnly {
            message = "Anglesite kept part of this site as it is — see Details."
        } else {
            message = "Anglesite couldn't update part of this site; it will try again next time."
        }
        return SiteOpenUpdateNotice(message: message, details: details)
    }
}
