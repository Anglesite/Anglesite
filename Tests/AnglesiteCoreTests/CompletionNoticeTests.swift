import Testing
import Foundation
@testable import AnglesiteCore

/// Wording + identity rules for the completion notifications posted when Deploy/Backup/Audit
/// finish (#526). Pure content — the app-target `CompletionNotifier` only renders these into
/// `UNNotificationRequest`s, so everything user-visible is asserted here under `swift test`.
struct CompletionNoticeTests {

    // MARK: Deploy

    @Test("Deploy success carries the URL and duration")
    func deploySucceeded() {
        let notice = CompletionNoticeBuilder.deploy(
            siteName: "Pullets Forever",
            siteID: "site-1",
            outcome: .succeeded(url: "https://pullets.example", duration: 65)
        )
        #expect(notice.title == "Deploy Succeeded")
        #expect(notice.subtitle == "Pullets Forever")
        #expect(notice.body == "Published to https://pullets.example in 1m 05s.")
        #expect(notice.siteID == "site-1")
        #expect(!notice.isFailure)
    }

    @Test("Deploy failure carries the reason")
    func deployFailed() {
        let notice = CompletionNoticeBuilder.deploy(
            siteName: "Pullets Forever",
            siteID: "site-1",
            outcome: .failed(reason: "npm run build failed (exit 1)")
        )
        #expect(notice.title == "Deploy Failed")
        #expect(notice.subtitle == "Pullets Forever")
        #expect(notice.body == "npm run build failed (exit 1)")
        #expect(notice.isFailure)
    }

    @Test("Blocked deploy counts the security failures", arguments: [
        (1, "Pre-deploy check found 1 issue that must be fixed before deploying."),
        (3, "Pre-deploy check found 3 issues that must be fixed before deploying."),
    ])
    func deployBlocked(count: Int, expectedBody: String) {
        let notice = CompletionNoticeBuilder.deploy(
            siteName: "Site",
            siteID: "site-1",
            outcome: .blocked(failureCount: count)
        )
        #expect(notice.title == "Deploy Blocked")
        #expect(notice.body == expectedBody)
        #expect(notice.isFailure)
    }

    @Test("Deploy identifier is stable per site so newer outcomes replace older banners")
    func deployIdentifierStable() {
        let a = CompletionNoticeBuilder.deploy(siteName: "S", siteID: "site-1", outcome: .failed(reason: "x"))
        let b = CompletionNoticeBuilder.deploy(siteName: "S", siteID: "site-1", outcome: .succeeded(url: "https://a", duration: 1))
        let other = CompletionNoticeBuilder.deploy(siteName: "S", siteID: "site-2", outcome: .failed(reason: "x"))
        #expect(a.identifier == b.identifier)
        #expect(a.identifier != other.identifier)
    }

    // MARK: Backup

    @Test("Backup success names the short commit and remote/branch")
    func backupSucceeded() {
        let notice = CompletionNoticeBuilder.backup(
            siteName: "Site",
            siteID: "site-1",
            outcome: .succeeded(commitSHA: "a1b2c3d4e5f6a7b8", branch: "main", remote: "origin")
        )
        #expect(notice.title == "Backup Complete")
        #expect(notice.subtitle == "Site")
        #expect(notice.body == "Pushed commit a1b2c3d to origin/main.")
        #expect(!notice.isFailure)
    }

    @Test("Backup with a short SHA does not over-trim")
    func backupShortSHA() {
        let notice = CompletionNoticeBuilder.backup(
            siteName: "Site",
            siteID: "site-1",
            outcome: .succeeded(commitSHA: "abc", branch: "main", remote: "origin")
        )
        #expect(notice.body == "Pushed commit abc to origin/main.")
    }

    @Test("Backup no-changes is a completion, not a failure")
    func backupNoChanges() {
        let notice = CompletionNoticeBuilder.backup(siteName: "Site", siteID: "site-1", outcome: .noChanges)
        #expect(notice.title == "Backup Complete")
        #expect(notice.body == "No changes to back up.")
        #expect(!notice.isFailure)
    }

    @Test("Backup failure carries the reason")
    func backupFailed() {
        let notice = CompletionNoticeBuilder.backup(
            siteName: "Site", siteID: "site-1", outcome: .failed(reason: "git push failed (exit 128)")
        )
        #expect(notice.title == "Backup Failed")
        #expect(notice.body == "git push failed (exit 128)")
        #expect(notice.isFailure)
    }

    // MARK: Audit

    @Test("Clean audit says no issues")
    func auditClean() {
        let notice = CompletionNoticeBuilder.audit(
            siteName: "Site", siteID: "site-1",
            outcome: .succeeded(criticalCount: 0, warningCount: 0, infoCount: 0)
        )
        #expect(notice.title == "Audit Complete")
        #expect(notice.body == "No issues found.")
        #expect(!notice.isFailure)
    }

