import Foundation
import AnglesiteCore

/// Owner-facing sentences for the failure kinds `OwnerPhrasing` (AnglesiteCore) classifies —
/// the app-side half of #1963 (decision D1): the primary surface talks about what happened to
/// the owner's *site*, and the raw git/npm/wrangler reason stays available as a technical
/// `detail` for a "Details" disclosure or the Debug pane. Kept here (not in AnglesiteCore) so
/// every sentence goes through `String(localized:)` and lands in the String Catalog.
///
/// Each entry point returns the owner sentence plus the technical detail together so a view
/// can't accidentally render one without having the other to hand.
enum OwnerFacingCopy {
    /// A failure as the owner should see it: `summary` on the primary surface, `detail` behind
    /// a disclosure. `detail` is `nil` when the summary already says everything (e.g. a
    /// cancellation).
    struct Failure: Equatable {
        let summary: String
        let detail: String?
    }

    // MARK: iCloud sync

    /// The sync badge/popover line for a `SyncScheduler.Status.failed(reason:)`.
    static func sync(reason: String) -> Failure {
        let summary: String
        switch OwnerPhrasing.syncKind(for: reason) {
        case .waitingForICloud:
            summary = String(localized: "Waiting for iCloud to finish copying this site's history.")
        case .nothingToSync:
            summary = String(localized: "Nothing to sync yet — this site has no saved changes.")
        case .unsavedEdits:
            summary = String(localized: "Sync will resume once this site's latest edits are saved into its history.")
        case .historyInUnexpectedState:
            summary = String(localized: "This site's history is in an unexpected state, so iCloud sync is paused.")
        case .couldNotCombineChanges:
            summary = String(localized: "Changes made on another Mac couldn't be combined with this one automatically.")
        case .cloudCopyUnreadable:
            summary = String(localized: "The copy of this site's history in iCloud couldn't be read.")
        case .cloudWriteFailed:
            summary = String(localized: "Anglesite couldn't save this site's history to iCloud Drive.")
        case .cloudReadFailed:
            summary = String(localized: "Anglesite couldn't read this site's history from iCloud Drive.")
        case .unknown:
            summary = String(localized: "iCloud sync didn't finish.")
        }
        return Failure(summary: summary, detail: OwnerPhrasing.detail(reason: reason, exitCode: nil))
    }

    // MARK: Backup

    /// The backup drawer / notification line for a `BackupModel.Phase.failed`.
    static func backup(reason: String, exitCode: Int32?) -> Failure {
        let summary: String
        switch OwnerPhrasing.backupKind(for: reason) {
        case .notConnected:
            summary = String(localized: "This site isn't connected to an online backup yet. Use Publish to GitHub to set one up.")
        case .canceled:
            return Failure(summary: String(localized: "Backup canceled."), detail: nil)
        case .uploadFailed:
            summary = String(localized: "Anglesite couldn't send this site's changes to its online backup. Check your connection and GitHub sign-in, then try again.")
        case .recordFailed:
            summary = String(localized: "Anglesite couldn't save this site's changes into its history.")
        case .historyUnreadable:
            summary = String(localized: "Anglesite couldn't read this site's history.")
        case .unknown:
            summary = String(localized: "Backup didn't finish.")
        }
        return Failure(summary: summary, detail: OwnerPhrasing.detail(reason: reason, exitCode: exitCode))
    }

    // MARK: Publish / audit

