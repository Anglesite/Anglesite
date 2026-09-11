import Testing
import Foundation
@testable import AnglesiteCore

/// `SiteOperations` core + dialog mapping. The command actors are faked through their existing
/// closure seams, so these tests verify the Result→dialog behavior without spawning anything.
struct SiteOperationsTests {

    /// A factory whose backup actor is scripted (via the git `runner` seam) to land on a
    /// clean feature branch → `.noChanges`. Deploy/audit aren't exercised here (their dialog
    /// mapping is tested directly against constructed `Result`s below).
    private struct FakeFactory: CommandFactory {
        func deploy() -> DeployCommand { DeployCommand() }
        func audit() -> AuditCommand { AuditCommand() }
        func socialWorkerProvision() -> SocialWorkerProvisionCommand {
            SocialWorkerProvisionCommand(tokenSource: { nil })
        }
        func backup() -> BackupCommand {
            BackupCommand(
                runner: { _, args in
                    switch args.first {
                    case "rev-parse":
                        // Serves both `--is-inside-work-tree` (exit 0 = repo) and
                        // `--abbrev-ref HEAD` (branch name → non-main so we proceed).
                        return .init(stdout: "feature\n", stderr: "", exitCode: 0)
                    case "remote":
                        return .init(stdout: "git@example.com:me/site.git\n", stderr: "", exitCode: 0)
                    case "status":
                        return .init(stdout: "", stderr: "", exitCode: 0) // clean → noChanges
                    default:
                        return .init(stdout: "", stderr: "unmocked git \(args.joined(separator: " "))", exitCode: 1)
                    }
                },
                streamer: { _, _, _ in (0, "") },
                clock: { Date(timeIntervalSince1970: 1_780_000_000) }
            )
        }
    }

    private func throwawayStore() -> SiteStore {
        SiteStore(persistenceURL: URL(fileURLWithPath: "/tmp/siteops-test-store.json"))
    }

    private func makeSite() -> SiteStore.Site {
        SiteStore.Site(
            id: "s1",
            name: "Portfolio",
            packageURL: URL(fileURLWithPath: NSTemporaryDirectory() + "portfolio.anglesite", isDirectory: true),
            isValid: true,
            missingSentinels: []
        )
    }

    private func makeSite(name: String, packageURL: URL) -> SiteStore.Site {
        SiteStore.Site(
            id: "s1",
            name: name,
            packageURL: packageURL,
            isValid: true,
            missingSentinels: []
        )
    }

