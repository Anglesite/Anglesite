import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Best-effort direct POSSE pass run after deploy. Explicit `posse:` frontmatter is the opt-in;
/// each successful API response is ledgered, written into `syndication:` source frontmatter, and
/// offered to the existing Webmention sender for backfeed after a subsequent deploy makes it live.
public actor POSSESyndicationCommand {
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let credentials: POSSECredentialResolver.Provider
    private let transport: POSSEHTTPTransport
    private let logCenter: LogCenter
    private let now: @Sendable () -> Date
    private var inFlight: [String: InFlight] = [:]

    var activeSiteCount: Int { inFlight.count }

    /// Creates the command actor. Every dependency is injectable — credentials, HTTP transport,
    /// log sink, and clock — so tests can drive a full syndication pass with no network, secret
    /// store, or real time; the defaults wire up production behavior.
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

    /// Runs one post-deploy syndication pass for a site: repairs `syndication:` write-backs and
    /// sends backfeed webmentions for previously-posted entries, then posts any new `posse:`
    /// opt-ins. Runs per site are serialized (a newer call chains behind the in-flight one) so
    /// two overlapping deploys can't race the ledger or double-post; distinct sites proceed
    /// concurrently.
    ///
    /// Never throws: every per-entry failure is logged and skipped, because one broken social
    /// account must not block the rest of the deploy pipeline — the pass is best-effort by design.
    public func syndicate(siteID: String, siteDirectory: URL, configDirectory: URL, siteBase: URL) async {
        let previous = inFlight[siteID]?.task
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            _ = await previous?.value
            await self?.perform(siteID: siteID, siteDirectory: siteDirectory,
                                configDirectory: configDirectory, siteBase: siteBase)
        }
        inFlight[siteID] = InFlight(id: id, task: task)
        await task.value
        // Actor reentrancy allows a newer run to replace this slot while `task` is awaited.
        // Remove only our own generation so the newer run remains serialized and tracked.
        if inFlight[siteID]?.id == id {
            inFlight[siteID] = nil
        }
    }

    private func perform(siteID: String, siteDirectory: URL, configDirectory: URL, siteBase: URL) async {
        let source = "posse:\(siteID)"
        let plan: SocialPublishPlan.Plan
        do {
            plan = try SocialPublishPlan.build(projectRoot: siteDirectory, siteBase: siteBase)
        } catch {
            await logError("couldn't build publish plan: \(error.localizedDescription)", source: source)
            return
        }
        var ledger = POSSESyndicationLog.load(from: configDirectory) ?? POSSESyndicationLog()
        guard plan.posseCount > 0 || !ledger.entries.isEmpty else { return }

        let accountCredentials = credentials(siteID, configDirectory)
        let previouslyPosted = ledger.entries

        // The source URL now points at the just-deployed version, so only entries from an earlier
        // pass are eligible for Webmention verification. Newly written u-syndication links are
        // intentionally held until the next deploy.
        for entry in previouslyPosted {
            do {
                try writeBack(entry, siteDirectory: siteDirectory)
            } catch {
                await logError("couldn't write \(entry.platform) URL back to \(entry.sourceFile): \(error.localizedDescription)", source: source)
            }
            guard entry.backfeedSentAt == nil else { continue }
            let outcome = await WebmentionSender.send(
                source: entry.canonicalURL,
                target: entry.syndicationURL,
                transport: transport
            )
            if case .sent = outcome {
                ledger.markBackfeedSent(for: entry, at: now())
                do {
                    try ledger.save(to: configDirectory)
                } catch {
                    await logError("backfeed succeeded but its ledger update failed: \(error.localizedDescription)", source: source)
                }
            }
        }

        for entry in plan.entries {
            guard let post = POSSEPost.load(entry: entry, projectRoot: siteDirectory) else {
                await logError("couldn't read \(entry.sourceFile)", source: source)
                continue
            }
            for rawTarget in entry.posseTargets {
                let platform = normalizedPlatform(rawTarget)
                guard let platform else {
                    await logError("unsupported destination '\(rawTarget)' in \(entry.sourceFile)", source: source)
                    continue
                }
                guard !ledger.contains(canonicalURL: entry.canonicalURL, platform: platform) else { continue }

                let syndicationURL: URL
                let stableKey = POSSEStableKey.make("\(siteID)\n\(entry.canonicalURL.absoluteString)\n\(platform)")
                do {
                    switch platform {
                    case "mastodon":
                        guard let mastodon = accountCredentials.mastodon else {
                            await logError("mastodon requested by \(entry.sourceFile), but its server/token are not configured", source: source)
                            continue
                        }
                        syndicationURL = try await MastodonPOSSEClient.post(
                            post, credentials: mastodon, idempotencyKey: "anglesite-\(stableKey)", transport: transport)
                    case "bluesky":
                        guard let bluesky = accountCredentials.bluesky else {
                            await logError("bluesky requested by \(entry.sourceFile), but its identifier/app password are not configured", source: source)
                            continue
                        }
                        let thumb = await resolveThumbnail(
                            post: post, credentials: bluesky, siteDirectory: siteDirectory, source: source)
                        syndicationURL = try await BlueskyPOSSEClient.post(
                            post, credentials: bluesky, recordKey: "anglesite-\(stableKey)", now: now(),
                            thumb: thumb, transport: transport)
                    default:
                        continue
                    }
                } catch {
                    await logError("\(platform) failed for \(entry.sourceFile): \(error.localizedDescription)", source: source)
                    continue
                }

                let recorded = POSSESyndicationLog.Entry(
                    sourceFile: entry.sourceFile,
                    canonicalURL: entry.canonicalURL,
                    platform: platform,
                    syndicationURL: syndicationURL,
                    postedAt: now()
                )
                ledger.record(recorded)
                // Save the remote success first. If write-back fails or the app exits, the
                // next deploy repairs source from this URL without posting a duplicate.
                do {
                    try ledger.save(to: configDirectory)
                } catch {
                    await logError("\(platform) accepted \(entry.sourceFile), but its returned URL couldn't be ledgered: \(error.localizedDescription)", source: source)
                    continue
                }
                do {
                    try writeBack(recorded, siteDirectory: siteDirectory)
                } catch {
                    await logError("\(platform) accepted \(entry.sourceFile), but source write-back failed: \(error.localizedDescription)", source: source)
                }
                await logCenter.append(
                    source: source, stream: .stdout,
                    text: "posse: syndicated \(entry.canonicalURL.absoluteString) to \(platform): \(syndicationURL.absoluteString)"
                )
            }
        }
    }

    /// Resolves `post`'s frontmatter `image` to an uploaded Bluesky blob ref for the embed's
    /// `thumb` (#1484), or `nil` when there's nothing to attach. Only a root-relative path
    /// (`/uploads/hero.jpg` — Astro's `public/` served at the site root, the same convention
    /// `StandardSitePublishCommand.resolveCoverImage` uses) resolves to a local file; anything
    /// else (an external URL, a colocated-asset relative path) is left unresolved rather than
    /// guessed at. Every failure mode — missing file, oversize, unrecognized extension, or a
    /// rejected upload — degrades to "no thumb" rather than failing the post; a missing file
    /// stays silent (the common case is simply no cover image configured), but every other case
    /// is one the owner *did* configure, so it's logged ("logs are sacred, no silent drops").
    ///
    /// Logs in fresh via ``AtprotoPutRecordClient/createSession(credentials:transport:)`` rather
    /// than reusing ``BlueskyPOSSEClient/post(_:credentials:recordKey:now:thumb:transport:)``'s own
    /// session — the two clients don't share session state, and this keeps the upload's success/
    /// failure fully observable here instead of silently swallowed inside the post call.
    private func resolveThumbnail(
        post: POSSEPost, credentials: POSSECredentials.Bluesky, siteDirectory: URL, source: String
    ) async -> AtprotoPutRecordClient.BlobRef? {
        guard let sourcePath = post.coverImageSourcePath, sourcePath.hasPrefix("/") else { return nil }
        let fileURL = siteDirectory
            .appendingPathComponent(WebsiteIconAsset.publicDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent(String(sourcePath.dropFirst()))
        let prepared: StandardSiteImageBlob.Prepared
        switch StandardSiteImageBlob.prepare(fileURL: fileURL) {
        case .success(let value):
            prepared = value
        case .failure(.fileNotFound):
            return nil
        case .failure(.tooLarge(let bytes)):
            await logCenter.append(
                source: source, stream: .stdout,
                text: "posse: skipped bluesky thumb — \(bytes) bytes exceeds the 1 MB limit (no downscaling yet)"
            )
            return nil
        case .failure(.unsupportedExtension(let ext)):
            await logCenter.append(
                source: source, stream: .stdout,
                text: "posse: skipped bluesky thumb — unrecognized image extension \"\(ext)\""
            )
            return nil
        }
        do {
            let session = try await AtprotoPutRecordClient.createSession(credentials: credentials, transport: transport)
            return try await AtprotoPutRecordClient.uploadBlob(
                data: prepared.data, mimeType: prepared.mimeType,
                pdsURL: credentials.pdsURL, session: session, transport: transport
            )
        } catch {
            await logError("couldn't upload bluesky thumb: \(error.localizedDescription)", source: source)
            return nil
        }
    }

    private func writeBack(_ entry: POSSESyndicationLog.Entry, siteDirectory: URL) throws {
        let fileURL = siteDirectory.appendingPathComponent(entry.sourceFile).standardizedFileURL
        guard fileURL.pathComponents.starts(with: siteDirectory.standardizedFileURL.pathComponents) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let updated = SyndicationFrontmatter.adding(urls: [entry.syndicationURL.absoluteString], to: contents)
        guard updated != contents else { return }
        guard let data = updated.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.write(to: fileURL, options: .atomic)
    }

    private func normalizedPlatform(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mastodon", "fediverse": "mastodon"
        case "bluesky", "bsky": "bluesky"
        default: nil
        }
    }

    private func logError(_ message: String, source: String) async {
        await logCenter.append(source: source, stream: .stderr, text: "posse: \(message)")
    }

    /// Production ``POSSEHTTPTransport``: `URLSession.shared`, failing on any non-HTTP response.
    /// Exposed (rather than buried in the initializer default) so callers composing their own
    /// transport — logging, retry — can still delegate the real request to it.
    public static let defaultTransport: POSSEHTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
