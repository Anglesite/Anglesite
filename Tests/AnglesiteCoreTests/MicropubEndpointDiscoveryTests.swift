import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

/// Tests `MicropubEndpointDiscovery` (#868) against an injected `Transport` — standard Micropub
/// client discovery: the site homepage's HTTP `Link` headers and HTML `<link>` elements, rel
/// values `micropub` and `indieauth-metadata`, relative-href resolution, and the distinct
/// errors for "site unreachable" vs "endpoint not advertised". No real networking, same
/// faked-seam style as `MicropubClientTests`.
struct MicropubEndpointDiscoveryTests {
    private let siteURL = URL(string: "https://owner.example/")!

    private func homepage(
        body: String,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> MicropubEndpointDiscovery {
        MicropubEndpointDiscovery(transport: { [siteURL] _ in
            let http = HTTPURLResponse(
                url: siteURL, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), http)
        })
    }

    @Test("discovers both endpoints from the template's own HTML link tags")
    func discoversFromHTMLLinkTags() async throws {
        // Exactly what BaseLayout.astro renders (relative hrefs, double quotes).
        let discovery = homepage(body: """
            <!doctype html><html><head>
            <link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server" />
            <link rel="micropub" href="/micropub" />
            </head><body></body></html>
            """)
        let endpoints = try await discovery.discover(siteURL: siteURL)
        #expect(endpoints.micropub == URL(string: "https://owner.example/micropub"))
        #expect(endpoints.indieAuthMetadata
            == URL(string: "https://owner.example/.well-known/oauth-authorization-server"))
    }

    @Test("HTTP Link headers win over HTML link tags, per Micropub discovery precedence")
    func linkHeaderTakesPrecedence() async throws {
        let discovery = homepage(
            body: #"<link rel="micropub" href="/html-wins-not"><link rel="indieauth-metadata" href="/html-metadata">"#,
            headers: [
                "Link": #"</header-micropub>; rel="micropub", </header-metadata>; rel="indieauth-metadata""#
            ])
        let endpoints = try await discovery.discover(siteURL: siteURL)
        #expect(endpoints.micropub == URL(string: "https://owner.example/header-micropub"))
        #expect(endpoints.indieAuthMetadata == URL(string: "https://owner.example/header-metadata"))
    }

    @Test("a rel list carrying extra tokens still matches, and absolute hrefs pass through")
    func relListAndAbsoluteHrefs() async throws {
        let discovery = homepage(body: """
            <LINK REL='authorization_endpoint indieauth-metadata' HREF='https://auth.example/meta'>
            <link rel=micropub href=https://api.example/mp>
            """)
        let endpoints = try await discovery.discover(siteURL: siteURL)
        #expect(endpoints.micropub == URL(string: "https://api.example/mp"))
        #expect(endpoints.indieAuthMetadata == URL(string: "https://auth.example/meta"))
    }

    @Test("no rel=micropub is the distinct 'site doesn't offer Micropub yet' error")
    func missingMicropubRel() async throws {
        let discovery = homepage(
            body: #"<link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server">"#)
        await #expect(throws: MicropubDiscoveryError.micropubNotAdvertised) {
            try await discovery.discover(siteURL: siteURL)
        }
    }

    @Test("no rel=indieauth-metadata is its own distinct error")
    func missingIndieAuthRel() async throws {
        let discovery = homepage(body: #"<link rel="micropub" href="/micropub">"#)
        await #expect(throws: MicropubDiscoveryError.indieAuthNotAdvertised) {
            try await discovery.discover(siteURL: siteURL)
        }
    }

    @Test("a non-2xx homepage is unreachable, not 'not advertised'")
    func non2xxIsUnreachable() async throws {
        let discovery = homepage(body: "gone", status: 503)
        await #expect(throws: MicropubDiscoveryError.unreachable("HTTP 503")) {
            try await discovery.discover(siteURL: siteURL)
        }
    }

    @Test("a transport failure is unreachable, carrying the underlying description")
    func transportFailureIsUnreachable() async throws {
        struct Boom: Error {}
        let discovery = MicropubEndpointDiscovery(transport: { _ in throw Boom() })
        do {
            _ = try await discovery.discover(siteURL: siteURL)
            Issue.record("expected discovery to throw")
        } catch let error as MicropubDiscoveryError {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
        }
    }

    @Test("relative hrefs resolve against the response's final URL after a redirect")
    func resolvesAgainstFinalURL() async throws {
        // Transport followed a redirect: the response URL is www.owner.example, not the input.
        let finalURL = URL(string: "https://www.owner.example/")!
        let discovery = MicropubEndpointDiscovery(transport: { _ in
            let http = HTTPURLResponse(
                url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"<link rel="micropub" href="/micropub"><link rel="indieauth-metadata" href="/meta">"#
            return (Data(body.utf8), http)
        })
        let endpoints = try await discovery.discover(siteURL: siteURL)
        #expect(endpoints.micropub == URL(string: "https://www.owner.example/micropub"))
        #expect(endpoints.indieAuthMetadata == URL(string: "https://www.owner.example/meta"))
    }
}
