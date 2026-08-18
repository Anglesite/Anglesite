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

    private func tempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
