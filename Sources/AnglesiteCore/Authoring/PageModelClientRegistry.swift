import Foundation

/// Per-siteID registry of live `PageModelClient`s — the `get_page_model` counterpart to
/// ``EditRouterRegistry``'s `apply_edit` routers.
///
/// Each open `SiteWindow`'s `PreviewModel` registers a `PageModelClient` bound to its runtime's
/// MCP connection here under the site's id, alongside the matching `EditRouterRegistry`
/// registration (`PreviewModel.open()`/`close()`). Intents that need to read a page's structured
/// model before building a structural edit (`AddEffectIntent`, #768) read it back the same way
/// `IntentEditBridge` reads `EditRouterRegistry` — so a Siri-driven placement resolves against the
/// live page tree while the site's window is open. The registry lives in `AnglesiteCore` so both
/// layers can see it; `AnglesiteIntents` doesn't need to know about WKWebView or `PreviewModel`.
///
/// Single shared instance — `PageModelClientRegistry.shared`. `PageModelClient` is a `Sendable`
/// value type, so entries are stored by value, not by reference.
///
/// Last-writer-wins on duplicate siteID registration, mirroring `EditRouterRegistry`.
public actor PageModelClientRegistry {
    /// The single process-wide registry — the only instance production code should touch
    /// (see `init`'s note on why external construction is blocked).
    public static let shared = PageModelClientRegistry()

    private var clients: [String: PageModelClient] = [:]

    /// `internal` (not `public`) — production callers go through `.shared`; tests reach in
    /// via `@testable import AnglesiteCore` to construct isolated instances. Prevents
    /// accidental external instances from silently routing model fetches to the wrong site.
    internal init() {}

    /// Registers (or replaces — last-writer-wins, see the type doc) the live client for a site.
    /// Pair with ``unregister(siteID:)`` around the owner's lifecycle, or the registration
    /// outlives the window that registered it.
    public func register(_ client: PageModelClient, for siteID: String) {
        clients[siteID] = client
    }

    /// Removes a site's client. Safe to call for an unknown siteID (no-op), so owners can
    /// unregister unconditionally on teardown.
    public func unregister(siteID: String) {
        clients.removeValue(forKey: siteID)
    }

    /// The live client for a site, or `nil` when no window has that site open — callers
    /// (intents) treat `nil` as "site not open" and tell the user, rather than falling back
    /// to a client that couldn't reach the preview anyway.
    public func pageModelClient(for siteID: String) -> PageModelClient? {
        clients[siteID]
    }

    /// All currently-registered siteIDs. Surfaced for tests + diagnostics; production callers
    /// always know the siteID they're asking about.
    public func knownSiteIDs() -> Set<String> {
        Set(clients.keys)
    }
}