    private func temporaryPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteOperationsTests-\(UUID().uuidString).anglesite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Source", isDirectory: true),
            withIntermediateDirectories: true
        )
        return package
    }

    /// A fixture `WorkerDescriptor` for the headless-deploy tests below — stands in for what
    /// `WorkerCatalogFetcher.cachedCatalog()` would return from a real on-disk cache, without
    /// touching the real `~/Library/Application Support/Anglesite/` cache file from a test.
    private func descriptor(id: String, d1: Bool = true, kv: Bool = true, r2: Bool = false) -> WorkerDescriptor {
        WorkerDescriptor(
            id: id, displayName: id, description: "test fixture", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
        )
    }

    private func finding(_ severity: AuditReport.Finding.Severity) -> AuditReport.Finding {
        AuditReport.Finding(
            category: .seo, severity: severity, title: "t", detail: "d",
            remediation: nil, location: nil
        )
    }

    @Test("backup on a clean feature branch maps to a 'no changes' dialog")
    func backupNoChanges() async {
        let ops = SiteOperations(factory: FakeFactory(), store: throwawayStore())
        let result = await ops.backup(site: makeSite())
        #expect(result == .noChanges)
        #expect(SiteOperations.dialog(forBackup: result) == "No changes to back up.")
    }

    @Test("backup success dialog shows the short SHA and remote")
    func backupSuccessDialog() {
        let result = BackupCommand.Result.succeeded(
            commitSHA: "abcdef1234567890", branch: "feature", remote: "git@example.com:me/site.git"
        )
        #expect(SiteOperations.dialog(forBackup: result) == "Backed up abcdef1 to git@example.com:me/site.git.")
    }

    @Test("audit dialog summarizes findings by severity")
    func auditDialog() {
        let report = AuditReport(
            findings: [finding(.critical), finding(.warning), finding(.warning)],
            runnersExecuted: [.seo], runnersSkipped: []
        )
        let dialog = SiteOperations.dialog(forAudit: .succeeded(report: report, duration: 1))
        #expect(dialog == "Audit complete: 1 critical, 2 warning, 0 info.")
    }

    @Test("deploy success dialog shows the deployed URL")
    func deploySuccessDialog() {
        let url = URL(string: "https://portfolio.example.workers.dev")!
        #expect(
            SiteOperations.dialog(forDeploy: .succeeded(url: url, duration: 2))
                == "Deployed to https://portfolio.example.workers.dev."
        )
    }

    @Test("deploy blocked dialog reports the issue count and never offers an override")
    func deployBlockedDialog() {
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken, message: "API key committed", file: "src/index.md", remediation: "Remove it"
        )
        let dialog = SiteOperations.dialog(forDeploy: .blocked(failures: [failure], warnings: []))
        #expect(dialog == "Deploy blocked by the pre-deploy security scan (1 issue). Resolve these in Anglesite first.")
        #expect(!dialog.lowercased().contains("force"))
        #expect(!dialog.lowercased().contains("override"))
    }

    @Test("deploy failure dialog surfaces the reason")
    func deployFailureDialog() {
        let dialog = SiteOperations.dialog(forDeploy: .failed(reason: "network down", exitCode: 1))
        #expect(dialog == "Deploy failed: network down")
    }

    @Test("deploy worker-name-conflict dialog names the taken Worker and asks for a rename")
    func deployWorkerNameConflictDialog() {
        let dialog = SiteOperations.dialog(forDeploy: .workerNameConflict(name: "taken-name"))
        #expect(dialog.contains("taken-name"))
        #expect(dialog.lowercased().contains("rename"))
    }

    @Test("social worker provisioning runs through SiteOperations and slugifies the worker name")
    func socialWorkerProvisionOperation() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.provisionSocialWorker(site: site)

        // The fixed V-2 starter pack's "webmention" worker id is `@dwk/webmention`'s catalog id
        // (`WorkerComposition.webmentionWorkerID`), which also carries inbound receive — so this
        // call now parks on the Cloudflare Queues paid-plan confirmation gate (#359) before ever
        // creating the Queue or deploying. D1/KV are still provisioned first (both webmention and
        // indieauth need them), so their ids are already in `resources` when the gate returns.
        guard case .webmentionPaidPlanConfirmationNeeded(let resources) = result else {
            Issue.record("expected webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        #expect(await recorder.arguments == [
            ["d1", "create", "blue-bottle-cafe-social"],
            ["kv", "namespace", "create", "blue-bottle-cafe-social"],
        ])
        #expect(await recorder.ran(.wrangler) == false)
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
    }

    @Test("provisionSocialWorker's fixed V-2 starter pack (webmention + indieauth) restores the pre-#708 Feature.v2 default")
    func provisionSocialWorkerRestoresV2Default() async throws {
        // provisionSocialWorker never accepted a workers/features parameter and always relied on
        // provision(...)'s default value — Feature.v2 pre-#708, now the fixed v2StarterWorkers
        // constant. This asserts every observable trace of that default's composition: D1 create
        // (both webmention and indieauth need it), KV create (same), and the AUTH_DB migration
        // step that only runs when "indieauth" specifically is among the composed workers.
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.provisionSocialWorker(site: site)

        // As in `socialWorkerProvisionOperation` above, the starter pack's real "webmention" id
        // now parks on the paid-plan confirmation gate (#359) before the IndieAuth migration step
        // or deploy — so D1/KV are provisioned but the AUTH_DB migration never runs.
        guard case .webmentionPaidPlanConfirmationNeeded = result else {
            Issue.record("expected webmentionPaidPlanConfirmationNeeded, got \(result)")
            return
        }
        let arguments = await recorder.arguments
        #expect(arguments.contains(["d1", "create", "blue-bottle-cafe-social"]))
        #expect(arguments.contains(["kv", "namespace", "create", "blue-bottle-cafe-social"]))
        #expect(!arguments.contains(["d1", "migrations", "apply", "AUTH_DB", "--remote"]))
        let toml = try String(
            contentsOf: package.appendingPathComponent("Config/wrangler.toml"), encoding: .utf8)
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("social worker provisioning maps missing folder grants to failed results")
    func socialWorkerProvisionNoGrant() async {
        let site = makeSite()
        let ops = SiteOperations(
            factory: SocialWorkerFactory(recorder: SocialWorkerRecorder()),
            store: throwawayStore(),
            socialWorkerAccess: { _, _, _ in
                throw SiteAccess.AccessError.noGrant("Portfolio has no folder grant.")
            }
        )

        let result = await ops.provisionSocialWorker(site: site)

        #expect(result == .failed(reason: "Portfolio has no folder grant.", exitCode: nil, resources: .init()))
    }

    @Test("social worker provisioning maps unexpected access errors to failed results")
    func socialWorkerProvisionGenericAccessError() async {
        let site = makeSite()
        let ops = SiteOperations(
            factory: SocialWorkerFactory(recorder: SocialWorkerRecorder()),
            store: throwawayStore(),
            socialWorkerAccess: { _, _, _ in
                throw TestAccessError()
            }
        )

        let result = await ops.provisionSocialWorker(site: site)

        #expect(result == .failed(reason: "could not resolve site access", exitCode: nil, resources: .init()))
    }

    @Test("social worker provisioning dialog reports success and resources")
    func socialWorkerProvisionSuccessDialog() {
        let result = SocialWorkerProvisionCommand.Result.succeeded(
            url: URL(string: "https://site.example.workers.dev")!,
            resources: .init(d1DatabaseID: "d1", kvNamespaceID: "kv"),
            duration: 1
        )
        #expect(
            SiteOperations.dialog(forSocialWorkerProvision: result)
                == "Social Worker provisioned at https://site.example.workers.dev. Provisioned resources: D1, KV."
        )
    }

    @Test("social worker provisioning blocked dialog preserves security gate wording")
    func socialWorkerProvisionBlockedDialog() {
        let failure = PreDeployCheck.ScanFailure(
            category: .exposedToken,
            message: "API key committed",
            file: "dist/index.html",
            remediation: "Remove it"
        )
        let result = SocialWorkerProvisionCommand.Result.blocked(
            failures: [failure],
            warnings: [],
            resources: .init(d1DatabaseID: "d1", kvNamespaceID: "kv", r2BucketName: "media")
        )
        let dialog = SiteOperations.dialog(forSocialWorkerProvision: result)
        #expect(dialog == "Social Worker provisioning blocked by the pre-deploy security scan (1 issue). Provisioned resources: D1, KV, R2.")
        #expect(!dialog.lowercased().contains("force"))
        #expect(!dialog.lowercased().contains("override"))
    }

    @Test("social worker provisioning worker-name-conflict dialog names the taken Worker")
    func socialWorkerProvisionWorkerNameConflictDialog() {
        let result = SocialWorkerProvisionCommand.Result.workerNameConflict(
            name: "taken-name", resources: .init(d1DatabaseID: "d1")
        )
        let dialog = SiteOperations.dialog(forSocialWorkerProvision: result)
        #expect(dialog.contains("taken-name"))
        #expect(dialog.lowercased().contains("rename"))
        #expect(dialog.contains("Provisioned resources: D1."))
    }

    @Test("social worker provisioning failure dialog includes partial resources")
    func socialWorkerProvisionFailureDialog() {
        let result = SocialWorkerProvisionCommand.Result.failed(
            reason: "KV failed",
            exitCode: 1,
            resources: .init(d1DatabaseID: "d1")
        )
        #expect(
            SiteOperations.dialog(forSocialWorkerProvision: result)
                == "Social Worker provisioning failed: KV failed. Provisioned resources: D1."
        )
    }

    @Test("backup failure dialog surfaces the reason")
    func backupFailureDialog() {
        let dialog = SiteOperations.dialog(forBackup: .failed(reason: "push rejected", exitCode: 1))
        #expect(dialog == "Backup failed: push rejected")
    }

    @Test("audit failure dialog surfaces the reason")
    func auditFailureDialog() {
        let dialog = SiteOperations.dialog(forAudit: .failed(reason: "config missing", exitCode: 1, logTail: []))
        #expect(dialog == "Audit failed: config missing")
    }

    @Test("headless deploy with a settings-activated worker routes through provision and persists lastDeployedWorkerIDs")
    func headlessDeployWithActiveWorkerPersistsState() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))

        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let saved = try await configStore.load()
        #expect(saved.lastDeployedWorkerIDs == ["indieauth"])
    }

    /// #1263 final review finding 1: this headless path (App Intents/Shortcuts/Siri) used to call
    /// `provision()` with no `activityPubActorType`/`moderators` at all — since `persistConfig`
    /// regenerates `wrangler.toml` from scratch on every deploy, a community correctly deployed
    /// once via the GUI then re-deployed headlessly silently reverted to a Person actor with no
    /// moderators, and `communityActorURL` was never written by this path either. Confirms both
    /// are now threaded through, mirroring `DeployModel.runDeploy`'s GUI-path wiring.
    @Test("headless deploy of a hosted community composes a Group actor with moderators and persists communityActorURL")
    func headlessDeployOfHostedCommunityComposesGroupActor() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Birding Club", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(
            activeWorkerIDs: ["activitypub"],
            moderators: ["https://mastodon.social/users/mod"]
        ))
        let siteConfigContents = SiteConfigFile.upsert([("SITE_TYPE", SiteType.community.rawValue)], into: "")
        try siteConfigContents.write(
            to: site.sourceDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath),
            atomically: true,
            encoding: .utf8
        )

        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(
            factory: SocialWorkerFactory(recorder: recorder),
            store: throwawayStore(),
            socialWorkerAccess: { site, store, body in try await SiteAccess.withScopedAccess(to: site, in: store, body) },
            cachedWorkerCatalog: { [self.descriptor(id: "activitypub")] }
        )

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let wranglerToml = try String(
            contentsOf: site.configDirectory.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(wranglerToml.contains(#"AP_ACTOR_TYPE = "Group""#))
        #expect(wranglerToml.contains(#"AP_MODERATORS = "https://mastodon.social/users/mod""#))

        let saved = try await configStore.load()
        #expect(saved.communityActorURL == URL(string: "https://blue-bottle-cafe.example.workers.dev/users/site"))
    }

    @Test("headless deploy resolves the Worker name from CF_PROJECT_NAME before deriving from the site's display name")
    func headlessDeployUsesConfiguredProjectNameOverDerivedSlug() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))

        // Simulate a #740 worker-name-conflict rename: `.site-config` already records a Worker
        // name that differs from what `SiteSlug.derive(from: site.name)` would produce. A naive
        // re-derivation would silently revert the rename on every subsequent deploy.
        let siteConfigContents = SiteConfigFile.upsert([("CF_PROJECT_NAME", "renamed-worker")], into: "")
        try siteConfigContents.write(
            to: site.sourceDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath),
            atomically: true,
            encoding: .utf8
        )

        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(
            factory: SocialWorkerFactory(recorder: recorder),
            store: throwawayStore(),
            socialWorkerAccess: { site, store, body in try await SiteAccess.withScopedAccess(to: site, in: store, body) },
            cachedWorkerCatalog: { [self.descriptor(id: "indieauth")] }
        )

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(await recorder.arguments == [
            ["d1", "create", "renamed-worker-social"],
            ["kv", "namespace", "create", "renamed-worker-social"],
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
    }

    @Test("headless deploy forwards active /.well-known/ route claims into the deploy spine's collision check (#934)")
    func headlessDeployForwardsWellKnownDynamicClaimsToDeployer() async throws {
        // `wellKnownDynamicClaims` is consumed entirely inside `DeployCommand.deploy`'s own #744
        // collision merge — it's never threaded into anything the executor's `run(step:...)` can
        // observe directly (there's no separate "deploy call" to record anymore now that
        // `provision()` drives a real `DeployCommand` spine). So the only way to prove the
        // headless path (App Intents/Shortcuts/Siri, #934) actually forwards the active worker's
        // route claim — matching `DeployModel.runDeploy`'s GUI-path wiring (#744/#746) — is to
        // plant a colliding runtime reservation at the exact same suffix and confirm the deploy
        // blocks: that's only possible if the claim genuinely reached the merge. Mirrors
        // `DeployCommandTests.wellKnownDynamicRuntimeCollisionBlocks` and
        // `SocialWorkerProvisionCommandTests.forwardsWellKnownDynamicClaimsToDeployer`, which use
        // the same technique for the same reason.
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["webfinger"]))

        let webfingerRoute = WorkerRouteClaim(
            path: "/.well-known/webfinger", match: .exact, methods: ["GET"], handler: "webfinger")
        let webfingerWorker = WorkerDescriptor(
            id: "webfinger", displayName: "webfinger", description: "test fixture", group: "social",
            binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false),
            routes: [webfingerRoute]
        )

        let recorder = SocialWorkerRecorder()
        await recorder.withRuntimeClaims([RuntimeOwnedPathClaim(
            id: "webfinger-collision", owner: "some-other-owner", path: "webfinger", match: .exact,
            capability: "test collision")])
        let ops = SiteOperations(
            factory: SocialWorkerFactory(recorder: recorder),
            store: throwawayStore(),
            socialWorkerAccess: { site, store, body in try await SiteAccess.withScopedAccess(to: site, in: store, body) },
            cachedWorkerCatalog: { [webfingerWorker] }
        )

        let result = await ops.deploy(site: site)

        guard case .blocked(let failures, _) = result else {
            Issue.record("expected .blocked once the forwarded webfinger claim collides with the planted runtime reservation, got \(result)")
            return
        }
        #expect(failures.first?.category == .wellKnownCollision)
        #expect(await recorder.ran(.build) == false, "the collision must block before any build/provisioning work runs")
    }

    @Test("headless deploy with no activated workers still deploys through the plain static path")
    func headlessDeployWithNoActiveWorkers() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(await recorder.arguments.isEmpty)
    }

    @Test("headless deploy backfills SECURITY_TXT_MODE before the deploy proceeds (#745)")
    func headlessDeployBackfillsSecurityTxtMode() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        try "SECURITY_CONTACT=security@example.com\n".write(
            to: site.sourceDirectory.appendingPathComponent(".site-config"),
            atomically: true, encoding: .utf8
        )
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: SocialWorkerRecorder()), store: throwawayStore())

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let config = try String(contentsOf: site.sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(config.contains("SECURITY_TXT_MODE=generated"))
    }

    @Test("#1821 final review finding 1: a partial provisioning failure persists resources so a retry doesn't re-create them")
    func partialProvisioningFailurePersistsResourcesForResumableRetry() async throws {
        // Root cause: `SiteSettings.provisionedWorkerResources` used to be persisted only on
        // `.succeeded`. Since the TOML-rescrape fallback that used to recover already-created
        // resource ids from `wrangler.toml` on disk is gone, that setting is now the ONLY source
        // of truth for "what's already been created" — so a KV-create failure after D1 succeeded
        // used to leave nothing persisted, and a retry would re-issue `d1 create` against a
        // database that already exists on the account and fail forever.
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))

        let recorder = FlakyKVRecorder()
        let ops = SiteOperations(
            factory: FlakyKVFactory(recorder: recorder),
            store: throwawayStore(),
            socialWorkerAccess: { site, store, body in try await SiteAccess.withScopedAccess(to: site, in: store, body) },
            cachedWorkerCatalog: { [self.descriptor(id: "indieauth")] }
        )

        // First attempt: D1 create succeeds, KV create fails (a transient wrangler error) — the
        // exact partial-failure shape this finding is about.
        let firstResult = await ops.deploy(site: site)
        guard case .failed = firstResult else {
            Issue.record("expected the first attempt to fail at the KV step, got \(firstResult)")
            return
        }
        let afterFirstAttempt = try await configStore.load()
        #expect(
            afterFirstAttempt.provisionedWorkerResources?.d1DatabaseID == "d1-id",
            "the D1 id created before the KV failure must survive the failed outcome"
        )
        #expect(afterFirstAttempt.provisionedWorkerResources?.kvNamespaceID == nil)

        // Second attempt (a retry, e.g. the owner pressing Deploy again): must resume from the
        // persisted D1 id rather than re-issuing `d1 create` against a database that already
        // exists on the Cloudflare account.
        let secondResult = await ops.deploy(site: site)
        guard case .succeeded = secondResult else {
            Issue.record("expected the retry to succeed once KV create stops failing, got \(secondResult)")
            return
        }
        let d1CreateCalls = await recorder.arguments.filter { $0 == ["d1", "create", "blue-bottle-cafe-social"] }
        #expect(d1CreateCalls.count == 1, "a resumed retry must not re-issue `d1 create` for a resource already known")
        let kvCreateCalls = await recorder.arguments.filter { $0 == ["kv", "namespace", "create", "blue-bottle-cafe-social"] }
        #expect(kvCreateCalls.count == 2, "KV create is retried since it never succeeded on the first attempt")

        let afterSecondAttempt = try await configStore.load()
        #expect(afterSecondAttempt.provisionedWorkerResources?.d1DatabaseID == "d1-id")
        #expect(afterSecondAttempt.provisionedWorkerResources?.kvNamespaceID == "kv-id")
    }

    @Test("headless deploy still reports coarse progress milestones through onProgress")
    func headlessDeployReportsProgress() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: SocialWorkerRecorder()), store: throwawayStore())
        let seen = HeadlessDeployProgressRecorder()

        _ = await ops.deploy(site: site, onProgress: { progress in Task { await seen.record(progress) } })
        // onProgress fires synchronously inside deployWithWorkerComposition, but the recorder hop
        // above is async — give it a beat to land before asserting.
        while await seen.progresses.count < 2 { await Task.yield() }

        let progresses = await seen.progresses
        #expect(progresses.contains(.deployBuilding))
        #expect(progresses.contains(.deployDeploying))
    }
}

