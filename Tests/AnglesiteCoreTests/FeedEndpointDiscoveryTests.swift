import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Feed endpoint discovery")
struct FeedEndpointDiscoveryTests {
    private func transport(status: Int = 200, body: String, url: URL = URL(string: "https://target.example")!) -> POSSEHTTPTransport {
        { _ in (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    @Test("discovers an RSS <link rel=alternate type=application/rss+xml>")
    func discoversRSS() async throws {
        let html = #"<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head></html>"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/feed.xml"))
    }

    @Test("discovers an Atom <link rel=alternate type=application/atom+xml>")
    func discoversAtom() async throws {
        let html = #"<link rel="alternate" type="application/atom+xml" href="https://target.example/atom.xml">"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/atom.xml"))
    }

    @Test("first matching link in document order wins")
    func firstMatchWins() async throws {
        let html = """
        <link rel="alternate" type="application/rss+xml" href="/first.xml">
        <link rel="alternate" type="application/rss+xml" href="/second.xml">
        """
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == URL(string: "https://target.example/first.xml"))
    }

    @Test("a non-feed alternate link is ignored")
    func ignoresNonFeedAlternate() async throws {
        let html = #"<link rel="alternate" type="text/html" href="/amp.html">"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == nil)
    }

    @Test("no <link> at all returns nil, not an error")
    func returnsNilWhenAbsent() async throws {
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: "<html></html>")
        )
        #expect(discovered == nil)
    }

    @Test("a javascript: href is ignored, not returned as a discovered feed")
    func ignoresNonHTTPScheme() async throws {
        // A discovered feed URL gets committed into the owner's git repo and later emitted into
        // /blogroll.opml, so a non-http(s) scheme from hostile or malformed markup must be
        // filtered out here rather than trusted (#1483 final review, Fix 7).
        let html = #"<link rel="alternate" type="application/rss+xml" href="javascript:alert(1)">"#
        let discovered = try await FeedEndpointDiscovery.discover(
            target: URL(string: "https://target.example")!, transport: transport(body: html)
        )
        #expect(discovered == nil)
    }
}
