import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@MainActor
@Suite struct ExperimentStatsModelTests {
    private static func makeModel() -> ExperimentStatsModel {
        ExperimentStatsModel(
            siteID: "s1", sourceDirectory: URL(fileURLWithPath: "/nonexistent-source"),
            configDirectory: URL(fileURLWithPath: "/nonexistent-config"))
    }

    @Test func canAnalyzeOnlyOnceBothVariantsHaveVisitors() {
        let model = Self.makeModel()
        #expect(!model.canAnalyze)
        model.controlImpressions = 1000
        model.controlConversions = 50
        #expect(!model.canAnalyze)
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        #expect(model.canAnalyze)
    }

    @Test func analyzeProducesAResultAndSummary() {
        let model = Self.makeModel()
        model.experimentName = "Hero headline"
        model.controlImpressions = 1000
        model.controlConversions = 50
        model.treatmentImpressions = 1000
        model.treatmentConversions = 120
        model.analyze()
        #expect(model.result != nil)
        #expect(model.summary?.contains("Hero headline") == true)
    }

    @Test func editAgainClearsTheResultButKeepsCounts() {
        let model = Self.makeModel()
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

    @Test func suggestionPlaybookIsAlwaysAvailable() {
        let model = Self.makeModel()
        #expect(!model.suggestions.isEmpty)
        #expect(model.suggestions == ExperimentStats.suggestionPlaybook)
    }

    @Test func loadLivePrefillIsANoOpAndLeavesManualEntryUsableWhenNothingIsConfigured() async {
        let model = Self.makeModel()
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

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory)
        await model.loadLivePrefillIfAvailable(
            secretStore: FakeSecretStore(token: "token"),
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

        let model = ExperimentStatsModel(siteID: "s1", sourceDirectory: sourceDirectory, configDirectory: configDirectory)
        model.controlImpressions = 42
        await model.loadLivePrefillIfAvailable(
            secretStore: FakeSecretStore(token: "token"),
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
}

private struct FakeSecretStore: SecretStore {
    let token: String?
    func read(account: String) throws -> String? { account == SecretAccounts.cloudflareToken ? token : nil }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}
