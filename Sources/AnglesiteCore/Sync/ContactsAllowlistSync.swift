import Foundation

/// Pushes the site's contact allowlist (`ContactStore.knownMeURLs()`) to the Worker's
/// `SOCIAL_KV` store (#1567) — both on a contact add/remove and, as the consistency backstop, on
/// every deploy. Both triggers call the same whole-set-replace `push`, so `Config/contacts.json`
/// is always the authoritative source: there's no diffing, only an unconditional overwrite.
public enum ContactsAllowlistSync {
    /// Reads `store`'s current me-URL set and replaces `client`'s `contacts:allowlist` value with
    /// it. Never throws — a failure (network, auth, provisioning) is logged and otherwise
    /// invisible; the next successful call (the next contact change, or the next deploy) retries
    /// with the current state, so a missed push self-heals rather than needing a retry queue.
    public static func push(store: ContactStore, client: ContactsAllowlistKVClient) async {
        do {
            let meURLs = try await store.knownMeURLs()
            try await client.putAllowlist(meURLs)
        } catch {
            await LogCenter.shared.append(
                source: "ContactsAllowlistSync", stream: .stderr,
                text: "Failed to push contacts allowlist to SOCIAL_KV: \(error). Will retry on the "
                    + "next contact change or deploy.")
        }
    }

    /// Reads the site's `SiteSettings` and Cloudflare API token from `secretStore`; no-ops (no
    /// network call) unless `SOCIAL_KV` has been provisioned
    /// (`provisionedWorkerResources.kvNamespaceID`) and a token is available — i.e. the site has
    /// never been deployed yet. `configDirectory` is the package's `Config/` directory
    /// (`AnglesitePackage.configURL`).
    public static func pushIfConfigured(
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async {
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let namespaceID = settings.provisionedWorkerResources?.kvNamespaceID, !namespaceID.isEmpty
        else { return }
        guard let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty
        else { return }
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return }

        let store = ContactStore(configDirectory: configDirectory)
        let client = ContactsAllowlistKVClient(
            accountID: accountID, namespaceID: namespaceID, apiToken: token, baseURL: baseURL, transport: transport)
        await push(store: store, client: client)
    }
}
