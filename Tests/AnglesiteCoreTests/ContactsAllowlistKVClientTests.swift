import Testing
import Foundation
@testable import AnglesiteCore

struct ContactsAllowlistKVClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("putAllowlist PUTs a sorted JSON array to the contacts:allowlist key")
    func putsSortedArray() async throws {
        let captured = CapturedRequest()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putAllowlist(["bob.example", "alice.example"])

        let request = await captured.value
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.path.hasSuffix("/values/contacts:allowlist") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded == ["alice.example", "bob.example"])
    }

    @Test("putAllowlist succeeds with an empty set (last contact removed)")
    func putsEmptySet() async throws {
        let captured = CapturedRequest()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putAllowlist([])

        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded.isEmpty)
    }

    @Test("throws unauthorized on a 401/403 response")
    func throwsUnauthorized() async {
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "bad",
            transport: { _ in (Data(), Self.response(403)) })
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.putAllowlist(["alice.example"])
        }
    }

    @Test("throws http(status:) on any other non-2xx response")
    func throwsHTTPError() async {
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })
        await #expect(throws: CloudflareError.http(status: 500)) {
            try await client.putAllowlist(["alice.example"])
        }
    }
}

/// Actor wrapper so the `@Sendable` transport closure can hand a captured `URLRequest`/body back
/// to the test body without a data race. Mirrors `InboxKVClientTests.CapturedRequest`.
private actor CapturedRequest {
    private(set) var value: URLRequest?
    var body: Data? { value?.httpBody }
    func set(_ request: URLRequest) { value = request }
}
