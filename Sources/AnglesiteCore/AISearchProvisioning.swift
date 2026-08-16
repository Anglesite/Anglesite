import Foundation

/// A provisioned Cloudflare AI Search instance.
public struct AISearchInstance: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// AI Search create failures that carry an owner-actionable fix beyond the generic
/// ``CloudflareError`` mapping. A separate error type (rather than a new `CloudflareError`
/// case) keeps the blast radius to this feature — roughly ten call sites switch over
/// `CloudflareError` exhaustively and none of them can hit this condition (#1486).
public enum AISearchProvisionError: Error, Equatable, Sendable {
    /// Cloudflare rejected the create with error code 7028 (`missing_sitemap`): the source
    /// website has no reachable sitemap. For an Anglesite site this virtually always means
    /// the site hasn't had its first deploy yet, so the fix is "deploy first" — the sitemap
    /// (#982) is in every build but isn't live at the domain until a deploy publishes it.
    case missingSitemap
}

/// Provisions Cloudflare AI Search instances. Kept separate from `CloudflareWriting` — that
/// protocol has five conformers across the test suite, and this is the only feature that needs
/// this call.
public protocol AISearchProvisioning: Sendable {
    /// Creates an AI Search instance backed by a website crawler for `domain`, resolving the
    /// caller's Cloudflare account internally (mirrors `attachWorkersCustomDomain`'s pattern).
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance
}
