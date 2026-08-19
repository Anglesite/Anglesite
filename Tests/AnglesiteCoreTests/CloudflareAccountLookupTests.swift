import Testing
import Foundation
@testable import AnglesiteCore

struct CloudflareAccountLookupTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("resolves the first account id from a successful envelope")
    func resolvesFirstAccountID() async {
        let body = Data("""
        {"success": true, "result": [{"id": "acct1"}, {"id": "acct2"}]}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == "acct1")
    }

    @Test("returns nil on a non-2xx response")
    func returnsNilOnHTTPError() async {
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (Data(), Self.response(403)) })
        #expect(accountID == nil)
    }

    @Test("returns nil when the envelope reports success: false")
    func returnsNilOnUnsuccessfulEnvelope() async {
        let body = Data("""
        {"success": false, "result": null}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == nil)
    }

    @Test("returns nil when the result list is empty")
    func returnsNilOnEmptyResult() async {
        let body = Data("""
        {"success": true, "result": []}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == nil)
    }
}
