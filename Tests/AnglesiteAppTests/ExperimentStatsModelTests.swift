import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@MainActor
@Suite struct ExperimentStatsModelTests {
    @Test func canAnalyzeOnlyOnceBothVariantsHaveVisitors() throws {
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: try tempDirectory(), currentRoute: "/")
        #expect(!model.canAnalyze)
        model.controlImpressions = 1000
        model.controlConversions = 50
        #expect(!model.canAnalyze)
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        #expect(model.canAnalyze)
    }

    @Test func analyzeProducesAResultAndSummary() throws {
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: try tempDirectory(), currentRoute: "/")
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
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: try tempDirectory(), currentRoute: "/")
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
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: try tempDirectory(), currentRoute: "/")
        #expect(!model.suggestions.isEmpty)
        #expect(model.suggestions == ExperimentStats.suggestionPlaybook)
    }

    @Test func withNoConfigStartsInManual() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
        #expect(model.step == .manual)
    }

    @Test func withADraftExperimentStartsInConfigure() throws {
        let tmp = try tempDirectory()
        let experiment = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Hero headline", page: "/",
            variant: .init(id: "b", name: "B", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "draft")
        DomainConfigStore.update(sourceDirectory: tmp) { $0.experiments = .init(active: [experiment]) }

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
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

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
        guard case .running(let running) = model.step else {
            Issue.record("expected .running, got \(model.step)")
            return
        }
        #expect(running.id == "homepage-hero")
    }

    @Test func proposeFromASuggestionMovesToConfigureWithASlugifiedID() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
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

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()

        guard case .configure(let draft) = model.step else {
            Issue.record("expected .configure, got \(model.step)")
            return
        }
        #expect(draft.variantPage == "/x/hero-headline/b")
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

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        await model.scaffoldVariant()

        model.setPageviewGoal(path: "/contact/thanks/")

        let saved = try DomainConfigStore(sourceDirectory: tmp).load()
        #expect(saved.experiments?.active?.first?.goal.kind == "pageview")
        #expect(saved.experiments?.active?.first?.status == "draft")
    }

    @Test func canStartOnlyOnceVariantAndGoalAreBothSet() throws {
        let tmp = try tempDirectory()
        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: tmp, currentRoute: "/")
        model.proposeCustom(name: "Hero headline")
        #expect(!model.canStart)
        model.setScrollGoal(depth: 75)
        #expect(!model.canStart) // no variantPage yet
    }

    private func tempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