    /// The deploy drawer / audit sheet / notification line for a failed publish or audit run.
    /// An unrecognized reason is shown as-is (most `DeployModel` reasons are already
    /// owner-phrased), with only the exit code moved out of the primary line.
    static func operation(reason: String, exitCode: Int32?) -> Failure {
        let detail = OwnerPhrasing.detail(reason: reason, exitCode: exitCode)
        switch OwnerPhrasing.operationKind(for: reason) {
        case .buildFailed:
            return Failure(summary: String(localized: "Anglesite couldn't build this site."), detail: detail)
        case .buildInterrupted:
            return Failure(summary: String(localized: "Building this site was interrupted."), detail: detail)
        case .publishRejected:
            return Failure(summary: String(localized: "Cloudflare didn't accept this publish."), detail: detail)
        case .publishUnconfirmed:
            return Failure(
                summary: String(localized: "Anglesite couldn't confirm this publish went through — it may have already succeeded. Check again in a few minutes before trying once more."),
                detail: detail)
        case .publishInterrupted:
            return Failure(summary: String(localized: "Publishing was interrupted."), detail: detail)
        case .safetyCheckUnavailable:
            return Failure(summary: String(localized: "Anglesite's safety check couldn't run, so nothing was published."), detail: detail)
        case .cloudflareSignInUnreadable:
            return Failure(summary: String(localized: "Anglesite couldn't read your Cloudflare sign-in. Sign in again in Settings."), detail: detail)
        case .canceled:
            return Failure(summary: String(localized: "Canceled."), detail: nil)
        case .unknown:
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the exit code was hidden — surface it as the detail so it isn't lost.
            return Failure(summary: trimmed, detail: detail == trimmed ? nil : detail)
        }
    }

    // MARK: Safety check (pre-deploy gate)

    /// One safety-check finding as the blocked-publish sheet shows it (#2211). `title` names what
    /// was found and `consequence` says what publishing it would do, both in the owner's terms;
    /// `page` is the visitor-facing address it's on, when it's on a page. The scan's own wording
    /// (message, suggested fix, file path) is technical — it names `dist/`, `_headers`,
    /// `.gitignore` — so it goes in `detail`, behind the sheet's Details disclosure (D1).
    struct GateFinding: Equatable {
        let title: String
        let consequence: String
        let page: String?
        let detail: String?
    }

    /// The owner-facing reading of a blocker the pre-deploy scan reported.
    static func gate(_ failure: PreDeployCheck.ScanFailure) -> GateFinding {
        let title: String
        let consequence: String
        switch failure.category {
        case .piiEmail:
            title = String(localized: "A personal email address")
            consequence = String(localized: "Anyone visiting your site could read it, and spammers collect addresses like this.")
        case .piiPhone:
            title = String(localized: "A phone number")
            consequence = String(localized: "Anyone visiting your site could read it.")
        case .piiSSN:
            title = String(localized: "A Social Security number")
            consequence = String(localized: "Anyone visiting your site could read it and use it to steal an identity.")
        case .exposedToken:
            title = String(localized: "A password or access key")
            consequence = String(localized: "Anyone who found it could use it to get into your accounts.")
        case .thirdPartyScript:
            title = String(localized: "Tracking code from another company")
            consequence = String(localized: "It would share what your visitors do on your site with that company.")
        case .keystaticRoute:
            title = String(localized: "Your editing pages")
            consequence = String(localized: "The pages you use to edit your site would be open to everyone.")
        case .cspMisconfigured:
            title = String(localized: "Missing protection against harmful code")
            consequence = String(localized: "Your site would lose the protection that stops other sites' code from running on your pages.")
        case .embedMediaHotlink:
            title = String(localized: "Media loaded from another service")
            consequence = String(localized: "Embedded media would load straight from that service, which can track your visitors and may stop working if it's removed there.")
        case .wellKnownCollision:
            title = String(localized: "Two files for the same special address")
            consequence = String(localized: "Apps and other sites look for this address, and with two files there, neither can be relied on.")
        case .anglesiteConfigInvalid:
            title = String(localized: "Your site's settings can't be read")
            consequence = String(localized: "Anglesite can't check your site safely until its settings can be read.")
        case .restrictedContentInSource, .restrictedContentInDist:
            title = String(localized: "Content you limited to certain people")
            consequence = String(localized: "It would be visible to everyone, not just the people you chose.")
        case .appOwnedScriptRestored:
            // #1958: the scan's own message is already owner-phrased ("your safety check had been
            // changed; it's been restored"), so it leads; only the file paths stay in detail.
            title = String(localized: "Safety check restored")
            consequence = failure.message
        case .other:
            title = String(localized: "Something that shouldn't go public")
            consequence = String(localized: "The safety check found a problem it can't describe more simply. Show Details says what it found.")
        }
        let detail = failure.category == .appOwnedScriptRestored
            ? gateDetail(message: nil, detail: failure.detail, remediation: failure.remediation, file: nil)
            : gateDetail(message: failure.message, detail: failure.detail, remediation: failure.remediation, file: failure.file)
        return GateFinding(
            title: title,
            consequence: consequence,
            page: failure.file.flatMap(PreDeployCheck.pageAddress(forPublishedFile:)),
            detail: detail
        )
    }

