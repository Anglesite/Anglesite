import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Standard.site graph records")
struct StandardSiteGraphRecordsTests {
    @Test("subscription record carries the lexicon's $type and fields")
    func recordShape() throws {
        let record = StandardSiteGraphSubscriptionRecord(
            publication: "at://did:plc:friend/site.standard.publication/anglesite-abc",
            createdAt: "2026-08-15T00:00:00Z"
        )
        let data = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["$type"] as? String == "site.standard.graph.subscription")
        #expect(object["publication"] as? String == "at://did:plc:friend/site.standard.publication/anglesite-abc")
        #expect(object["createdAt"] as? String == "2026-08-15T00:00:00Z")
    }
}

@Suite("Standard.site publication resolver")
struct StandardSitePublicationResolverTests {
    private func transport(status: Int, body: String) -> POSSEHTTPTransport {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test("resolves a well-formed at-URI from the target's well-known file")
    func resolves() async throws {
        let uri = "at://did:plc:friend/site.standard.publication/anglesite-abc"
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://friend.example")!,
            transport: transport(status: 200, body: "\(uri)\n")
        )
        #expect(resolved == uri)
    }

    @Test("requests the well-known path at the homepage's host")
    func requestsCorrectPath() async throws {
        actor Capture { var url: URL?; func set(_ u: URL?) { url = u } }
        let capture = Capture()
        _ = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://friend.example/some/path")!,
            transport: { request in
                await capture.set(request.url)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        )
        let requested = await capture.url
        #expect(requested?.absoluteString == "https://friend.example/.well-known/site.standard.publication")
    }

    @Test("returns nil on 404 — target doesn't run standard.site")
    func returnsNilOn404() async throws {
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://plain.example")!,
            transport: transport(status: 404, body: "")
        )
        #expect(resolved == nil)
    }

    @Test("returns nil for a malformed body")
    func returnsNilForMalformedBody() async throws {
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://weird.example")!,
            transport: transport(status: 200, body: "not-an-at-uri\n")
        )
        #expect(resolved == nil)
    }

    @Test("returns nil when the transport throws")
    func returnsNilOnTransportError() async throws {
        struct Boom: Error {}
        let resolved = await StandardSitePublicationResolver.resolve(
            homepage: URL(string: "https://unreachable.example")!,
            transport: { _ in throw Boom() }
        )
        #expect(resolved == nil)
    }
}
