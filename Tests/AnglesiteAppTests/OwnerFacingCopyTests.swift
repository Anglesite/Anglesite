import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// The app-side half of #1963 (D1): every owner-facing summary `OwnerFacingCopy` produces must
/// be free of the vocabulary `scripts/check-localization-catalog.sh` forbids, and the raw
/// reason must survive in `detail` for the Details disclosure.
@Suite("OwnerFacingCopy")
struct OwnerFacingCopyTests {
    /// Mirrors OWNER_VOCABULARY in scripts/check-localization-catalog.sh.
    private static let forbidden = try! NSRegularExpression(
        pattern: #"\bgit\b|\bcommit(?:s|ted|ting)?\b|\bpush(?:es|ed|ing)?\b|\bpull(?:s|ed|ing)?\b|\bbranch(?:es)?\b|\bSHA\b|packfile|\bbundles?\b|\bnpm\b|\bsemver\b|package\.json|\bwrangler\b|\bMCP\b|\bdev[ -]server\b|\bAstro\b|\.git\b|\.json\b|\.toml\b|\bSource/|\bConfig/|\bexit code\b|\(exit "#,
        options: [.caseInsensitive]
    )

    private static func usesForbiddenVocabulary(_ text: String) -> Bool {
        forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let syncReasons = [
        "waiting for iCloud to finish syncing this site's history before pushing.",
        "this site has no commits yet — nothing to sync.",
        "the working tree has uncommitted changes — commit them before syncing.",
        "the repo is in a detached-HEAD state — check out a branch before syncing.",
        "couldn't merge sync/main into main: conflicts",
        "the artifact's packfile is corrupt: missing the packfile's \"PACK\" signature",
        "couldn't write the sync artifact into the package: disk full",
        "couldn't fetch the synced history: timeout",
        "something entirely new happened",
    ]

    @Test("sync summaries never use tool vocabulary and keep the raw reason as detail", arguments: syncReasons)
    func syncSummaryIsOwnerPhrased(reason: String) {
        let failure = OwnerFacingCopy.sync(reason: reason)
        #expect(!failure.summary.isEmpty)
        #expect(!Self.usesForbiddenVocabulary(failure.summary), "summary leaked vocabulary: \(failure.summary)")
        #expect(failure.detail == reason)
    }

    private static let backupReasons: [(String, Int32?)] = [
        ("this site isn't a git repository — run `git init` and add an `origin` remote", nil),
        ("`git push` failed (exit 128): fatal: unable to access", 128),
        ("`git commit` failed (exit 128): Author identity unknown", 128),
        ("`git status` exited 128", 128),
        ("backup canceled", nil),
        ("mystery", 7),
    ]

    @Test("backup summaries never use tool vocabulary; the exit code moves to detail", arguments: backupReasons)
    func backupSummaryIsOwnerPhrased(reason: String, exitCode: Int32?) throws {
        let failure = OwnerFacingCopy.backup(reason: reason, exitCode: exitCode)
        #expect(!failure.summary.isEmpty)
        #expect(!Self.usesForbiddenVocabulary(failure.summary), "summary leaked vocabulary: \(failure.summary)")
        if reason == "backup canceled" {
            #expect(failure.detail == nil)
        } else {
            let detail = try #require(failure.detail)
            #expect(detail.hasPrefix(reason))
            if let exitCode, !reason.contains("\(exitCode)") {
                #expect(detail.contains("exit code \(exitCode)"))
            }
        }
    }

    @Test("operation summaries translate the build/wrangler shapes and pass owner-phrased reasons through")
    func operationSummaries() {
        let build = OwnerFacingCopy.operation(reason: "npm run build failed (exit 1)", exitCode: 1)
        #expect(!Self.usesForbiddenVocabulary(build.summary))
        #expect(build.detail == "npm run build failed (exit 1)")

        let wrangler = OwnerFacingCopy.operation(reason: "wrangler exited with code 1", exitCode: 1)
        #expect(!Self.usesForbiddenVocabulary(wrangler.summary))
        #expect(wrangler.detail == "wrangler exited with code 1")

        // Regression (#1963 review): a "the deploy likely succeeded" outcome must not read as a
        // rejection on the primary surface.
        let unconfirmedReason = "wrangler exited successfully (code 0), but no deployed URL could be found in its output — the deploy likely succeeded; check the deploy log for the URL"
        let unconfirmed = OwnerFacingCopy.operation(reason: unconfirmedReason, exitCode: 0)
        #expect(!Self.usesForbiddenVocabulary(unconfirmed.summary))
        #expect(!unconfirmed.summary.localizedCaseInsensitiveContains("didn't accept"))
        #expect(unconfirmed.detail == unconfirmedReason)

        let owner = "Worker name \"site\" is already in use on your Cloudflare account — rename it in the app and publish again."
        let passthrough = OwnerFacingCopy.operation(reason: owner, exitCode: nil)
        #expect(passthrough.summary == owner)
        #expect(passthrough.detail == nil, "nothing was hidden, so there's nothing to disclose")

        let withExit = OwnerFacingCopy.operation(reason: "audit runner crashed", exitCode: 3)
        #expect(withExit.summary == "audit runner crashed")
        #expect(withExit.detail == "audit runner crashed (exit code 3)")
    }

    @Test("backup destination is the host the owner knows")
    func backupDestination() {
        #expect(OwnerFacingCopy.backupDestination(remote: "https://github.com/me/site.git") == "GitHub")
    }

    // MARK: Safety check (#2211)

    /// Output paths and scan vocabulary the primary lines of the blocked-publish sheet must not
    /// show — they belong under Show Details.
    private static func leaksScanWording(_ text: String) -> Bool {
        ["dist/", "_headers", ".gitignore", ".html", "CSP", "PII", "Content-Security-Policy"]
            .contains { text.contains($0) }
    }

    @Test("every blocker reads in the owner's terms and keeps the scan's wording as detail",
          arguments: PreDeployCheck.ScanFailure.Category.allCases.filter { $0 != .appOwnedScriptRestored })
    func gateFailureIsOwnerPhrased(category: PreDeployCheck.ScanFailure.Category) {
        let failure = PreDeployCheck.ScanFailure(
            category: category,
            message: "dist/_headers has no Content-Security-Policy.",
            file: "dist/contact/index.html",
            remediation: "Add .env to .gitignore before publishing."
        )
        let finding = OwnerFacingCopy.gate(failure)
        #expect(!finding.title.isEmpty)
        #expect(!finding.consequence.isEmpty)
        for line in [finding.title, finding.consequence] {
            #expect(!Self.usesForbiddenVocabulary(line), "leaked vocabulary: \(line)")
            #expect(!Self.leaksScanWording(line), "leaked scan wording: \(line)")
        }
        #expect(finding.page == "/contact/")
        let detail = finding.detail
        #expect(detail?.contains(failure.message) == true)
        #expect(detail?.contains("Add .env to .gitignore") == true)
        #expect(detail?.contains("dist/contact/index.html") == true)
    }

    @Test("every warning reads in the owner's terms and keeps the scan's wording as detail",
          arguments: PreDeployCheck.ScanWarning.Category.allCases)
    func gateWarningIsOwnerPhrased(category: PreDeployCheck.ScanWarning.Category) {
        let warning = PreDeployCheck.ScanWarning(category: category, message: "dist/blog/index.html lacks og:image", file: "dist/blog/index.html")
        let finding = OwnerFacingCopy.gate(warning)
        for line in [finding.title, finding.consequence] {
            #expect(!line.isEmpty)
            #expect(!Self.usesForbiddenVocabulary(line), "leaked vocabulary: \(line)")
            #expect(!Self.leaksScanWording(line), "leaked scan wording: \(line)")
        }
        #expect(finding.page == "/blog/")
        #expect(finding.detail?.contains(warning.message) == true)
    }

    @Test("a restored safety check leads with the scan's owner-phrased message and hides paths")
    func gateRestoredScriptLeadsWithMessage() {
        let failure = PreDeployCheck.ScanFailure(
            category: .appOwnedScriptRestored,
            message: "Your site's safety check had been changed, so Anglesite restored it.",
            file: "scripts/pre-deploy-check.ts",
            detail: "scripts/pre-deploy-check.ts"
        )
        let finding = OwnerFacingCopy.gate(failure)
        #expect(finding.consequence == failure.message)
        #expect(finding.page == nil)
        #expect(finding.detail == "scripts/pre-deploy-check.ts")
    }

    @Test("a finding off any page has no address, and an empty scan gives no detail")
    func gateFindingWithoutPage() {
        let finding = OwnerFacingCopy.gate(PreDeployCheck.ScanFailure(category: .other, message: "  ", file: nil))
        #expect(finding.page == nil)
        #expect(finding.detail == nil)
    }
}
