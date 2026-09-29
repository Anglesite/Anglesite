import Foundation

/// Orchestrates #362's "pull the Worker's verified webmention inbox and snapshot it into the
/// site's git working copy" step: query D1 (`WebmentionInboxD1Client`), reconcile + commit
/// (`ReceivedInteractionCommitter`). This is the counterpart to #587's `InboxSubmissionSync`, but
/// there is no staging store to drain — D1 remains the permanent operational store, so every call
/// reconciles against the *current full inbox*, not just what's new since last time. Designed to
/// be called once per site-open (`PreviewModel.open(site:)`), alongside `InboxSubmissionSync`.
public enum ReceivedInteractionSync {
    /// Maps one D1 row to the git-canonical schema. Returns `nil` (skip, don't fail the whole
    /// pull) when `source`/`target` aren't parseable URLs, or the id fails
    /// `ReceivedInteraction`'s path-traversal guard — a malformed row shouldn't block every other
    /// mention. An unrecognized/absent `interactionType` defaults to `.mention`, and an absent
    /// `publishedAt` falls back to `verifiedAt`, mirroring `InboxStore.list()`'s own defaults on
    /// the Worker side (`packages/webmention/src/inbox.ts`) — including rows written by
    /// `@dwk/webmention` versions published before the mf2-enrichment columns existed.
    static func makeInteraction(from mention: WebmentionInboxD1Client.Mention) -> ReceivedInteraction? {
        guard let source = URL(string: mention.source), let target = URL(string: mention.target) else { return nil }
        let interactionType = mention.interactionType.flatMap(ReceivedInteraction.InteractionType.init(rawValue:)) ?? .mention
        let author: ReceivedInteraction.Author? =
            (mention.authorName != nil || mention.authorURL != nil || mention.authorPhoto != nil)
            ? .init(
                name: mention.authorName,
                url: mention.authorURL.flatMap(URL.init(string:)),
                photo: mention.authorPhoto.flatMap(URL.init(string:)))
            : nil
        // A vouch requires both the URL and the verified flag from the row — if either is missing
        // (no vouch was sent, or a malformed vouchURL somehow made it through), there is no vouch.
        let vouch: ReceivedInteraction.Vouch? = {
            guard let vouchURLString = mention.vouchURL, let vouchVerified = mention.vouchVerified,
                  let vouchURL = URL(string: vouchURLString)
            else { return nil }
            return ReceivedInteraction.Vouch(url: vouchURL, verified: vouchVerified)
        }()
        let verifiedAt = Double(mention.verifiedAt) / 1000
        let publishedAt = Double(mention.publishedAt ?? mention.verifiedAt) / 1000
        return try? ReceivedInteraction(
            id: mention.id, type: .webmention, source: source, target: target,
            interactionType: interactionType, author: author, content: mention.content,
            published: Date(timeIntervalSince1970: publishedAt),
            verified: Date(timeIntervalSince1970: verifiedAt), verificationStatus: .verified,
            vouch: vouch)
    }

    /// Queries `client` for the full current inbox, maps it to `ReceivedInteraction`, and
    /// reconciles it into `siteDirectory`. Returns 0 (never throws) if the D1 query failed, so
    /// callers simply re-attempt on the next site-open rather than surfacing a transient network
    /// error. An empty inbox still reconciles (proceeds to `commit`) rather than short-circuiting,
    /// so previously-snapshotted mentions that were later unverified/removed still get cleaned up.
    ///
    /// With a `screener`, each interaction passes through the spam/abuse gate first
    /// (``InteractionScreener/screen(_:isAlreadyPublished:ownerRuling:)``): only the `published`
    /// partition reaches the commit, every decision is recorded in `ledger`, and a held
    /// interaction stays in D1 for the owner's ruling. Without one (the default, and the app's
    /// wiring until a decision model ships), behavior is exactly the pre-screening path.
    ///
    /// - Parameters:
    ///   - client: The site's D1 inbox.
    ///   - siteDirectory: The site's `Source/` working copy.
    ///   - screener: The gate, or `nil` to publish everything.
    ///   - ledger: Where decisions and owner rulings live; only consulted when `screener` is set.
    /// - Returns: How many snapshot files the resulting commit wrote or deleted.
    public static func pullAndCommit(
        client: WebmentionInboxD1Client, siteDirectory: URL,
        screener: InteractionScreener? = nil, ledger: InteractionScreeningLedger? = nil
    ) async -> Int {
        guard var interactions = await fetchInteractions(client: client) else { return 0 }
        if let screener {
            let interactionsDir = siteDirectory.appendingPathComponent("data/interactions", isDirectory: true)
            let rulings = ledger?.load().rulings ?? [:]
            let outcome = await screener.screen(
                interactions,
                isAlreadyPublished: { id in
                    FileManager.default.fileExists(atPath: interactionsDir.appendingPathComponent("\(id).json").path)
                },
                ownerRuling: { id in rulings[id] })
            ledger?.record(outcome.decisions)
            interactions = outcome.published
        }
        let committedIDs = await ReceivedInteractionCommitter.commit(
            interactions: interactions, scopedTo: [.webmention], into: siteDirectory)
        return committedIDs.count
    }