    @Test("Audit findings are summarized by severity, omitting empty buckets")
    func auditFindings() {
        let notice = CompletionNoticeBuilder.audit(
            siteName: "Site", siteID: "site-1",
            outcome: .succeeded(criticalCount: 2, warningCount: 1, infoCount: 0)
        )
        #expect(notice.body == "Found 2 critical, 1 warning.")
    }

    @Test("Audit singular/plural forms", arguments: [
        (1, 0, 0, "Found 1 critical."),
        (0, 2, 0, "Found 2 warnings."),
        (0, 0, 3, "Found 3 info."),
        (1, 1, 1, "Found 1 critical, 1 warning, 1 info."),
    ])
    func auditPluralization(critical: Int, warning: Int, info: Int, expected: String) {
        let notice = CompletionNoticeBuilder.audit(
            siteName: "Site", siteID: "site-1",
            outcome: .succeeded(criticalCount: critical, warningCount: warning, infoCount: info)
        )
        #expect(notice.body == expected)
    }

    @Test("Audit failure carries the reason")
    func auditFailed() {
        let notice = CompletionNoticeBuilder.audit(
            siteName: "Site", siteID: "site-1", outcome: .failed(reason: "build failed")
        )
        #expect(notice.title == "Audit Failed")
        #expect(notice.body == "build failed")
        #expect(notice.isFailure)
    }

    // MARK: Follow Request

    @Test("Singular follow request reads as one person")
    func followRequestSingular() {
        let notice = CompletionNoticeBuilder.followRequest(siteName: "Pullets Forever", siteID: "site-1", count: 1)
        #expect(notice.title == "New Follow Request")
        #expect(notice.subtitle == "Pullets Forever")
        #expect(notice.body == "1 person wants to follow your site.")
        #expect(notice.siteID == "site-1")
        #expect(!notice.isFailure)
    }

    @Test("Plural follow requests read as N people", arguments: [2, 5])
    func followRequestPlural(count: Int) {
        let notice = CompletionNoticeBuilder.followRequest(siteName: "Site", siteID: "site-1", count: count)
        #expect(notice.title == "New Follow Requests")
        #expect(notice.body == "\(count) people want to follow your site.")
    }

    @Test("Follow request identifier is stable per site so a later count replaces the banner")
    func followRequestIdentifierStable() {
        let a = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-1", count: 1)
        let b = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-1", count: 3)
        let other = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-2", count: 1)
        #expect(a.identifier == b.identifier)
        #expect(a.identifier != other.identifier)
    }

    // MARK: Duration formatting

    @Test("Durations format as seconds under a minute and m/ss above", arguments: [
        (0.4, "0s"),
        (12.0, "12s"),
        (59.4, "59s"),
        (60.0, "1m 00s"),
        (65.0, "1m 05s"),
        (3_725.0, "62m 05s"),
    ])
    func durationFormatting(seconds: TimeInterval, expected: String) {
        #expect(CompletionNoticeBuilder.formatDuration(seconds) == expected)
    }
}

/// Deploy Dock-tile progress mapping (#526): the deploy pipeline has four fixed milestones, so
/// the Dock bar is determinate per-phase; unknown phases fall back to indeterminate.
struct DeployDockProgressTests {

    /// The deploy milestones in emission order (build/feed generation → preflight scan → wrangler
    /// → finalize → webmentions → POSSE). NOTE: that order lives across `DeployCommand` and
    /// `DeployModel`'s post-deploy pipeline and is not statically derivable here. If it is ever
    /// reordered, update this list (and `DeployDockProgress`'s table), or the Dock bar moves back.
    private static let pipelineOrder = [
        OperationProgress.deployBuilding, .deployPreflight, .deployDeploying, .deployFinalizing,
        .deployWebmentions, .deploySyndicating,
    ]

    @Test("Known milestones map to monotonically increasing fractions in pipeline order")
    func monotonicPipeline() throws {
        let fractions = Self.pipelineOrder.map { DeployDockProgress.fraction(forPhase: $0.phase) }
        for fraction in fractions {
            let value = try #require(fraction, "every DeployCommand milestone must resolve to a determinate fraction")
            #expect(value > 0 && value < 1)
        }
        let values = fractions.compactMap { $0 }
        #expect(values == values.sorted())
        #expect(Set(values).count == values.count, "each milestone advances the bar")
    }

    @Test("Unknown phases are indeterminate")
    func unknownPhaseIndeterminate() {
        #expect(DeployDockProgress.fraction(forPhase: "warpingSpacetime") == nil)
        #expect(DeployDockProgress.fraction(forPhase: "") == nil)
    }
}