/// Fakes `SocialWorkerProvisionCommand`'s `executor:` seam directly (rather than the old
/// `runner:`/`deployer:` closures) so the many `deploy()`/`provisionSocialWorker()` tests above
/// that share this recorder keep observing the same `d1`/`kv` wrangler-subcommand argv, now
/// exercised through the real `DeployCommand` spine (`.build`/`.preflight`/`.wrangler` all run
/// for real, scripted here to succeed) instead of a canned deployer closure.
private actor SocialWorkerRecorder: DeployExecutor {
    private var seenArguments: [[String]] = []
    private var seenSteps: [String] = []
    private var runtimeClaims: [RuntimeOwnedPathClaim] = []

    var arguments: [[String]] { seenArguments }

    /// Plants a runtime-reported `.well-known` ownership claim `reportOwnedPathClaims()` returns
    /// on every subsequent call — lets a test prove a dynamic claim genuinely reached
    /// `DeployCommand.deploy`'s #744 collision merge by colliding it against a claim at the same
    /// path (mirrors `DeployCommandTests.swift`'s `FakeExecutor.withRuntimeClaims`).
    func withRuntimeClaims(_ claims: [RuntimeOwnedPathClaim]) {
        runtimeClaims = claims
    }

    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] {
        runtimeClaims
    }

    private func key(_ step: DeployStep) -> String {
        switch step {
        case .build: return "build"
        case .preflight: return "preflight"
        case .wrangler: return "wrangler"
        case .bundleUpload: return "bundleUpload"
        case .githubPagesPublish: return "githubPagesPublish"
        case .wranglerSubcommand(let args): return "wranglerSubcommand:\(args.joined(separator: " "))"
        }
    }

    /// Whether `step` actually ran through `run(step:...)` — used where a test needs to confirm
    /// the deploy stage was (or wasn't) reached, the equivalent of the old `deployCalls.isEmpty`
    /// check against a fake `deployer` closure.
    func ran(_ step: DeployStep) -> Bool {
        seenSteps.contains(key(step))
    }

    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        seenSteps.append(key(step))
        switch step {
        case .build:
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#)
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "Published site (0.1 sec)\n  https://blue-bottle-cafe.example.workers.dev")
        case .bundleUpload, .githubPagesPublish:
            return DeployStepResult(exitCode: 0, output: "")
        case .wranglerSubcommand(let args):
            seenArguments.append(args)
            if args.first == "d1" {
                return DeployStepResult(exitCode: 0, output: #"{"uuid":"d1-id"}"#)
            }
            if args.first == "kv" {
                return DeployStepResult(exitCode: 0, output: #"{"id":"kv-id"}"#)
            }
            return DeployStepResult(exitCode: 127, output: "unexpected arguments \(args)")
        }
    }
}

