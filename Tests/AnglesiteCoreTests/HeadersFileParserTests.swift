import Testing
@testable import AnglesiteCore

struct HeadersFileParserTests {
    /// Verbatim shape of `csp.ts`'s `buildHeaders()` output (#2007): the multi-line indented `/*`
    /// block (including a repeated `Link:` header), a cache block, two `Content-Type` blocks, a
    /// noindex block, and a service-worker block — separated by blank lines.
    private static let realFileFixture = """
    /*
      X-Frame-Options: DENY
      X-Content-Type-Options: nosniff
      Referrer-Policy: strict-origin-when-cross-origin
      Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
      Cross-Origin-Opener-Policy: same-origin-allow-popups
      Cross-Origin-Resource-Policy: same-site
      Strict-Transport-Security: max-age=31536000; includeSubDomains
      Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'
      Link: </sitemap.xml>; rel="sitemap"; type="application/xml"
      Link: </rss.xml>; rel="alternate"; type="application/rss+xml"
      Cache-Control: public, max-age=0, must-revalidate

    /_astro/*
      Cache-Control: public, max-age=31536000, immutable

    /.well-known/security.txt
      Content-Type: text/plain; charset=utf-8

    /.well-known/mta-sts.txt
      Content-Type: text/plain; charset=utf-8

    /blog/drafts/
      X-Robots-Tag: noindex

    /sw.js
      Cache-Control: no-cache
      Service-Worker-Allowed: /
    """

    @Test("parses every block in file order")
    func parsesEveryBlock() {
        let blocks = HeadersFileParser.parse(Self.realFileFixture)
        #expect(blocks.map(\.path) == [
            "/*", "/_astro/*", "/.well-known/security.txt", "/.well-known/mta-sts.txt",
            "/blog/drafts/", "/sw.js",
        ])
    }

    @Test("the root block's headers round-trip, including the exact security-header values")
    func rootBlockRoundTrips() throws {
        let root = try #require(HeadersFileParser.headers(forPath: "/*", in: Self.realFileFixture))
        #expect(root["X-Frame-Options"] == "DENY")
        #expect(root["X-Content-Type-Options"] == "nosniff")
        #expect(root["Referrer-Policy"] == "strict-origin-when-cross-origin")
        #expect(root["Permissions-Policy"]
            == "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
        #expect(root["Strict-Transport-Security"] == "max-age=31536000; includeSubDomains")
        #expect(root["Content-Security-Policy"] == "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'")
        #expect(root["Cache-Control"] == "public, max-age=0, must-revalidate")
    }

    @Test("a header repeated within a block (Link:) keeps only its last value")
    func repeatedHeaderKeepsLastValue() throws {
        let root = try #require(HeadersFileParser.headers(forPath: "/*", in: Self.realFileFixture))
        #expect(root["Link"] == "</rss.xml>; rel=\"alternate\"; type=\"application/rss+xml\"")
    }

    @Test("a non-root block parses independently of the root block")
    func nonRootBlockParsesIndependently() throws {
        let astro = try #require(HeadersFileParser.headers(forPath: "/_astro/*", in: Self.realFileFixture))
        #expect(astro == ["Cache-Control": "public, max-age=31536000, immutable"])
    }

    @Test("an unknown path returns nil")
    func unknownPathReturnsNil() {
        #expect(HeadersFileParser.headers(forPath: "/nope", in: Self.realFileFixture) == nil)
    }

    @Test("empty content parses to no blocks")
    func emptyContentParsesToNoBlocks() {
        #expect(HeadersFileParser.parse("").isEmpty)
    }
}
