import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `DeployTargetKind` (#1683) — the lossy classifier that turns
/// `DomainConfig.deployTarget`'s open string into the closed set of hosts the app knows how to
/// reason about. Deliberately non-failable: an unrecognized or absent value has to resolve to
/// `.cloudflare`, matching `DomainConfig.deployTarget`'s documented "nil means cloudflare"
/// contract and `DeployTargetSelection`'s conformer fallback.
struct DeployTargetKindTests {
    @Test("the Cloudflare target identifier resolves to .cloudflare")
    func cloudflareIdentifier() {
        #expect(DeployTargetKind(identifier: CloudflareDeployTarget.id) == .cloudflare)
        #expect(DeployTargetKind(identifier: "cloudflare") == .cloudflare)
    }

    @Test("the GitHub Pages target identifier resolves to .githubPages")
    func githubPagesIdentifier() {
        #expect(DeployTargetKind(identifier: GitHubPagesDeployTarget.id) == .githubPages)
    }

    @Test("an absent declaration resolves to .cloudflare")
    func absentIdentifier() {
        #expect(DeployTargetKind(identifier: nil) == .cloudflare)
    }

    @Test("an unrecognized declaration resolves to .cloudflare")
    func unrecognizedIdentifier() {
        #expect(DeployTargetKind(identifier: "netlify") == .cloudflare)
        #expect(DeployTargetKind(identifier: "") == .cloudflare)
        #expect(DeployTargetKind(identifier: "GitHubPages") == .cloudflare)
    }
}