/// Fakes `SocialWorkerProvisionCommand`'s `executor:` seam so `partialProvisioningFailurePersistsResourcesForResumableRetry`
/// can script a KV-namespace-create failure on its first attempt only, succeeding on any later
/// attempt — reproducing the exact partial-provisioning-failure shape #1821's final review
/// finding 1 is about (D1 already created, KV still pending).
private actor FlakyKVRecorder: DeployExecutor {
    private var kvAttempts = 0
    private var seenArguments: [[String]] = []

    var arguments: [[String]] { seenArguments }

    func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }

    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        switch step {
        case .build:
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#)
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "Published site (0.1 sec)\n  https://blue-bottle-cafe.example.workers.dev")
        case .bundleUpload, .githubPagesPublish:
            return DeployStepResult(exitCode: 0, output: "")
        case .wranglerSubcommand(let args):
            seenArguments.append(args)
            if args.first == "d1" {
                if args.dropFirst().first == "create" {
                    return DeployStepResult(exitCode: 0, output: #"{"uuid":"d1-id"}"#)
                }
                // AUTH_DB migration — always succeeds once reached.
                return DeployStepResult(exitCode: 0, output: "")
            }
            if args.first == "kv" {
                kvAttempts += 1
                if kvAttempts == 1 {
                    return DeployStepResult(exitCode: 1, output: "kv namespace create: transient network error")
                }
                return DeployStepResult(exitCode: 0, output: #"{"id":"kv-id"}"#)
            }
            return DeployStepResult(exitCode: 127, output: "unexpected arguments \(args)")
        }
    }
}

