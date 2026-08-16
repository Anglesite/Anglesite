import Foundation
import Testing
import AnglesiteTestSupport
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

@Suite("Standard.site graph publish log")
struct StandardSiteGraphPublishLogTests {
    @Test("round-trips through save/load")
    func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        var log = StandardSiteGraphPublishLog()
        log.record(.init(
            sourceFile: "src/content/blogroll/friend.md",
            uri: "at://did:plc:owner/site.standard.graph.subscription/anglesite-xyz",
            lastPublishedAt: Date(timeIntervalSince1970: 1_755_000_000)
        ))
        try log.save(to: dir)

        let loaded = try #require(StandardSiteGraphPublishLog.load(from: dir))
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.sourceFile == "src/content/blogroll/friend.md")
    }

    @Test("record(_:) replaces an existing entry with the same sourceFile")
    func recordDedupsBySourceFile() {
        var log = StandardSiteGraphPublishLog()
        log.record(.init(sourceFile: "a.md", uri: "at://one", lastPublishedAt: Date()))
        log.record(.init(sourceFile: "a.md", uri: "at://two", lastPublishedAt: Date()))
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.uri == "at://two")
    }

    @Test("load returns nil when no file exists yet")
    func loadReturnsNilWhenMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(StandardSiteGraphPublishLog.load(from: dir) == nil)
    }
}

@Suite("Standard.site graph publish pass")
struct StandardSiteGraphPublishCommandTests {
    private actor APIStub {
        var requests: [URLRequest] = []
        let did: String
        var wellKnownResponses: [String: (status: Int, body: String)] = [:]
        var homepageResponses: [String: String] = [:]
        var deleteRecordStatus: Int = 200

        init(did: String = "did:plc:owner") { self.did = did }

        func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = request.url ?? URL(string: "https://invalid.example")!
            if url.path == "/.well-known/site.standard.publication" {
                let match = wellKnownResponses[url.host ?? ""] ?? (404, "")
                return (Data(match.body.utf8), HTTPURLResponse(url: url, statusCode: match.status, httpVersion: nil, headerFields: nil)!)
            }
            if let body = homepageResponses[url.absoluteString] {
                return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "/xrpc/com.atproto.server.createSession":
                return json(#"{"accessJwt":"jwt","did":"\#(did)"}"#, url: url)
            case "/xrpc/com.atproto.repo.putRecord":
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let collection = body?["collection"] as? String ?? "unknown"
                let rkey = body?["rkey"] as? String ?? "unknown"
                return json(#"{"uri":"at://\#(did)/\#(collection)/\#(rkey)","cid":"bafycid"}"#, url: url)
            case "/xrpc/com.atproto.repo.deleteRecord":
                return json("{}", url: url, statusCode: deleteRecordStatus)
            default:
                return json("{}", url: url)
            }
        }

        private func json(_ body: String, url: URL, statusCode: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }

        func set(wellKnown host: String, status: Int, body: String) { wellKnownResponses[host] = (status, body) }
        func set(homepage: String, body: String) { homepageResponses[homepage] = body }
        func count(path: String) -> Int { requests.count { $0.url?.path == path } }
        func bodies(path: String) -> [[String: Any]] {
            requests.filter { $0.url?.path == path }.compactMap {
                guard let data = $0.httpBody else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
    }

    private var credentials: POSSECredentials {
        POSSECredentials(bluesky: .init(pdsURL: URL(string: "https://pds.example")!, identifier: "owner.test", appPassword: "secret-b"))
    }

    private func makeSite(siteURL: String? = "https://owner.example", blogroll: [String: String] = [:]) throws -> (root: URL, source: URL, config: URL) {
        var files: [String: String] = [:]
        for (name, content) in blogroll { files["Source/src/content/blogroll/\(name)"] = content }
        if let siteURL { files["Source/.site-config"] = "SITE_NAME=Owner Site\nSITE_URL=\(siteURL)\n" }
        let root = try writeSiteTree(prefix: "standardsitegraph-command", files)
        return (root, root.appendingPathComponent("Source"), root.appendingPathComponent("Config"))
    }

    @Test("no-ops without a Bluesky credential")
    func noopWithoutCredential() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        let command = StandardSiteGraphPublishCommand(
            credentials: { _, _ in POSSECredentials() },
            transport: { try await stub.respond($0) }
        )
        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)
        #expect(await stub.count(path: "/xrpc/com.atproto.server.createSession") == 0)
    }

    @Test("publishes a subscription record when the target resolves")
    func publishesResolvedEntry() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let putBodies = await stub.bodies(path: "/xrpc/com.atproto.repo.putRecord")
        let graphPuts = putBodies.filter { ($0["collection"] as? String) == "site.standard.graph.subscription" }
        #expect(graphPuts.count == 1)
        let record = graphPuts.first?["record"] as? [String: Any]
        #expect(record?["publication"] as? String == "at://did:plc:friend/site.standard.publication/anglesite-abc")

        let log = try #require(StandardSiteGraphPublishLog.load(from: site.config))
        #expect(log.entries.count == 1)
    }

