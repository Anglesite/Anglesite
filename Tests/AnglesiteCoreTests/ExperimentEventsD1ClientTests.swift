import Testing
import Foundation
@testable import AnglesiteCore

struct ExperimentEventsD1ClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func d1Body(_ rowsJSON: String) -> Data {
        Data("""
        {"success": true, "result": [{"success": true, "results": [\(rowsJSON)]}]}
        """.utf8)
    }

    @Test("sums impressions and conversions per arm across day buckets")
    func sumsCountsPerArm() async throws {
        let body = Self.d1Body("""
        {"variant_id": "control", "metric": "impression", "total": 620},
        {"variant_id": "control", "metric": "conversion", "total": 31},
        {"variant_id": "hero-2", "metric": "impression", "total": 615},
        {"variant_id": "hero-2", "metric": "conversion", "total": 48}
        """)
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (body, Self.response(200)) })

        let counts = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        #expect(counts.controlVisitors == 620)
        #expect(counts.controlConversions == 31)
        #expect(counts.variantVisitors == 615)
        #expect(counts.variantConversions == 48)
    }

    @Test("returns all-zero counts when the experiment has no traffic yet")
    func returnsZeroCountsForEmptyResultSet() async throws {
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (Self.d1Body(""), Self.response(200)) })

        let counts = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        #expect(counts == ExperimentEventsD1Client.Counts(
            controlVisitors: 0, controlConversions: 0, variantVisitors: 0, variantConversions: 0))
    }

    @Test("ignores rows for a variant id that isn't control or the requested variant")
    func ignoresRowsForOtherVariantIDs() async throws {
        let body = Self.d1Body("""
        {"variant_id": "control", "metric": "impression", "total": 100},
        {"variant_id": "stale-variant-from-a-concluded-test", "metric": "impression", "total": 9999}
        """)
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (body, Self.response(200)) })

        let counts = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        #expect(counts.controlVisitors == 100)
        #expect(counts.variantVisitors == 0)
    }

    @Test("computes the observed control split, defaulting to 0.5 with no traffic")
    func computesObservedControlSplit() {
        let noTraffic = ExperimentEventsD1Client.Counts(
            controlVisitors: 0, controlConversions: 0, variantVisitors: 0, variantConversions: 0)
        #expect(noTraffic.observedControlSplit == 0.5)

        let skewed = ExperimentEventsD1Client.Counts(
            controlVisitors: 300, controlConversions: 0, variantVisitors: 100, variantConversions: 0)
        #expect(skewed.observedControlSplit == 0.75)
    }

    @Test("throws unauthorized on 401")
    func throwsUnauthorizedOn401() async throws {
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "bad-token",
            transport: { _ in (Data(), Self.response(401)) })

        await #expect(throws: CloudflareError.unauthorized) {
            _ = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        }
    }

    @Test("throws http error on a non-2xx, non-auth status")
    func throwsHTTPErrorOnFailureStatus() async throws {
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })

        await #expect(throws: CloudflareError.http(status: 500)) {
            _ = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        }
    }

    @Test("sends the experiment id as a bound query parameter to the D1 query endpoint")
    func sendsExperimentIDAsBoundParameter() async throws {
        let capturedRequest = ActorBox<URLRequest?>(nil)
        let client = ExperimentEventsD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { request in
                await capturedRequest.set(request)
                return (Self.d1Body(""), Self.response(200))
            })

        _ = try await client.counts(experimentID: "hero-headline", variantID: "hero-2")
        let request = await capturedRequest.get()
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/acct1/d1/database/db1/query")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(request?.httpBody)
        let decoded = try JSONDecoder().decode(CapturedQueryBody.self, from: body)
        #expect(decoded.params == ["hero-headline"])
        #expect(decoded.sql.contains("WHERE experiment_id = ?"))
    }
}

private struct CapturedQueryBody: Decodable {
    let sql: String
    let params: [String]
}

private actor ActorBox<Value: Sendable> {
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { value = newValue }
    func get() -> Value { value }
}
