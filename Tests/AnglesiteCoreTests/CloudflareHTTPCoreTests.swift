import Testing
import Foundation
@testable import AnglesiteCore

@Suite("CloudflareHTTPCore")
struct CloudflareHTTPCoreTests {
    private struct Widget: Codable, Sendable, Equatable { let name: String }

    private static func envelopeBody(success: Bool, result: String?, errorMessage: String? = nil, resultInfo: (page: Int, totalPages: Int)? = nil) -> Data {
        var json = "{\"success\": \(success)"
        if let result { json += ", \"result\": \(result)" }
        if let errorMessage { json += ", \"errors\": [{\"message\": \"\(errorMessage)\"}]" }
        if let resultInfo { json += ", \"result_info\": {\"page\": \(resultInfo.page), \"total_pages\": \(resultInfo.totalPages)}" }
        json += "}"
        return Data(json.utf8)
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/client/v4/widgets")!,
                         statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("get decodes a successful envelope's result")
    func getDecodesResult() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (Self.envelopeBody(success: true, result: "{\"name\": \"gadget\"}"), Self.response(200))
        }
        let widget: Widget = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        #expect(widget == Widget(name: "gadget"))
    }

    @Test("401 surfaces as .unauthorized")
    func unauthorizedMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data(), Self.response(401))
        }
        await #expect(throws: CloudflareError.unauthorized) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("a non-2xx, non-401/403 status surfaces as .http(status:)")
    func httpStatusMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data(), Self.response(500))
        }
        await #expect(throws: CloudflareError.http(status: 500)) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("an undecodable body surfaces as .malformedResponse")
    func malformedResponseMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data("not json".utf8), Self.response(200))
        }
        await #expect(throws: CloudflareError.malformedResponse) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("success:false surfaces as .api with Cloudflare's message")
    func apiFailureMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: false, result: nil, errorMessage: "nope"), Self.response(200))
        }
        await #expect(throws: CloudflareError.api(message: "nope")) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("paginated walks every page until page == total_pages")
    func paginatedWalksAllPages() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { request in
            let onPageTwo = request.url!.absoluteString.contains("page=2")
            let result = onPageTwo ? "[{\"name\": \"b\"}]" : "[{\"name\": \"a\"}]"
            let info = onPageTwo ? (page: 2, totalPages: 2) : (page: 1, totalPages: 2)
            return (Self.envelopeBody(success: true, result: result, resultInfo: info), Self.response(200))
        }
        let widgets: [Widget] = try await core.paginated("/widgets?per_page=1", apiToken: "tok", as: Widget.self)
        #expect(widgets == [Widget(name: "a"), Widget(name: "b")])
    }

    @Test("send passes through an opted-in status instead of throwing")
    func sendPassthroughStatus() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data("{}".utf8), Self.response(400))
        }
        let (_, http) = try await core.send(method: "POST", "/widgets", body: Widget(name: "x"), apiToken: "tok", passthroughStatuses: [400])
        #expect(http.statusCode == 400)
    }

    @Test("mutate succeeds silently on success:true")
    func mutateSucceeds() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: nil), Self.response(200))
        }
        try await core.mutate(method: "PUT", "/widgets/1", body: Widget(name: "x"), apiToken: "tok")
    }

    @Test("resolveAccountID returns the token's first visible account id")
    func resolveAccountIDSucceeds() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: "[{\"id\": \"acct-1\"}]"), Self.response(200))
        }
        let id = try await core.resolveAccountID(apiToken: "tok")
        #expect(id == "acct-1")
    }

    @Test("resolveAccountID throws .api when no account is visible")
    func resolveAccountIDThrowsWhenNoAccount() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: "[]"), Self.response(200))
        }
        await #expect(throws: CloudflareError.self) {
            _ = try await core.resolveAccountID(apiToken: "tok")
        }
    }
}
