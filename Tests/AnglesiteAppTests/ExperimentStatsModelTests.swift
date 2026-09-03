import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore
import AnglesiteTestSupport

@MainActor
@Suite struct ExperimentStatsModelTests {
    @Test func canAnalyzeOnlyOnceBothVariantsHaveVisitors() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        #expect(!model.canAnalyze)
        model.controlImpressions = 1000
        model.controlConversions = 50
        #expect(!model.canAnalyze)
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        #expect(model.canAnalyze)
    }

    @Test func analyzeProducesAResultAndSummary() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        model.experimentName = "Hero headline"
        model.controlImpressions = 1000
        model.controlConversions = 50
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        model.analyze()
        #expect(model.result != nil)
        #expect(model.summary?.contains("Hero headline") == true)
    }

    @Test func editAgainClearsTheResultButKeepsCounts() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        model.controlImpressions = 1000
        model.controlConversions = 50
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        model.analyze()
        #expect(model.result != nil)
        model.editAgain()
        #expect(model.result == nil)
        #expect(model.controlImpressions == 1000)
    }

    @Test func suggestionPlaybookIsAlwaysAvailable() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        #expect(!model.suggestions.isEmpty)
        #expect(model.suggestions == ExperimentStats.suggestionPlaybook)
    }

    // MARK: - #1270 live prefill

    @Test func loadLivePrefillIsANoOpAndLeavesManualEntryUsableWhenNothingIsConfigured() async {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: URL(fileURLWithPath: "/nonexistent-source"),
            configDirectory: URL(fileURLWithPath: "/nonexistent-config"), currentRoute: "/")
        await model.loadLivePrefillIfAvailable()
        #expect(!model.isLive)
        #expect(model.controlImpressions == 0)
        #expect(model.treatmentImpressions == 0)
        #expect(!model.canAnalyze)
    }

    @Test func loadLivePrefillFillsFieldsAndMarksLiveWhenAvailable() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let fm = FileManager.default
        let sourceDirectory = fm.temporaryDirectory.appendingPathComponent(
            "experiment-stats-model-source-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = fm.temporaryDirectory.appendingPathComponent(
            "experiment-stats-model-config-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: sourceDirectory)
            try? fm.removeItem(at: configDirectory)
        }
        try fm.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let experiment = DomainConfig.Experiments.Experiment(
            id: "hero-headline", name: "Hero headline", page: "/",
            variant: .init(id: "hero-2", name: "New headline", page: "/hero-2/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/"), status: "running",
            startedAt: "2026-08-01")
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [experiment])))
        try await SiteConfigStore(configDirectory: configDirectory).save(
            SiteSettings(provisionedWorkerResources: .init(d1DatabaseID: "db1")))

        let accountsBody = Data(#"{"success": true, "result": [{"id": "acct1"}]}"#.utf8)
        let d1Body = Data("""
        {"success": true, "result": [{"success": true, "results": [
            {"variant_id": "control", "metric": "impression", "total": 620},
            {"variant_id": "control", "metric": "conversion", "total": 31},
            {"variant_id": "hero-2", "metric": "impression", "total": 615},
            {"variant_id": "hero-2", "metric": "conversion", "total": 48}
        ]}]}
        """.utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")
        await model.loadLivePrefillIfAvailable(
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, response) }
                if request.url!.path.contains("/d1/database/db1/query") { return (d1Body, response) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            })

        #expect(model.isLive)
        #expect(model.experimentName == "Hero headline")
        #expect(model.treatmentName == "New headline")
        #expect(model.controlImpressions == 620)
        #expect(model.controlConversions == 31)
        #expect(model.treatmentImpressions == 615)
        #expect(model.treatmentConversions == 48)
        #expect(model.canAnalyze)
    }

    @Test func loadLivePrefillDoesNotClobberCountsTheOwnerAlreadyTyped() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let fm = FileManager.default
        let sourceDirectory = fm.temporaryDirectory.appendingPathComponent(
            "experiment-stats-model-source-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = fm.temporaryDirectory.appendingPathComponent(
            "experiment-stats-model-config-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: sourceDirectory)
            try? fm.removeItem(at: configDirectory)
        }
        try fm.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let experiment = DomainConfig.Experiments.Experiment(
            id: "hero-headline", name: "Hero headline", page: "/",
            variant: .init(id: "hero-2", name: "New headline", page: "/hero-2/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/"), status: "running",
            startedAt: "2026-08-01")
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [experiment])))
        try await SiteConfigStore(configDirectory: configDirectory).save(
            SiteSettings(provisionedWorkerResources: .init(d1DatabaseID: "db1")))

        let accountsBody = Data(#"{"success": true, "result": [{"id": "acct1"}]}"#.utf8)
        let d1Body = Data("""
        {"success": true, "result": [{"success": true, "results": [
            {"variant_id": "control", "metric": "impression", "total": 620},
            {"variant_id": "control", "metric": "conversion", "total": 31},
            {"variant_id": "hero-2", "metric": "impression", "total": 615},
            {"variant_id": "hero-2", "metric": "conversion", "total": 48}
        ]}]}
        """.utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")
        model.controlImpressions = 42
        await model.loadLivePrefillIfAvailable(
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, response) }
                if request.url!.path.contains("/d1/database/db1/query") { return (d1Body, response) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            })

        #expect(!model.isLive)
        #expect(model.controlImpressions == 42)
        #expect(model.treatmentImpressions == 0)
    }

    // MARK: - #1518 lifecycle

    @Test func withNoConfigStartsInManual() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        #expect(model.step == .manual)
    }

    @Test func withADraftExperimentStartsInConfigure() throws {
        let tmp = try tempDirectory()
        let experiment = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Hero headline", page: "/",
            variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "draft")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [experiment]) }

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.id == "homepage-hero")
    }

    @Test func withARunningExperimentStartsInRunning() throws {
        let tmp = try tempDirectory()
        let experiment = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Hero headline", page: "/",
            variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"),
            status: "running", startedAt: "2026-08-01")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [experiment]) }

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        guard case .running(let running) = model.step else {
            Issue.record("expected .running, got \(model.step)")
            return
        }
        #expect(running.id == "homepage-hero")
    }

    @Test func proposeFromASuggestionMovesToConfigureWithASlugifiedID() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.propose(from: ExperimentStats.suggestionPlaybook[0]) // "Hero headline"
        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.id == "hero-headline")
        #expect(draft.name == "Hero headline")
        #expect(draft.page == "/")
    }

    @Test func scaffoldVariantWritesTheVariantPageAndUpdatesTheDraft() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()

        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.variantPage == "/x/hero-headline/b/")
    }

    // scaffoldVariant is async and file-backed (already covered above); this test isolates
    // goal-setting + persistence by scaffolding a real variant via the same fixture shape rather
    // than reaching for a test-only draft setter, keeping Draft's mutation surface private to the
    // model's own methods.
    @Test func settingAGoalPersistsTheDraftToConfig() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()

        model.setPageviewGoal(path: "/contact/thanks/")

        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.goal.kind == "pageview")
        #expect(saved.experiments?.active?.first?.status == "draft")
    }

    @Test func canStartOnlyOnceVariantAndGoalAreBothSet() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        #expect(!model.canStart)
        model.setScrollGoal(depth: 75)
        #expect(!model.canStart) // no variantPage yet
    }

    // start/observeDeployPhase need a draft with both a scaffolded variant and a goal set, reached
    // the same way settingAGoalPersistsTheDraftToConfig does above: a real fixture on disk plus
    // scaffoldVariant()/setPageviewGoal(), not a test-only draft setter.
    @Test func startWritesRunningStatusAndInvokesDeploy() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")

        var deployCalled = false
        model.start(deploy: { deployCalled = true })

        guard case .starting = model.step else { Issue.record("expected .starting, got \(model.step)"); return }
        #expect(deployCalled)
        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.status == "running")
    }

    @Test func deploySuccessMovesToRunning() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")
        model.start(deploy: {})

        model.observeDeployPhase(.succeeded(url: URL(string: "https://example.com")!, duration: 1))

        guard case .running(let experiment) = model.step else { Issue.record("expected .running, got \(model.step)"); return }
        #expect(experiment.status == "running")
    }

    @Test func deployFailureRevertsToConfigureWithoutClearingTheDraft() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")
        model.start(deploy: {})

        model.observeDeployPhase(.failed(reason: "Network error", exitCode: nil))

        guard case .configure(let reverted) = model.step else { Issue.record("expected .configure, got \(model.step)"); return }
        #expect(reverted.variantPage == "/x/hero-headline/b/")
        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.status == "draft")
    }

    // MARK: - #1518 whole-branch review fixes

    /// Mirrors `Resources/Template/scripts/pre-deploy-check.ts`'s
    /// `experimentPathProblem(path, { requireTrailingSlash: true })`, which the gate applies to
    /// every `experiments.active[]` entry's `page`, `variant.page`, and (for `pageview`) goal
    /// `path` — draft entries included. Anything this model writes into `anglesite.json` has to
    /// pass it, or the site's *every* subsequent deploy fails, not just the experiment's.
    private func experimentPathProblem(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return "must be a non-empty string" }
        if !path.hasPrefix("/") { return #"must start with "/""# }
        if path.contains("..") { return #"must not contain "..""# }
        if path.contains("%") { return "must not contain percent-encoding" }
        if !path.hasSuffix("/") { return #"must end with "/""# }
        return nil
    }

    @Test func aConfiguredDraftSatisfiesThePreDeployPathContract() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Pricing"><h1>Pricing</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/pricing.astro"), atomically: true, encoding: .utf8)

        // `preview.activeRoute`/`ContentScanner.routeFromPagePath` hand over the slash-less form…
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/pricing")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks") // …and the owner can type one too.

        guard case .configure(let draft) = model.step, let experiment = draft.asExperiment else {
            Issue.record("expected a complete .configure draft, got \(model.step)")
            return
        }
        #expect(experimentPathProblem(experiment.page) == nil)
        #expect(experimentPathProblem(experiment.variant.page) == nil)
        #expect(experimentPathProblem(experiment.goal.path) == nil)
        #expect(experiment.page == "/pricing/")
        #expect(experiment.variant.page == "/x/hero-headline/b/")
        // The slash is a URL convention only — the scaffold still resolved the control page's file.
        #expect(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("src/pages/x/hero-headline/b.astro").path))
    }

    @Test func aSlashLessConfigEntryIsHealedByTheNextWrite() throws {
        let tmp = try tempDirectory()
        // The shape a pre-fix build would have left on disk.
        let stale = DomainConfig.Experiments.Experiment(
            id: "hero-headline", name: "Hero headline", page: "/pricing",
            variant: .init(id: "b", name: "B", page: "/x/hero-headline/b"),
            split: 0.5, goal: .init(kind: "pageview", path: "/thanks"), status: "draft")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [stale]) }

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        guard case .configure(let draft) = model.step, let healed = draft.asExperiment else {
            Issue.record("expected a complete .configure draft, got \(model.step)")
            return
        }
        #expect(experimentPathProblem(healed.page) == nil)
        #expect(experimentPathProblem(healed.variant.page) == nil)
        #expect(experimentPathProblem(healed.goal.path) == nil)
    }

    @Test func aRouteKindGoalPathKeepsItsSlashLessShape() throws {
        let tmp = try tempDirectory()
        // `pre-deploy-check.ts` deliberately does NOT require a trailing slash for `route` goals
        // (API/action endpoints, per worker.ts's ROUTES table) — normalizing them would break them.
        let entry = DomainConfig.Experiments.Experiment(
            id: "hero-headline", name: "Hero headline", page: "/pricing/",
            variant: .init(id: "b", name: "B", page: "/x/hero-headline/b/"),
            split: 0.5, goal: .init(kind: "route", path: "/api/contact"), status: "draft")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [entry]) }

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        guard case .configure(let draft) = model.step, let round = draft.asExperiment else {
            Issue.record("expected a complete .configure draft, got \(model.step)")
            return
        }
        #expect(round.goal.path == "/api/contact")
    }

    @Test func theRootRouteStaysASingleSlash() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.page == "/")
    }

    @Test func scaffoldVariantSurfacesWhyItFailed() async throws {
        let tmp = try tempDirectory() // no src/pages/index.astro to duplicate
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()

        #expect(model.scaffoldFailureReason?.contains("src/pages/index.astro") == true)
        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.variantPage == nil)
    }

    @Test func startRefusesWhenTheDeployCouldNotRun() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")

        var deployCalled = false
        model.start(unavailableReason: "Sign in to Cloudflare first.", deploy: { deployCalled = true })

        #expect(!deployCalled)
        guard case .configure = model.step else { Issue.record("expected .configure, got \(model.step)"); return }
        #expect(model.startFailureReason == "Sign in to Cloudflare first.")
        // Nothing may claim the test is live when no deploy was even attempted.
        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.status == "draft")
    }

    @Test func aDeployParkedOnAConfirmationRollsTheStartBack() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")
        model.start(deploy: {})

        model.observeDeployPhase(.workerNameConflict(name: "my-site"))

        guard case .configure = model.step else { Issue.record("expected .configure, got \(model.step)"); return }
        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.status == "draft")
    }

    @Test func returnToManualIsReachableFromEveryStepButStarting() async throws {
        let tmp = try tempDirectory()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---
        <BaseLayout title="Home"><h1>Home</h1></BaseLayout>
        """.write(to: tmp.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)

        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        #expect(!model.canReturnToManual) // already there
        model.openPropose()
        #expect(model.canReturnToManual)
        model.proposeCustom(name: "Hero headline")
        #expect(model.canReturnToManual)
        await model.scaffoldVariant()
        model.setPageviewGoal(path: "/thanks/")
        model.start(deploy: {})
        #expect(!model.canReturnToManual) // a deploy is in flight
        model.returnToManual()
        guard case .starting = model.step else { Issue.record("expected .starting, got \(model.step)"); return }

        model.observeDeployPhase(.succeeded(url: URL(string: "https://example.com")!, duration: 1))
        #expect(model.canReturnToManual)
        model.returnToManual()
        #expect(model.step == .manual)
    }

    // MARK: - #1518 escape-hatch fix: returnToManual() must not open a door to overwriting a
    // running experiment's config.

    @Test func openProposeRefusesWhileAnExperimentIsRunning() async throws {
        let tmp = try tempDirectory()
        let running = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Hero headline", page: "/",
            variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"),
            status: "running", startedAt: "2026-08-01")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [running]) }

        // Reached via returnToManual(), the only way to land on `.manual` while a running
        // experiment still exists on disk (the model would otherwise start in `.running`).
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        guard case .running = model.step else { Issue.record("expected .running, got \(model.step)"); return }
        model.returnToManual()
        #expect(model.step == .manual)
        #expect(model.runningExperiment?.id == "homepage-hero")

        // The bug: tapping a "Test ideas" suggestion from here used to enter .propose, then
        // .configure, and once scaffolded/goal-set would silently overwrite the running
        // experiment's config entry with a brand-new draft, losing its "running" status and
        // startedAt with no warning. `openPropose()` is the sole reachable entry point into
        // .propose (ExperimentProposeView's buttons, which call propose(from:)/proposeCustom, are
        // only ever shown once .propose is reached), so refusing it here closes the whole path.
        model.openPropose()
        #expect(model.step == .manual) // refused, not .propose

        // The running experiment's config entry is untouched.
        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.id == "homepage-hero")
        #expect(saved.experiments?.active?.first?.status == "running")
    }

    @Test func testIdeasStayReachableFromManualWhenNothingIsRunning() throws {
        let tmp = try tempDirectory()
        let draft = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Hero headline", page: "/",
            variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "draft")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [draft]) }

        // A draft (not running) config starts in .configure; return to manual and confirm
        // openPropose() is NOT blocked, since nothing is actually running.
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")
        model.returnToManual()
        #expect(model.step == .manual)
        #expect(model.runningExperiment == nil)
        model.openPropose()
        #expect(model.step == .propose)
    }

    // MARK: - #1270 slice 6 conclude

    private func makeRunningExperiment() -> DomainConfig.Experiments.Experiment {
        .init(
            id: "homepage-hero", name: "Hero headline", page: "/pricing/",
            variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"),
            status: "running", startedAt: "2026-08-01")
    }

    /// Seeds a real git repo (`promoteVariant`'s control-page commit is not best-effort, unlike
    /// `scaffoldVariant`'s — see `NativeContentOperations.promoteVariant`) with the control and
    /// variant pages `makeRunningExperiment()` declares, plus the running experiment itself in
    /// `anglesite.json`.
    private func makeRunningExperimentRepo() throws -> URL {
        let dir = try tempDirectory()
        let controlAbs = dir.appendingPathComponent("src/pages/pricing.astro")
        try FileManager.default.createDirectory(at: controlAbs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../layouts/BaseLayout.astro";
        ---

        <BaseLayout title="Pricing">
          <h1>Pricing</h1>
        </BaseLayout>
        """.write(to: controlAbs, atomically: true, encoding: .utf8)
        let variantAbs = dir.appendingPathComponent("src/pages/x/homepage-hero/b.astro")
        try FileManager.default.createDirectory(at: variantAbs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        import BaseLayout from "../../layouts/BaseLayout.astro";
        ---

        <BaseLayout canonicalPath="/pricing/" title="Fresh eggs">
          <h1>Fresh eggs!</h1>
        </BaseLayout>
        """.write(to: variantAbs, atomically: true, encoding: .utf8)
        DomainConfigStore.update(sourceDirectory: dir) { $0.experiments = .init(active: [makeRunningExperiment()]) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "git init -q && git config user.email t@example.com && git config user.name Test && git add -A && git commit -q -m init"]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        return dir
    }

    @Test func requestConcludeArmsPendingConclude() throws {
        let tmp = try tempDirectory()
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [makeRunningExperiment()]) }
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")

        model.requestConclude(.promote)

        #expect(model.pendingConclude == .promote)
    }

    @Test func cancelConcludeClearsPendingConclude() throws {
        let tmp = try tempDirectory()
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [makeRunningExperiment()]) }
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: tmp, configDirectory: try tempDirectory(), currentRoute: "/")

        model.requestConclude(.keep)
        model.cancelConclude()

        #expect(model.pendingConclude == nil)
    }

    @Test func requestConcludeIsANoOpOutsideRunning() throws {
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: try tempDirectory(), configDirectory: try tempDirectory(),
            currentRoute: "/")
        #expect(model.step == .manual)

        model.requestConclude(.promote)

        #expect(model.pendingConclude == nil)
    }

    @Test func confirmConcludePromoteAppliesTheVariantDropsTheConfigAppendsHistoryAndReturnsToManual() async throws {
        let sourceDirectory = try makeRunningExperimentRepo()
        let configDirectory = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")
        model.controlImpressions = 1000
        model.controlConversions = 50
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120

        model.requestConclude(.promote)
        var deployed = false
        await model.confirmConclude { deployed = true }

        #expect(model.step == .manual)
        #expect(deployed)
        #expect(model.concludeFailureReason == nil)

        let written = try String(
            contentsOf: sourceDirectory.appendingPathComponent("src/pages/pricing.astro"), encoding: .utf8)
        #expect(written.contains("Fresh eggs"))
        #expect(!written.contains("canonicalPath"))

        let config = try DomainConfigStore(sourceDirectory: sourceDirectory).load()
        #expect(config.experiments?.active?.isEmpty != false)

        let history = await ExperimentHistoryStore(configDirectory: configDirectory).load()
        #expect(history.count == 1)
        #expect(history.first?.decision == .promote)
        #expect(history.first?.experimentID == "homepage-hero")
        #expect(history.first?.controlVisitors == 1000)
        #expect(history.first?.variantConversions == 120)
    }

    @Test func confirmConcludeKeepRemovesTheVariantWithoutChangingTheControlPage() async throws {
        let sourceDirectory = try makeRunningExperimentRepo()
        let configDirectory = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")

        model.requestConclude(.keep)
        await model.confirmConclude {}

        #expect(model.step == .manual)
        let written = try String(
            contentsOf: sourceDirectory.appendingPathComponent("src/pages/pricing.astro"), encoding: .utf8)
        #expect(written.contains("<h1>Pricing</h1>"))

        let history = await ExperimentHistoryStore(configDirectory: configDirectory).load()
        #expect(history.first?.decision == .keep)
    }

    @Test func confirmConcludeDiscardRecordsTheDiscardDecision() async throws {
        let sourceDirectory = try makeRunningExperimentRepo()
        let configDirectory = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")

        model.requestConclude(.discard)
        await model.confirmConclude {}

        let history = await ExperimentHistoryStore(configDirectory: configDirectory).load()
        #expect(history.first?.decision == .discard)
        let config = try DomainConfigStore(sourceDirectory: sourceDirectory).load()
        #expect(config.experiments?.active?.isEmpty != false)
    }

    @Test func confirmConcludeFailurePathKeepsRunningAndSetsFailureReasonWithoutTouchingConfigOrHistory() async throws {
        // No real git repo here — `promoteVariant`'s control-page commit fails, so the whole
        // conclude action must fail rather than partially apply.
        let sourceDirectory = try tempDirectory()
        let controlAbs = sourceDirectory.appendingPathComponent("src/pages/pricing.astro")
        try FileManager.default.createDirectory(at: controlAbs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "control".write(to: controlAbs, atomically: true, encoding: .utf8)
        let variantAbs = sourceDirectory.appendingPathComponent("src/pages/x/homepage-hero/b.astro")
        try FileManager.default.createDirectory(at: variantAbs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "variant".write(to: variantAbs, atomically: true, encoding: .utf8)
        let experiment = makeRunningExperiment()
        DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
        let configDirectory = try tempDirectory()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory, currentRoute: "/")

        model.requestConclude(.promote)
        var deployed = false
        await model.confirmConclude { deployed = true }

        #expect(model.step == .running(experiment))
        #expect(!deployed)
        #expect(model.concludeFailureReason != nil)

        let config = try DomainConfigStore(sourceDirectory: sourceDirectory).load()
        #expect(config.experiments?.active?.first?.id == "homepage-hero")
        let history = await ExperimentHistoryStore(configDirectory: configDirectory).load()
        #expect(history.isEmpty)
    }

    @Test func isConcludingIsTrueWhileConfirmConcludeRunsAndFalseAfter() async throws {
        let sourceDirectory = try makeRunningExperimentRepo()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: try tempDirectory(), currentRoute: "/")

        model.requestConclude(.discard)
        var sawConcludingDuringDeploy = false
        await model.confirmConclude { sawConcludingDuringDeploy = model.isConcluding }

        #expect(sawConcludingDuringDeploy)
        #expect(!model.isConcluding)
    }

    @Test func canReturnToManualIsFalseWhileConcluding() async throws {
        let sourceDirectory = try makeRunningExperimentRepo()
        let model = ExperimentStatsModel(
            siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: try tempDirectory(), currentRoute: "/")

        model.requestConclude(.keep)
        var couldReturnDuringDeploy = true
        await model.confirmConclude { couldReturnDuringDeploy = model.canReturnToManual }

        #expect(!couldReturnDuringDeploy)
    }

    private func tempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
