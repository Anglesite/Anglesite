import Foundation

/// Pushes the site's blogroll domains (`BlogrollPlan.build(projectRoot:)`) to the Worker's
/// `SOCIAL_KV` store under `vouch:trusted-domains` (#1597) — the Vouch trust list. Deploy-time
/// only (unlike `ContactsAllowlistSync`, no immediate-on-edit trigger): the list doesn't need
/// real-time freshness, and this avoids hooking every blogroll-editing code path. Both the
/// deploy trigger and this whole-set-replace `push` make `src/content/blogroll/` the always-
/// authoritative source: there's no diffing, only an unconditional overwrite, so a missed push
/// self-heals on the next deploy.
public enum BlogrollTrustSync {
    /// Extracts each entry's hostname, deduplicates, and replaces `client`'s
    /// `vouch:trusted-domains` value with the result. An empty blogroll still pushes an empty
    /// array — never skipped — so removing every entry actually clears the trust list rather
    /// than leaving a stale one in place. Never throws — a failure (network, auth,
    /// provisioning) is logged and otherwise invisible; the next deploy retries with the
    /// current state.
    public static func push(entries: [BlogrollPlan.Entry], client: BlogrollTrustKVClient) async {
        do {
            // Lowercased to match `vouch-trust.ts`'s `isTrustedVouchDomain`, which is looked up
            // against a hostname already lowercased by `verifyVouch` — a blogroll entry written
            // in mixed case (e.g. `https://Alice.Example/`) must still match.
            let domains = Set(entries.compactMap { $0.url.host?.lowercased() })
            try await client.putTrustedDomains(domains)
        } catch {
            await LogCenter.shared.append(
                source: "BlogrollTrustSync", stream: .stderr,
                text: "Failed to push blogroll trust list to SOCIAL_KV: \(error). Will retry on "
                    + "the next deploy.")
        }
    }

    /// Reads the site's `SiteSettings` and Cloudflare API token from `secretStore`; no-ops (no
    /// network call) unless `SOCIAL_KV` has been provisioned
    /// (`provisionedWorkerResources.kvNamespaceID`) and a token is available. `siteDirectory` is
    /// the package's `Source/` directory (`AnglesitePackage.sourceURL`) — `BlogrollPlan` reads
    /// blogroll entries from there; `configDirectory` is the sibling `Config/` directory.
    public static func pushIfConfigured(
        siteDirectory: URL,
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

        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        let client = BlogrollTrustKVClient(
            accountID: accountID, namespaceID: namespaceID, apiToken: token, baseURL: baseURL, transport: transport)
        await push(entries: plan.entries, client: client)
    }
}