    /// The owner-facing reading of an advisory the pre-deploy scan reported. Warnings never block,
    /// so `consequence` says what the visitor or owner would notice, not why publishing stopped.
    static func gate(_ warning: PreDeployCheck.ScanWarning) -> GateFinding {
        let title: String
        let consequence: String
        switch warning.category {
        case .missingOgImage:
            title = String(localized: "No picture for link previews")
            consequence = String(localized: "When someone shares a page, it will appear without a picture.")
        case .maintenanceOverdue:
            title = String(localized: "Routine upkeep is overdue")
            consequence = String(localized: "Some of your site's regular checkups haven't run for a while.")
        case .seoCritical:
            title = String(localized: "Hard for search engines to list")
            consequence = String(localized: "A page is missing something search engines need in order to show it.")
        case .seoWarning:
            title = String(localized: "Could be easier to find in search")
            consequence = String(localized: "A page is missing something that helps search engines describe it.")
        case .orphanedRoute:
            title = String(localized: "A page nothing links to")
            consequence = String(localized: "Visitors can only reach it if they already know its address.")
        case .mixedContent:
            title = String(localized: "Something loads without protection")
            consequence = String(localized: "Part of a page loads over an unprotected connection, so browsers may block it or warn visitors.")
        case .sriMissing:
            title = String(localized: "Unchecked code from another service")
            consequence = String(localized: "A file loaded from another service isn't checked for tampering before it runs.")
        case .externalLinkRel:
            title = String(localized: "Links to other sites need a safety setting")
            consequence = String(localized: "A link that opens in a new tab could let the other site change your page.")
        case .missingSecurityArtifact, .securityTxtIssue:
            title = String(localized: "Security contact details need attention")
            consequence = String(localized: "People who find a security problem on your site may not know how to tell you.")
        case .mtaStsIssue:
            title = String(localized: "Email protection needs attention")
            consequence = String(localized: "A setting that protects email sent to your address isn't working.")
        case .thirdPartyScript:
            title = String(localized: "Tracking code from another company")
            consequence = String(localized: "It shares what your visitors do on your site with that company.")
        case .wellKnownArtifact:
            title = String(localized: "A special file was left out")
            consequence = String(localized: "A file that apps and other sites look for won't be published.")
        case .other:
            title = String(localized: "Worth a look")
            consequence = String(localized: "The safety check noticed something that may need attention. Show Details says what it found.")
        }
        return GateFinding(
            title: title,
            consequence: consequence,
            page: warning.file.flatMap(PreDeployCheck.pageAddress(forPublishedFile:)),
            detail: gateDetail(message: warning.message, detail: warning.detail, remediation: warning.remediation, file: warning.file)
        )
    }

    /// The scan's technical wording, one line per field, for the Details disclosure. `nil` when
    /// the scan gave nothing beyond the category.
    private static func gateDetail(message: String?, detail: String?, remediation: String?, file: String?) -> String? {
        let lines = [message, detail, remediation, file]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    // MARK: Backup success

    /// "Backed up to GitHub" — the destination as the owner knows it, never the remote URL or
    /// the branch name.
    static func backupDestination(remote: String) -> String {
        OwnerPhrasing.backupDestinationLabel(remote: remote)
    }
}