    /// Queries `client` for the full current verified inbox, mapped to `ReceivedInteraction`
    /// (malformed rows skipped per `makeInteraction(from:)`). `nil` when the D1 query failed —
    /// distinct from an empty inbox, so callers can tell "nothing there" from "couldn't ask".
    public static func fetchInteractions(client: WebmentionInboxD1Client) async -> [ReceivedInteraction]? {
        guard let mentions = try? await client.listVerifiedMentions() else { return nil }
        return mentions.compactMap(Self.makeInteraction(from:))
    }

    /// Reads the site's `SiteSettings` and the Cloudflare API token from `secretStore`; no-ops
    /// (returns 0, no network call) unless a D1 database has been provisioned
    /// (`provisionedWorkerResources.d1DatabaseID`, set once the webmention receive Worker has been
    /// provisioned — see `SocialWorkerProvisionCommand`) and a token is available.
    /// `configDirectory` is the package's `Config/` directory (`AnglesitePackage.configURL`), a
    /// sibling of `siteDirectory` (`AnglesitePackage.sourceURL`); with a `screener`, it also
    /// hosts the ``InteractionScreeningLedger``.
    public static func pullAndCommitIfConfigured(
        siteDirectory: URL,
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport,
        screener: InteractionScreener? = nil
    ) async -> Int {
        guard let client = await makeClientIfConfigured(
            configDirectory: configDirectory, secretStore: secretStore, baseURL: baseURL, transport: transport)
        else { return 0 }
        let ledger = screener == nil ? nil : InteractionScreeningLedger(configDirectory: configDirectory)
        return await pullAndCommit(client: client, siteDirectory: siteDirectory, screener: screener, ledger: ledger)
    }

    /// The read-only counterpart of ``pullAndCommitIfConfigured(siteDirectory:configDirectory:secretStore:baseURL:transport:screener:)``
    /// for the moderation queue (#2066): the current verified inbox with nothing written to git.
    /// `nil` when the site has no provisioned inbox, no token, or the query failed.
    public static func fetchInteractionsIfConfigured(
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async -> [ReceivedInteraction]? {
        guard let client = await makeClientIfConfigured(
            configDirectory: configDirectory, secretStore: secretStore, baseURL: baseURL, transport: transport)
        else { return nil }
        return await fetchInteractions(client: client)
    }

    /// Resolves the D1 client for a site, or `nil` when the inbox isn't provisioned
    /// (`provisionedWorkerResources.d1DatabaseID` unset), no Cloudflare token is available, or
    /// the account lookup failed — the shared gate for both entry points above.
    private static func makeClientIfConfigured(
        configDirectory: URL,
        secretStore: any SecretStore,
        baseURL: String,
        transport: @escaping CloudflareTransport
    ) async -> WebmentionInboxD1Client? {
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let databaseID = settings.provisionedWorkerResources?.d1DatabaseID, !databaseID.isEmpty
        else { return nil }
        guard let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty
        else { return nil }
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return nil }
        return WebmentionInboxD1Client(
            accountID: accountID, databaseID: databaseID, apiToken: token, baseURL: baseURL, transport: transport)
    }
}
