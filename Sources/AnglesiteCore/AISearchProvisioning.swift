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

    /// Cloudflare rejected the create with error code 7022
    /// (`ai_search_with_this_name_already_exist`): an instance with this id already exists in
    /// the namespace. `instanceID` is derived deterministically from the domain
    /// (`AISearchExecutor.namespaceID(for:)`), so this is expected on a re-run of the wizard
    /// after a prior partial or complete success — callers should treat it as "already
    /// provisioned" rather than a failure (#1478).
    case instanceAlreadyExists

    /// The existing instance behind an ``instanceAlreadyExists`` response was created for a
    /// *different* domain than the one being provisioned. `namespaceID(for:)`'s dot-to-dash
    /// normalization isn't injective (`"a.b.com"` and `"a-b.com"` collide), so an id collision
    /// is possible without this actually being a re-run for the same site — callers must not
    /// treat this as success (#1478 review).
    case instanceIDCollision
}

/// Provisions Cloudflare AI Search instances. Kept separate from `CloudflareWriting` — that
/// protocol has five conformers across the test suite, and this is the only feature that needs
/// this call.
public protocol AISearchProvisioning: Sendable {
    /// Creates an AI Search instance backed by a website crawler for `domain`, resolving the
    /// caller's Cloudflare account internally (mirrors `attachWorkersCustomDomain`'s pattern).
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance

    /// Fetches the configured source (crawled domain) of an existing AI Search instance by id.
    /// Used to verify, after an ``AISearchProvisionError/instanceAlreadyExists`` response, that
    /// the existing instance really was created for the domain being provisioned rather than a
    /// different one that happens to collide under `namespaceID(for:)`'s normalization (#1478).
    func aiSearchInstanceSource(instanceID: String, apiToken: String) async throws -> String
}
