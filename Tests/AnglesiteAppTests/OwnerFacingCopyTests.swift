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
}
