import Testing
import Foundation
@testable import AnglesiteCore

struct HTTPCloudflareClientAISearchTests {
    @Test("createAISearchInstance resolves the account then POSTs id/type/source to the instances endpoint")
    func createsInstance() async throws {
        let spy = TransportSpy()
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let createJSON = #"{"success":true,"errors":[],"result":{"id":"example-com"}}"#
        let client = HTTPCloudflareClient(transport: spyTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (200, createJSON),
        ], spy: spy))

        let instance = try await client.createAISearchInstance(
            domain: "example.com", instanceID: "example-com", apiToken: "test-token")

        #expect(instance.id == "example-com")
        #expect(instance.name == "example-com")
        let postReq = try #require(spy.requests.first { $0.httpMethod == "POST" })
        #expect(postReq.url?.path.hasSuffix("/accounts/acct1/ai-search/instances") == true)
        let body = try #require(postReq.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["id"] as? String == "example-com")
        #expect(body["type"] as? String == "web-crawler")
        #expect(body["source"] as? String == "example.com")
    }

    @Test("createAISearchInstance maps a 400 with Cloudflare code 7028 to .missingSitemap")
    func createInstanceMissingSitemap() async throws {
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let errorJSON = #"{"success":false,"errors":[{"code":7028,"message":"missing_sitemap: no sitemap found for source"}],"result":null}"#
        let client = HTTPCloudflareClient(transport: fakeTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (400, errorJSON),
        ]))
        await #expect(throws: AISearchProvisionError.missingSitemap) {
            try await client.createAISearchInstance(domain: "example.com", instanceID: "example-com", apiToken: "t")
        }
    }

    @Test("createAISearchInstance maps a 400 with Cloudflare code 7022 to .instanceAlreadyExists")
    func createInstanceAlreadyExists() async throws {
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let errorJSON = #"{"success":false,"errors":[{"code":7022,"message":"An instance with this name already exists in the namespace."}],"result":null}"#
        let client = HTTPCloudflareClient(transport: fakeTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (400, errorJSON),
        ]))
        await #expect(throws: AISearchProvisionError.instanceAlreadyExists) {
            try await client.createAISearchInstance(domain: "example.com", instanceID: "example-com", apiToken: "t")
        }
    }

    @Test("createAISearchInstance surfaces other 400 error bodies as .api with Cloudflare's message")
    func createInstanceOther400WithMessage() async throws {
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let errorJSON = #"{"success":false,"errors":[{"code":7003,"message":"instance already exists"}],"result":null}"#
        let client = HTTPCloudflareClient(transport: fakeTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (400, errorJSON),
        ]))
        await #expect(throws: CloudflareError.api(message: "instance already exists")) {
            try await client.createAISearchInstance(domain: "example.com", instanceID: "example-com", apiToken: "t")
        }
    }

    @Test("createAISearchInstance falls back to .http(400) when the error body doesn't decode")
    func createInstance400Undecodable() async throws {
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let client = HTTPCloudflareClient(transport: fakeTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (400, "<html>Bad Request</html>"),
        ]))
        await #expect(throws: CloudflareError.http(status: 400)) {
            try await client.createAISearchInstance(domain: "example.com", instanceID: "example-com", apiToken: "t")
        }
    }

    @Test("createAISearchInstance surfaces .unauthorized on a 403")
    func createInstanceUnauthorized() async throws {
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let client = HTTPCloudflareClient(transport: fakeTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances": (403, #"{"success":false,"errors":[{"message":"missing scope"}]}"#),
        ]))
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.createAISearchInstance(domain: "example.com", instanceID: "example-com", apiToken: "t")
        }
    }

    @Test("aiSearchInstanceSource GETs the instance and returns its configured source")
    func fetchesInstanceSource() async throws {
        let spy = TransportSpy()
        let accountsJSON = #"{"success":true,"errors":[],"result":[{"id":"acct1"}]}"#
        let getJSON = #"{"success":true,"errors":[],"result":{"source":"example.com"}}"#
        let client = HTTPCloudflareClient(transport: spyTransport([
            "/accounts?per_page=1": (200, accountsJSON),
            "/ai-search/instances/example-com": (200, getJSON),
        ], spy: spy))

        let source = try await client.aiSearchInstanceSource(instanceID: "example-com", apiToken: "test-token")

        #expect(source == "example.com")
        let getReq = try #require(spy.requests.first { $0.httpMethod == "GET" && $0.url?.path.contains("ai-search") == true })
        #expect(getReq.url?.path.hasSuffix("/accounts/acct1/ai-search/instances/example-com") == true)
    }
}
