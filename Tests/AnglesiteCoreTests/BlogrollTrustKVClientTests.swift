import Testing
import Foundation
@testable import AnglesiteCore

struct BlogrollTrustKVClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("putTrustedDomains PUTs a sorted JSON array to the vouch:trusted-domains key")
    func putsSortedArray() async throws {
        let captured = CapturedRequest()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putTrustedDomains(["bob.example", "alice.example"])

        let request = await captured.value
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.path.hasSuffix("/values/vouch:trusted-domains") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded == ["alice.example", "bob.example"])
    }

    @Test("putTrustedDomains succeeds with an empty set (empty blogroll)")
    func putsEmptySet() async throws {
        let captured = CapturedRequest()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putTrustedDomains([])

        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded.isEmpty)
    }

    @Test("throws unauthorized on a 401/403 response")
    func throwsUnauthorized() async {
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "bad",
            transport: { _ in (Data(), Self.response(403)) })
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.putTrustedDomains(["alice.example"])
        }
    }

    @Test("throws http(status:) on any other non-2xx response")
    func throwsHTTPError() async {
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })
        await #expect(throws: CloudflareError.http(status: 500)) {
            try await client.putTrustedDomains(["alice.example"])
        }
    }
}

private actor CapturedRequest {
    private(set) var value: URLRequest?
    var body: Data? { value?.httpBody }
    func set(_ request: URLRequest) { value = request }
}