    @Test("skips, without failing the pass, when the target has no standard.site well-known file")
    func skipsUnresolvedEntry() async throws {
        let site = try makeSite(blogroll: ["plain.md": "---\nname: Plain Site\nurl: https://plain.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        let logCenter = LogCenter()
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) }, logCenter: logCenter)

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let graphPuts = (await stub.bodies(path: "/xrpc/com.atproto.repo.putRecord"))
            .filter { ($0["collection"] as? String) == "site.standard.graph.subscription" }
        #expect(graphPuts.isEmpty)
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("skipped") && $0.text.contains("plain.example") })
    }

    @Test("unpublishes a removed entry's subscription record")
    func unpublishesRemovedEntry() async throws {
        let site = try makeSite(blogroll: [:])
        defer { try? FileManager.default.removeItem(at: site.root) }
        var log = StandardSiteGraphPublishLog()
        log.record(.init(
            sourceFile: "src/content/blogroll/gone.md",
            uri: "at://did:plc:owner/site.standard.graph.subscription/anglesite-old",
            lastPublishedAt: Date()
        ))
        try log.save(to: site.config)
        let stub = APIStub()
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        #expect(await stub.count(path: "/xrpc/com.atproto.repo.deleteRecord") == 1)
        let reloaded = try #require(StandardSiteGraphPublishLog.load(from: site.config))
        #expect(reloaded.entries.isEmpty)
    }

    @Test("discovers and writes back a feed URL when the entry has none")
    func discoversAndWritesBackFeedURL() async throws {
        let site = try makeSite(blogroll: ["friend.md": "---\nname: Friend\nurl: https://friend.example\naddedDate: 2026-08-01\n---\n"])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        await stub.set(
            homepage: "https://friend.example",
            body: #"<link rel="alternate" type="application/rss+xml" href="/feed.xml">"#
        )
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let written = try String(
            contentsOf: site.source.appendingPathComponent("src/content/blogroll/friend.md"), encoding: .utf8
        )
        #expect(written.contains("feedURL: \"https://friend.example/feed.xml\""))
    }

    @Test("never overwrites an owner-supplied feedURL")
    func neverOverwritesOwnerFeedURL() async throws {
        let site = try makeSite(blogroll: [
            "friend.md": "---\nname: Friend\nurl: https://friend.example\nfeedURL: https://friend.example/manual.xml\naddedDate: 2026-08-01\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: site.root) }
        let stub = APIStub()
        await stub.set(wellKnown: "friend.example", status: 200, body: "at://did:plc:friend/site.standard.publication/anglesite-abc\n")
        await stub.set(
            homepage: "https://friend.example",
            body: #"<link rel="alternate" type="application/rss+xml" href="/different-feed.xml">"#
        )
        let command = StandardSiteGraphPublishCommand(credentials: { _, _ in credentials }, transport: { try await stub.respond($0) })

        await command.publish(siteID: "site-1", siteDirectory: site.source, configDirectory: site.config)

        let written = try String(
            contentsOf: site.source.appendingPathComponent("src/content/blogroll/friend.md"), encoding: .utf8
        )
        #expect(written.contains("feedURL: https://friend.example/manual.xml"))
        #expect(!written.contains("different-feed.xml"))
    }
}
