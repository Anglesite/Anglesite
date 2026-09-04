import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct CloudflareRUMAnalyticsClientTests {
    private let baseURL = URL(string: "https://example.invalid/client/v4")!
    private let accountsJSON = #"{"result":[{"id":"acc1"}]}"#

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Routes each request to a canned status/body keyed by path (`accounts` vs `graphql`) —
    /// mirrors how `RUMAnalyticsStubURLProtocol` used to key its response table, but as a plain
    /// `CloudflareTransport` closure instead of a `URLProtocol` stub.
    private func transport(
        accountsBody: String,
        accountsStatus: Int = 200,
        graphqlBody: String,
        graphqlStatus: Int = 200,
        onGraphQLRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) -> CloudflareTransport {
        { request in
            let path = request.url!.path
            if path.hasSuffix("/accounts") {
                return (Data(accountsBody.utf8), Self.response(request.url!, accountsStatus))
            }
            onGraphQLRequest?(request)
            return (Data(graphqlBody.utf8), Self.response(request.url!, graphqlStatus))
        }
    }

    @Test("decodes a successful summary with full-timestamp dates")
    func decodesSummaryWithFullTimestampDates() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: """
                {"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[
                    {"count":100,"sum":{"visits":40},"dimensions":{"date":"2026-08-01T00:00:00Z"}},
                    {"count":140,"sum":{"visits":60},"dimensions":{"date":"2026-08-02T00:00:00Z"}}
                ]}]}}}
                """))

        let summary = try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)

        #expect(summary.totalPageviews == 240)
        #expect(summary.totalVisits == 100)
        #expect(summary.dailyPageviews.map(\.pageviews) == [100, 140])
    }

    @Test("decodes a successful summary with bare-day dates")
    func decodesSummaryWithBareDayDates() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: """
                {"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[
                    {"count":10,"sum":{"visits":4},"dimensions":{"date":"2026-08-01"}}
                ]}]}}}
                """))

        let summary = try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)

        #expect(summary.totalPageviews == 10)
        #expect(summary.dailyPageviews.count == 1)
    }

    @Test("throws noAccount when the token has no Cloudflare account")
    func throwsWhenNoAccount() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: #"{"result":[]}"#,
            graphqlBody: ""))

        await #expect(throws: CloudflareWebAnalyticsError.noAccount) {
            try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)
        }
    }

    @Test("throws api error on a non-2xx GraphQL response")
    func throwsOnNon2xxResponse() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: #"{"errors":[{"message":"Invalid token"}]}"#,
            graphqlStatus: 403))

        await #expect(throws: CloudflareWebAnalyticsError.api("Invalid token")) {
            try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)
        }
    }

    @Test("throws api error when a 200 response carries GraphQL-level errors")
    func throwsOnGraphQLLevelErrors() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: #"{"data":null,"errors":[{"message":"siteTag not found"}]}"#))

        await #expect(throws: CloudflareWebAnalyticsError.api("siteTag not found")) {
            try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)
        }
    }

    @Test("throws invalidResponse when the body doesn't decode")
    func throwsOnUndecodableBody() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: "not json"))

        await #expect(throws: CloudflareWebAnalyticsError.invalidResponse) {
            try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)
        }
    }

    @Test("throws invalidResponse when every group's date fails to parse, rather than reporting empty traffic")
    func throwsWhenAllDatesUnparseable() async throws {
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: """
                {"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[
                    {"count":100,"sum":{"visits":40},"dimensions":{"date":"not-a-date"}}
                ]}]}}}
                """))

        await #expect(throws: CloudflareWebAnalyticsError.invalidResponse) {
            try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)
        }
    }

    @Test("sends the expected siteTag and a roughly 7-day since/until window")
    func sendsExpectedSiteTagAndDateWindow() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        let client = CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: transport(
            accountsBody: accountsJSON,
            graphqlBody: """
                {"data":{"viewer":{"accounts":[{"rumPageloadEventsAdaptiveGroups":[]}]}}}
                """,
            onGraphQLRequest: { request in
                capturedBody = request.httpBody
            }))

        _ = try await client.summary(siteTag: "site-tag-1", apiToken: "token", days: 7)

        let body = try #require(capturedBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])

        #expect(variables["siteTag"] as? String == "site-tag-1")

        let isoFormatter = ISO8601DateFormatter()
        let sinceString = try #require(variables["since"] as? String)
        let untilString = try #require(variables["until"] as? String)
        let since = try #require(isoFormatter.date(from: sinceString))
        let until = try #require(isoFormatter.date(from: untilString))
        let span = until.timeIntervalSince(since)
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        #expect(abs(span - sevenDays) < 3600 * 4)
    }
}
