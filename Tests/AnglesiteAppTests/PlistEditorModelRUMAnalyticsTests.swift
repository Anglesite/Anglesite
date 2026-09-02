import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel RUM analytics summary (#1114)")
@MainActor
struct PlistEditorModelRUMAnalyticsTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private struct FakeRUMAnalyticsProvider: CloudflareRUMAnalyticsProviding {
        let result: Result<RUMAnalyticsSummary, Error>
        func summary(siteTag: String, apiToken: String, days: Int) async throws -> RUMAnalyticsSummary {
            try result.get()
        }
    }

    private struct Fixture {
        let model: PlistEditorModel
        let keychainCleanup: () -> Void
    }

    private func makeFixture(
        token: String? = "test-token",
        siteTag: String = "",
        rumResult: Result<RUMAnalyticsSummary, Error> = .success(
            RUMAnalyticsSummary(totalPageviews: 100, totalVisits: 40, dailyPageviews: []))
    ) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelRUMAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = dir.appendingPathComponent("Source", isDirectory: true)
        let configDir = dir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let plistURL = sourceDir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let scratchKeychain = TemporaryKeychainStore()
        if let token {
            try scratchKeychain.store.writeCloudflareToken(token)
        }
        let model = PlistEditorModel(
            file: FileRef(url: plistURL, group: .metadata, name: "Info.plist"),
            websiteTitle: "My Test Site",
            sourceDirectory: sourceDir,
            configDirectory: configDir,
            rumAnalyticsProvider: FakeRUMAnalyticsProvider(result: rumResult),
            keychain: scratchKeychain.store)
        model.analyticsSettings.cloudflareToken = siteTag
        return Fixture(model: model, keychainCleanup: scratchKeychain.cleanup)
    }

    @Test("loadRUMSummary does nothing when Cloudflare Analytics is not enabled")
    func skipsWhenAnalyticsDisabled() async throws {
        let fixture = try await makeFixture(siteTag: "")
        defer { fixture.keychainCleanup() }

        await fixture.model.loadRUMSummary()

        #expect(fixture.model.rumSummary == nil)
        #expect(fixture.model.rumSummaryError == nil)
    }

    @Test("loadRUMSummary populates rumSummary on success")
    func populatesSummaryOnSuccess() async throws {
        let summary = RUMAnalyticsSummary(
            totalPageviews: 240, totalVisits: 90,
            dailyPageviews: [DailyCount(date: Date(timeIntervalSince1970: 0), pageviews: 240)])
        let fixture = try await makeFixture(siteTag: "site-tag-1", rumResult: .success(summary))
        defer { fixture.keychainCleanup() }

        await fixture.model.loadRUMSummary()

        #expect(fixture.model.rumSummary == summary)
        #expect(fixture.model.rumSummaryError == nil)
    }

    @Test("loadRUMSummary surfaces a provider error and clears any prior summary")
    func surfacesProviderError() async throws {
        let fixture = try await makeFixture(
            siteTag: "site-tag-1",
            rumResult: .failure(CloudflareWebAnalyticsError.api("boom")))
        defer { fixture.keychainCleanup() }

        await fixture.model.loadRUMSummary()

        #expect(fixture.model.rumSummary == nil)
        #expect(fixture.model.rumSummaryError == "boom")
    }

    @Test("loadRUMSummary surfaces missingToken when no Cloudflare token is configured")
    func surfacesMissingToken() async throws {
        // Claim the process-wide `CLOUDFLARE_API_TOKEN` env var in its exclusive "cleared" state:
        // `CloudflareAPICredentials.resolve()` consults it before the injected keychain, and
        // sibling setter suites (DomainConfigAuditModelTests, HardenModelTests,
        // OnionRoutingModelTests) legitimately hold it set to "test-token" while their own tests
        // run concurrently in this process (#1375). The claim replaces the old
        // `.enabled(if: env == nil)` trait, which was evaluated once before the body ran and so
        // couldn't keep a setter's claim window from overlapping it; claiming also lets this test
        // run (rather than silently skip) on a machine whose shell exports a real token.
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let fixture = try await makeFixture(token: nil, siteTag: "site-tag-1")
        defer { fixture.keychainCleanup() }

        await fixture.model.loadRUMSummary()

        #expect(fixture.model.rumSummary == nil)
        #expect(fixture.model.rumSummaryError == CloudflareWebAnalyticsError.missingToken.localizedDescription)
    }
}
