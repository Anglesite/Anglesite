import Testing
import Foundation
@testable import AnglesiteCore

@Suite("CloudflareWebAnalyticsClient")
struct CloudflareWebAnalyticsClientTests {
    @Test("matchingSite normalizes host URLs")
    func matchingSiteNormalizesHostURLs() {
        let sites = [
            CloudflareWebAnalyticsSite(host: "example.com", siteTag: "tag-1"),
            CloudflareWebAnalyticsSite(host: "other.example", siteTag: "tag-2")
        ]

        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "https://example.com/", in: sites)?.siteTag == "tag-1")
        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "OTHER.EXAMPLE/path", in: sites)?.siteTag == "tag-2")
        #expect(CloudflareWebAnalyticsClient.matchingSite(for: "missing.example", in: sites) == nil)
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/client/v4/accounts")!,
                         statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("siteTag resolves the token's site by normalized host")
    func siteTagResolvesMatchingHost() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { request in
            if request.url!.path.hasSuffix("/accounts") {
                return (Data(#"{"result": [{"id": "acct-1"}]}"#.utf8), Self.response(200))
            }
            return (Data(#"{"result": [{"host": "example.com", "site_tag": "tag-1"}]}"#.utf8), Self.response(200))
        })
        let tag = try await client.siteTag(for: "https://Example.com/", apiToken: "tok")
        #expect(tag == "tag-1")
    }

    @Test("siteTag throws .noAccount when the token has no visible account")
    func siteTagThrowsNoAccount() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data(#"{"result": []}"#.utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.noAccount) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag throws .noMatchingSite when no registration matches the host")
    func siteTagThrowsNoMatchingSite() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { request in
            if request.url!.path.hasSuffix("/accounts") {
                return (Data(#"{"result": [{"id": "acct-1"}]}"#.utf8), Self.response(200))
            }
            return (Data(#"{"result": []}"#.utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.noMatchingSite("example.com")) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag surfaces a non-2xx response as .api with Cloudflare's message")
    func siteTagThrowsAPIErrorOnNon2xx() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data(#"{"errors": [{"message": "bad token"}]}"#.utf8), Self.response(403))
        })
        await #expect(throws: CloudflareWebAnalyticsError.api("bad token")) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag surfaces an undecodable body as .invalidResponse")
    func siteTagThrowsInvalidResponseOnMalformedBody() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data("not json".utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.invalidResponse) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }
}
