import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Best-effort post-deploy pass that publishes `site.standard.graph.subscription` records for
/// the site's blogroll (#1483) — see
/// `docs/superpowers/specs/2026-08-15-blogroll-standard-site-graph-design.md`. Modeled directly
/// on ``StandardSitePublishCommand``: never throws into the deploy result, ledgers in `Config/`,
/// logs to the debug pane, per-site serialized.
///
/// Reuses the site's Bluesky POSSE credential — no credential, or no real deployed `SITE_URL`
/// yet, and the pass silently no-ops, matching ``StandardSitePublishCommand``.
public actor StandardSiteGraphPublishCommand {
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let credentials: POSSECredentialResolver.Provider
    private let transport: POSSEHTTPTransport
    private let thirdPartyTransport: POSSEHTTPTransport
    private let logCenter: LogCenter
    private let now: @Sendable () -> Date
    private var inFlight: [String: InFlight] = [:]

    /// `transport` above is only ever pointed at this app's own atproto PDS. Feed discovery and
    /// standard.site resolution instead fetch whatever URL the owner typed as a blogroll entry —
    /// third-party, untrusted, and potentially slow or hostile — so they get a separate,
    /// capped/time-bounded transport (#1483 final review, Fix 2) rather than reusing
    /// `URLSession.shared` via the PDS transport.
    public init(
        credentials: @escaping POSSECredentialResolver.Provider = POSSECredentialResolver.provider(),
        transport: @escaping POSSEHTTPTransport = POSSESyndicationCommand.defaultTransport,
        thirdPartyTransport: @escaping POSSEHTTPTransport = StandardSiteGraphPublishCommand.defaultThirdPartyTransport,
        logCenter: LogCenter = .shared,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.thirdPartyTransport = thirdPartyTransport
        self.logCenter = logCenter
        self.now = now
    }

    /// Runs one post-deploy blogroll graph publish pass for a site. Runs per site are serialized
    /// (a newer call chains behind the in-flight one) so two overlapping deploys can't race the
    /// ledger; distinct sites proceed concurrently.
    ///
    /// Never throws: every per-entry failure is logged and skipped, and the pass as a whole
    /// no-ops when the site has no Bluesky credential or no real deployed `SITE_URL` yet.
    public func publish(siteID: String, siteDirectory: URL, configDirectory: URL) async {
        let previous = inFlight[siteID]?.task
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            _ = await previous?.value
            await self?.perform(siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory)
        }
        inFlight[siteID] = InFlight(id: id, task: task)
        await task.value
        if inFlight[siteID]?.id == id {
            inFlight[siteID] = nil
        }
    }

    private func perform(siteID: String, siteDirectory: URL, configDirectory: URL) async {
        let source = "standardsitegraph:\(siteID)"
        guard let bluesky = credentials(siteID, configDirectory).bluesky else { return }
        guard let siteURLString = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory),
              siteURLString != "https://example.com"
        else { return }

        // Unlike the two gates above (not yet configured — nothing for the owner to act on), this
        // one is a deliberate choice made in Site Settings (#1233), so skipping it is logged
        // rather than silent — matches `StandardSitePublishCommand`'s equivalent gate.
        let settings = (try? SiteConfigStore.read(from: configDirectory)) ?? SiteSettings()
        guard settings.publishToAtmosphere ?? true else {
            await logCenter.append(
                source: source, stream: .stdout,
                text: "standardsitegraph: skipped — \"Publish posts to the Atmosphere\" is off in Site Settings"
            )
            return
        }

        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        var ledger = StandardSiteGraphPublishLog.load(from: configDirectory) ?? StandardSiteGraphPublishLog()

        // No early return on an empty plan: the owner may have just deleted their *last*
        // blogroll entry, in which case `plan.entries` is empty but the ledger still holds one
        // stale entry that the unpublish diff below must still clean up. An empty plan with an
        // empty ledger still pays for one `createSession` call it didn't strictly need — a minor
        // cost, not worth the risk of silently skipping unpublish on the last-entry-removed path
        // (this exact scenario is covered by the `unpublishesRemovedEntry` test in Step 1, which
        // calls `makeSite(blogroll: [:])` — an early return here would make that test fail).

        let session: AtprotoPutRecordClient.Session
        do {
            session = try await AtprotoPutRecordClient.createSession(credentials: bluesky, transport: transport)
        } catch {
            await logError("couldn't sign in to publish blogroll: \(error.localizedDescription)", source: source)
            return
        }

        var publishedCount = 0
        var skippedCount = 0
        var failedCount = 0

        for entry in plan.entries {
            // Feed discovery runs unconditionally, before the standard.site resolve guard below —
            // most blogroll targets don't run standard.site at all (that's the expected common
            // case), so gating discovery behind a successful resolve would make it never run for
            // an ordinary blogroll (#1483 final review, Fix 1).
            if entry.feedURL == nil {
                if let discovered = try? await FeedEndpointDiscovery.discover(target: entry.url, transport: thirdPartyTransport) {
                    writeBackFeedURL(discovered, entry: entry, siteDirectory: siteDirectory)
                }
            }

            guard let publicationURI = await StandardSitePublicationResolver.resolve(homepage: entry.url, transport: thirdPartyTransport) else {
                skippedCount += 1
                await logCenter.append(
                    source: source, stream: .stdout,
                    text: "standardsitegraph: skipped \(entry.url.absoluteString) — no site.standard.publication found"
                )
                continue
            }

            let rkey = "anglesite-\(POSSEStableKey.make("\(siteID)\n\(entry.sourceFile)"))"
            let record = StandardSiteGraphSubscriptionRecord(publication: publicationURI, createdAt: iso8601(now()))
            let result: AtprotoPutRecordClient.Result
            do {
                result = try await AtprotoPutRecordClient.putRecord(
                    collection: "site.standard.graph.subscription", rkey: rkey, record: record,
                    pdsURL: bluesky.pdsURL, session: session, transport: transport
                )
            } catch {
                failedCount += 1
                await logError("couldn't publish \(entry.sourceFile): \(error.localizedDescription)", source: source)
                continue
            }
            // The record write above already succeeded — a failure past this point is a local
            // ledger problem, not a publish failure, so it gets its own message rather than
            // falling into a shared catch that would misreport a live record as unpublished.
            ledger.record(.init(sourceFile: entry.sourceFile, uri: result.uri, lastPublishedAt: now()))
            do {
                try ledger.save(to: configDirectory)
            } catch {
                failedCount += 1
                await logError(
                    "published \(entry.sourceFile) as \(result.uri), but its ledger update failed: \(error.localizedDescription)",
                    source: source
                )
                continue
            }
            publishedCount += 1
            await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: published \(entry.sourceFile) as \(result.uri)")
        }

        // Unpublish: a ledgered entry whose sourceFile no longer appears in the current plan
        // means the owner removed that blogroll entry. Diff first, delete after, so a
        // `deleteRecord` failure leaves the ledger entry in place for the next pass to retry
        // rather than losing track of a record that's still live.
        let currentSourceFiles = Set(plan.entries.map(\.sourceFile))
        let staleEntries = ledger.entries.filter { !currentSourceFiles.contains($0.sourceFile) }
        var unpublishedCount = 0
        for staleEntry in staleEntries {
            guard let rkey = staleEntry.uri.split(separator: "/").last else { continue }
            do {
                try await AtprotoPutRecordClient.deleteRecord(
                    collection: "site.standard.graph.subscription", rkey: String(rkey),
                    pdsURL: bluesky.pdsURL, session: session, transport: transport
                )
            } catch {
                failedCount += 1
                await logError("couldn't unpublish \(staleEntry.sourceFile): \(error.localizedDescription)", source: source)
                continue
            }
            ledger.entries.removeAll { $0.sourceFile == staleEntry.sourceFile }
            do {
                try ledger.save(to: configDirectory)
            } catch {
                await logError(
                    "unpublished \(staleEntry.sourceFile), but its ledger update failed: \(error.localizedDescription)",
                    source: source
                )
                continue
            }
            unpublishedCount += 1
            await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: unpublished \(staleEntry.sourceFile)")
        }

        await logCenter.append(
            source: source, stream: .stdout,
            text: "standardsitegraph: done — published \(publishedCount), skipped \(skippedCount), "
                + "unpublished \(unpublishedCount), failed \(failedCount)"
        )
    }

    /// Writes a discovered feed URL back into `entry`'s own content file (#1483). Best-effort:
    /// a read/write failure here is a local-file problem, not a publish failure, so it's silently
    /// skipped (see the `catch` below) rather than aborting the entry's record publish.
    private func writeBackFeedURL(_ feedURL: URL, entry: BlogrollPlan.Entry, siteDirectory: URL) {
        let fileURL = siteDirectory.appendingPathComponent(entry.sourceFile)
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let updated = BlogrollFeedFrontmatter.setting(feedURL: feedURL.absoluteString, in: contents)
        guard updated != contents else { return }
        do {
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort; no log line — matches how `persistIdentity` in
            // `StandardSitePublishCommand` treats a write-through failure as silent, since it
            // never turns a successful publish into a failed one and will simply retry next pass.
        }
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func logError(_ message: String, source: String) async {
        await logCenter.append(source: source, stream: .stderr, text: "standardsitegraph: \(message)")
    }

    private static let thirdPartyRequestTimeout: TimeInterval = 10
    private static let thirdPartyResourceTimeout: TimeInterval = 20
    private static let thirdPartyMaximumResponseBytes = 1 * 1024 * 1024 // 1 MB

    private static let thirdPartySession = CappedHTTPTransport.session(
        requestTimeout: thirdPartyRequestTimeout, resourceTimeout: thirdPartyResourceTimeout)

    /// Production transport for fetching an owner-typed blogroll target's homepage or
    /// well-known file — capped and time-bounded (10s request / 20s resource / 1 MB body) so a
    /// slow or byte-dribbling third-party site can't stall the rest of the post-deploy pipeline,
    /// which runs this pass serially ahead of POSSE/WebSub/ActivityPub (#1483 final review, Fix
    /// 2). Follows the same `CappedHTTPTransport` wiring as `CommunityActorResolver.defaultTransport`.
    public static let defaultThirdPartyTransport: POSSEHTTPTransport = { request in
        try await CappedHTTPTransport.fetch(
            request, session: thirdPartySession, cap: thirdPartyMaximumResponseBytes,
            tooLarge: { StandardSiteGraphPublishCommandError.responseTooLarge(bytes: $0) })
    }
}

/// Error thrown by ``StandardSiteGraphPublishCommand/defaultThirdPartyTransport`` when a
/// third-party blogroll target's response exceeds the size cap. Both callers
/// (`StandardSitePublicationResolver.resolve`, `FeedEndpointDiscovery.discover`) treat any
/// transport failure as "no match found" rather than inspecting this error's payload.
enum StandardSiteGraphPublishCommandError: Error {
    case responseTooLarge(bytes: Int)
}
