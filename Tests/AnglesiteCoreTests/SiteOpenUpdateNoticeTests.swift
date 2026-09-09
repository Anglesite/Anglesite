import Testing
import Foundation
@testable import AnglesiteCore

/// #1962: the non-blocking site-open notice replaces the "Site Scripts Customized" and
/// "Dependency Updates Available" sheets. Its primary line is phrased about the site; raw paths
/// and semver ranges only ever appear under Details, and even there only as plain-language names.
@Suite struct SiteOpenUpdateNoticeTests {
    private func heldAstro() -> DependencyHeldUpdate {
        DependencyHeldUpdate(
            offer: DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^7.1.3"),
            blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")]
        )
    }

    @Test func nothingToTellYieldsNoNotice() {
        #expect(SiteOpenUpdateNotice.build(migration: .init(), dependencyOffers: nil) == nil)
        #expect(SiteOpenUpdateNotice.build(migration: .init(), dependencyOffers: DependencySyncOffers()) == nil)
    }

    @Test func scriptUpdatesProduceASiteFramedMessageWithNoPathsOnThePrimaryLine() {
        var report = ExistingSiteMigration.Report()
        report.refreshedPaths = ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"]
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil))

        #expect(notice.message == "Anglesite updated the parts of this site it maintains.")
        for noun in ["scripts/", "src/lib", ".ts", "git", "npm", "package.json", "semver"] {
            #expect(!notice.message.contains(noun), "primary line leaked \(noun)")
        }
        #expect(notice.details == ["Updated: Security check, 1 site framework file."])
    }

    @Test func aRestoredFileIsNamedAsRestoredNotMerelyUpdated() {
        var report = ExistingSiteMigration.Report()
        report.restoredPaths = ["scripts/pre-deploy-check.ts"]
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil))

        #expect(notice.details.first?.hasPrefix("Restored, because this copy had been changed: Security check") == true)
    }

    @Test func appliedDependencyUpdatesSayTheSiteWillRebuild() {
        let offers = DependencySyncOffers(
            updates: [DependencyUpdateOffer(name: "typescript", currentRange: "^5.8.0", offeredRange: "^5.9.3")],
            additions: [DependencyAdditionOffer(name: "pagefind", offeredRange: "^1.3.0", section: .devDependencies)]
        )
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: .init(), dependencyOffers: offers))

        #expect(notice.message == "Anglesite updated the parts of this site it maintains. Your site will rebuild.")
        #expect(notice.details == ["Updated the site's building blocks: pagefind, typescript."])
        #expect(!notice.details.joined().contains("^5.9.3"))
    }

    @Test func heldBackOnlyOffersProduceAKeptAsIsNoticeWithTheConsequenceUnderDetails() {
        let offers = DependencySyncOffers(heldUpdates: [heldAstro()])
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: .init(), dependencyOffers: offers))

        #expect(notice.message == "Anglesite kept part of this site as it is — see Details.")
        #expect(notice.details.count == 1)
        #expect(notice.details[0].contains("@astrojs/cloudflare"))
        #expect(!notice.details[0].contains("^6.3.0"))
    }

    @Test func failuresAndAnUncommittedPassAreDisclosed() {
        var report = ExistingSiteMigration.Report()
        report.refreshedPaths = ["scripts/csp.ts"]
        report.failedPaths = ["scripts/redirects.ts"]
        report.committed = false
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil))

        #expect(notice.details.contains("1 file couldn't be updated and will be retried the next time this site opens."))
        #expect(notice.details.contains { $0.contains("couldn't be recorded in the site's history yet") })
    }

    @Test func aPreservedSecurityTxtIsMentionedAsTheOwners() {
        var report = ExistingSiteMigration.Report()
        report.otherTouchedPaths = [".site-config"]
        report.securityTxtPreserved = true
        let notice = try! #require(SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil))

        #expect(notice.details.contains("Your hand-written security contact file was left as yours to maintain."))
    }

    @Test func appOwnedFileSummaryNamesKnownFilesAndRollsUpTheRest() {
        let lines = AppOwnedFileDescription.summary(for: [
            "src/lib/rsl.ts", "scripts/edge-artifacts.ts", "scripts/embeds/adapters.ts", "scripts/pre-deploy-check.ts",
        ])
        #expect(lines == ["AI-crawler and content-licensing signals", "Security check", "2 site framework files"])
    }
}
