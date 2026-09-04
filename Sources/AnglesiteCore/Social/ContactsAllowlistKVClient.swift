import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare Workers KV client for the #1567 contacts allowlist push. Writes the site's
/// normalized me-URL set (`ContactStore.knownMeURLs()`) as a single JSON array under
/// `contacts:allowlist` in the already-provisioned `SOCIAL_KV` namespace — the future
/// authenticated-read gate (epic #963 slice 4) reads this key from the Worker side. Follows the
/// same injectable-transport DI pattern as `InboxKVClient`/`HTTPCloudflareClient` — no Keychain
/// coupling, token passed in at init.
public struct ContactsAllowlistKVClient: Sendable {
    private static let key = "contacts:allowlist"

    private let baseURL: String
    private let accountID: String
    private let namespaceID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        namespaceID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.namespaceID = namespaceID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Replaces the whole `contacts:allowlist` value with `meURLs`, sorted for a deterministic
    /// request body. Whole-set replace, not an incremental add/remove — the caller
    /// (`ContactsAllowlistSync`) always supplies the complete current set, so this single call
    /// doubles as both "push on change" and "reconcile."
    public func putAllowlist(_ meURLs: Set<String>) async throws {
        let body = try JSONEncoder().encode(meURLs.sorted())
        let valueURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(Self.key)"
        guard let url = URL(string: valueURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
    }
}