private struct FlakyKVFactory: CommandFactory {
    let recorder: FlakyKVRecorder

    func deploy() -> DeployCommand { DeployCommand() }
    func backup() -> BackupCommand { BackupCommand(runner: { _, _ in .init(stdout: "", stderr: "", exitCode: 1) }, streamer: { _, _, _ in (1, "") }) }
    func audit() -> AuditCommand {
        AuditCommand(
            executor: HostAuditExecutor(resolveCommand: { _ in { _ in .unavailable(reason: "noop") } }),
            runners: []
        )
    }
    func socialWorkerProvision() -> SocialWorkerProvisionCommand {
        SocialWorkerProvisionCommand(tokenSource: { "token" }, executor: recorder)
    }
}

private struct TestAccessError: LocalizedError, Sendable {
    var errorDescription: String? { "could not resolve site access" }
}

// Named distinctly from `DeployCommandProgressTests.ProgressRecorder` (an internal,
// non-private, lock-based type in the same test target) to avoid a same-module name clash.
private actor HeadlessDeployProgressRecorder {
    private(set) var progresses: [OperationProgress] = []
    func record(_ progress: OperationProgress) { progresses.append(progress) }
}

private struct SocialWorkerFactory: CommandFactory {
    let recorder: SocialWorkerRecorder

    func deploy() -> DeployCommand { DeployCommand() }
    func backup() -> BackupCommand { BackupCommand(runner: { _, _ in .init(stdout: "", stderr: "", exitCode: 1) }, streamer: { _, _, _ in (1, "") }) }
    func audit() -> AuditCommand {
        AuditCommand(
            executor: HostAuditExecutor(resolveCommand: { _ in { _ in .unavailable(reason: "noop") } }),
            runners: []
        )
    }
    func socialWorkerProvision() -> SocialWorkerProvisionCommand {
        SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            executor: recorder,
            // Only exercised when the activitypub worker is active (it's the only one that pushes
            // a secret, `AP_PRIVATE_KEY`) — always-succeeds is fine for the indieauth/webfinger
            // fixtures elsewhere in this file, which never call it.
            secretRunner: { _, _, _, _, _ in .init(stdout: "Success!", stderr: "", exitCode: 0) }
        )
    }
}
