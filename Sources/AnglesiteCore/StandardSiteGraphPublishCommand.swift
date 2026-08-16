import Foundation

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
    private let logCenter: LogCenter
    private let now: @Sendable () -> Date
    private var inFlight: [String: InFlight] = [:]

    public init(
        credentials: @escaping POSSECredentialResolver.Provider = POSSECredentialResolver.provider(),
        transport: @escaping POSSEHTTPTransport = POSSESyndicationCommand.defaultTransport,
        logCenter: LogCenter = .shared,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.credentials = credentials
        self.transport = transport
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

        let settings = (try? SiteConfigStore.read(from: configDirectory)) ?? SiteSettings()
        guard settings.publishToAtmosphere ?? true else { return }

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
            guard let publicationURI = await StandardSitePublicationResolver.resolve(homepage: entry.url, transport: transport) else {
                skippedCount += 1
                await logCenter.append(
                    source: source, stream: .stdout,
                    text: "standardsitegraph: skipped \(entry.url.absoluteString) — no site.standard.publication found"
                )
                continue
            }

            if entry.feedURL == nil {
                if let discovered = try? await FeedEndpointDiscovery.discover(target: entry.url, transport: transport) {
                    writeBackFeedURL(discovered, entry: entry, siteDirectory: siteDirectory)
                }
            }

            let rkey = "anglesite-\(POSSEStableKey.make("\(siteID)\n\(entry.sourceFile)"))"
            let record = StandardSiteGraphSubscriptionRecord(publication: publicationURI, createdAt: iso8601(now()))
            do {
                let result = try await AtprotoPutRecordClient.putRecord(
                    collection: "site.standard.graph.subscription", rkey: rkey, record: record,
                    pdsURL: bluesky.pdsURL, session: session, transport: transport
                )
                ledger.record(.init(sourceFile: entry.sourceFile, uri: result.uri, lastPublishedAt: now()))
                try ledger.save(to: configDirectory)
                publishedCount += 1
                await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: published \(entry.sourceFile) as \(result.uri)")
            } catch {
                failedCount += 1
                await logError("couldn't publish \(entry.sourceFile): \(error.localizedDescription)", source: source)
            }
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
                ledger.entries.removeAll { $0.sourceFile == staleEntry.sourceFile }
                try ledger.save(to: configDirectory)
                unpublishedCount += 1
                await logCenter.append(source: source, stream: .stdout, text: "standardsitegraph: unpublished \(staleEntry.sourceFile)")
            } catch {
                failedCount += 1
                await logError("couldn't unpublish \(staleEntry.sourceFile): \(error.localizedDescription)", source: source)
            }
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
}
