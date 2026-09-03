import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite(.serialized)
struct ExperimentResultsSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func d1Body(_ rowsJSON: String) -> Data {
        Data("""
        {"success": true, "result": [{"success": true, "results": [\(rowsJSON)]}]}
        """.utf8)
    }

    private static func makeExperiment(
        id: String = "hero-headline", status: String = "running"
    ) -> DomainConfig.Experiments.Experiment {
        DomainConfig.Experiments.Experiment(
            id: id, name: "Hero headline", page: "/",
            variant: .init(id: "hero-2", name: "New headline", page: "/hero-2/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/"), status: status,
            startedAt: status == "running" ? "2026-08-01" : nil)
    }

    private static func makeTempDirectory(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - runningExperiment

    @Test("runningExperiment returns nil when anglesite.json doesn't exist")
    func runningExperimentNilWithNoConfig() {
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        #expect(ExperimentResultsSync.runningExperiment(sourceDirectory: sourceDirectory) == nil)
    }

    @Test("runningExperiment returns nil when the only declared experiment is a draft")
    func runningExperimentNilForDraftOnly() throws {
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [Self.makeExperiment(status: "draft")])))
        #expect(ExperimentResultsSync.runningExperiment(sourceDirectory: sourceDirectory) == nil)
    }

    @Test("runningExperiment returns the experiment with status running")
    func runningExperimentReturnsRunningOne() throws {
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let experiment = Self.makeExperiment()
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [experiment])))
        #expect(ExperimentResultsSync.runningExperiment(sourceDirectory: sourceDirectory) == experiment)
    }

    // MARK: - prefill

    @Test("prefill no-ops when there's no running experiment")
    func prefillNoOpsWithNoRunningExperiment() async {
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        let configDirectory = Self.makeTempDirectory(prefix: "experiments-sync-config")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: configDirectory)
        }

        let prefill = await ExperimentResultsSync.prefill(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            secretStore: InMemorySecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no running experiment")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
        #expect(prefill == nil)
    }

    @Test("prefill no-ops when the site has no provisioned D1 database")
    func prefillNoOpsWithoutD1Database() async throws {
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        let configDirectory = Self.makeTempDirectory(prefix: "experiments-sync-config")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: configDirectory)
        }
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [Self.makeExperiment()])))

        let prefill = await ExperimentResultsSync.prefill(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            secretStore: InMemorySecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no provisioned D1 database")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
        #expect(prefill == nil)
    }

    @Test("prefill no-ops (with no network call) when D1 is provisioned but no token is stored")
    func prefillNoOpsWithNoToken() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        let configDirectory = Self.makeTempDirectory(prefix: "experiments-sync-config")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: configDirectory)
        }
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [Self.makeExperiment()])))
        try await SiteConfigStore(configDirectory: configDirectory).save(
            SiteSettings(provisionedWorkerResources: .init(d1DatabaseID: "db1")))

        let prefill = await ExperimentResultsSync.prefill(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            secretStore: InMemorySecretStore(token: nil),
            transport: { _ in
                Issue.record("transport must not be called with no Cloudflare token")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
        #expect(prefill == nil)
    }

    @Test("prefill resolves the account id, queries D1, and returns live counts")
    func prefillResolvesAccountAndReturnsCounts() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let sourceDirectory = Self.makeTempDirectory(prefix: "experiments-sync-source")
        let configDirectory = Self.makeTempDirectory(prefix: "experiments-sync-config")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: configDirectory)
        }
        let experiment = Self.makeExperiment()
        try DomainConfigStore(sourceDirectory: sourceDirectory).save(
            DomainConfig(experiments: .init(active: [experiment])))
        try await SiteConfigStore(configDirectory: configDirectory).save(
            SiteSettings(provisionedWorkerResources: .init(d1DatabaseID: "db1")))

        let accountsBody = Data(#"{"success": true, "result": [{"id": "acct1"}]}"#.utf8)
        let d1Body = Self.d1Body("""
        {"variant_id": "control", "metric": "impression", "total": 620},
        {"variant_id": "control", "metric": "conversion", "total": 31},
        {"variant_id": "hero-2", "metric": "impression", "total": 615},
        {"variant_id": "hero-2", "metric": "conversion", "total": 48}
        """)
        let seenAuthorization = SeenHeader()

        let prefill = await ExperimentResultsSync.prefill(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                await seenAuthorization.record(request.value(forHTTPHeaderField: "Authorization"))
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.contains("/d1/database/db1/query") { return (d1Body, Self.response(200)) }
                return (Data(), Self.response(404))
            })

        let unwrapped = try #require(prefill)
        #expect(unwrapped.experiment == experiment)
        #expect(unwrapped.counts.controlVisitors == 620)
        #expect(unwrapped.counts.variantVisitors == 615)
        #expect(await seenAuthorization.value == "Bearer token")
    }

    // MARK: - prefillForRunningExperiment

    @Test("prefillForRunningExperiment returns nil, with no network calls, when nothing is running")
    func prefillForRunningExperimentNilWhenNothingRunning() async {
        let site1Source = Self.makeTempDirectory(prefix: "experiments-sync-multi-source")
        let site1Config = Self.makeTempDirectory(prefix: "experiments-sync-multi-config")
        defer {
            try? FileManager.default.removeItem(at: site1Source)
            try? FileManager.default.removeItem(at: site1Config)
        }

        let prefill = await ExperimentResultsSync.prefillForRunningExperiment(
            sites: [(sourceDirectory: site1Source, configDirectory: site1Config)],
            secretStore: InMemorySecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called when no site has a running experiment")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
        #expect(prefill == nil)
    }

    @Test("prefillForRunningExperiment skips a site with nothing running and finds the one that does")
    func prefillForRunningExperimentFindsTheRunningSite() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }

        let idleSource = Self.makeTempDirectory(prefix: "experiments-sync-multi-source")
        let idleConfig = Self.makeTempDirectory(prefix: "experiments-sync-multi-config")
        let runningSource = Self.makeTempDirectory(prefix: "experiments-sync-multi-source")
        let runningConfig = Self.makeTempDirectory(prefix: "experiments-sync-multi-config")
        defer {
            for url in [idleSource, idleConfig, runningSource, runningConfig] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let experiment = Self.makeExperiment()
        try DomainConfigStore(sourceDirectory: runningSource).save(
            DomainConfig(experiments: .init(active: [experiment])))
        try await SiteConfigStore(configDirectory: runningConfig).save(
            SiteSettings(provisionedWorkerResources: .init(d1DatabaseID: "db1")))

        let accountsBody = Data(#"{"success": true, "result": [{"id": "acct1"}]}"#.utf8)
        let d1Body = Self.d1Body("""
        {"variant_id": "control", "metric": "impression", "total": 10}
        """)

        let prefill = await ExperimentResultsSync.prefillForRunningExperiment(
            sites: [
                (sourceDirectory: idleSource, configDirectory: idleConfig),
                (sourceDirectory: runningSource, configDirectory: runningConfig),
            ],
            secretStore: InMemorySecretStore(token: "token"),
            transport: { request in
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.contains("/d1/database/db1/query") { return (d1Body, Self.response(200)) }
                return (Data(), Self.response(404))
            })

        let unwrapped = try #require(prefill)
        #expect(unwrapped.experiment == experiment)
        #expect(unwrapped.counts.controlVisitors == 10)
    }
}

private actor SeenHeader {
    private(set) var value: String?
    func record(_ value: String?) { self.value = value }
}
