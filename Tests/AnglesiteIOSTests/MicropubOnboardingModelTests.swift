import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteIOS
import AnglesiteCore
import AnglesiteSiteModel

/// Minimal conforming store, same shape as `SecretStoreTests`' reference implementation —
/// `AnglesiteIOSTests` doesn't depend on `AnglesiteTestSupport`.
private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var entries: [String: String] = [:]
    private let lock = NSLock()

    func read(account: String) throws -> String? { lock.withLock { entries[account] } }
    func write(_ value: String, account: String) throws {
        lock.withLock { entries[account] = value.isEmpty ? nil : value }
    }
    func delete(account: String) throws { lock.withLock { entries[account] = nil } }
}

/// Completes the web-auth step by echoing the authorize URL's own `state` into the bridged
/// custom-scheme callback — exactly what the template worker's `/indieauth/app-callback`
/// route produces after a real approval.
private struct EchoingWebAuthenticator: SiteWebAuthenticating {
    var code = "auth-code-868"
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(callbackScheme)://indieauth-callback?code=\(code)&state=\(state)")!
    }
}

/// Fails the web-auth step the way the production adapter reports a user dismissal.
private struct CancellingWebAuthenticator: SiteWebAuthenticating {
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        throw SiteWebAuthenticationCancelled()
    }
}

private struct FailingWebAuthenticator: SiteWebAuthenticating {
    struct Boom: Error {}
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        throw Boom()
    }
}

/// Tests `MicropubOnboardingModel` (#868) — the iOS IndieAuth onboarding state machine —
/// against faked transports, a faked web-auth session, and an in-memory secret store. Pins the
/// issue's required behaviors: Keychain restore, the discover→authorize→exchange→store happy
/// path, cancellation as its own state (never a network failure), and the 401/403 re-auth
/// signal from `MicropubClient`.
@MainActor
struct MicropubOnboardingModelTests {
    private static let siteOrigin = "https://owner.example"

    /// One transport serving the whole flow: homepage (discovery), IndieAuth metadata, and the
    /// token exchange — routed by path, matching what a real site's Worker serves.
    private static func siteTransport(tokenMe: String = "https://owner.example/") -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in
            let url = request.url!
            let respond = { (body: String, status: Int) -> (Data, HTTPURLResponse) in
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "", "/":
                return respond(#"""
                    <link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server" />
                    <link rel="micropub" href="/micropub" />
                    """#, 200)
            case "/.well-known/oauth-authorization-server":
                return respond(#"{"issuer":"\#(siteOrigin)","authorization_endpoint":"\#(siteOrigin)/authorize","token_endpoint":"\#(siteOrigin)/token"}"#, 200)
            case "/token":
                return respond(#"{"access_token":"tok-868","token_type":"DPoP","scope":"create update delete media","me":"\#(tokenMe)"}"#, 200)
            default:
                return respond("not found", 404)
            }
        }
    }

    /// A throwaway `.anglesite` package whose `Source/.site-config` carries `SITE_URL` (or
    /// nothing, when `siteURL` is nil) — what `configure(site:)` resolves the origin from.
    private func makePackage(siteURL: String?) throws -> SitePickerModel.DiscoveredSite {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("micropub-onboarding-\(UUID().uuidString)")
        let packageURL = root.appendingPathComponent("Site.anglesite", isDirectory: true)
        let package = AnglesitePackage(url: packageURL)
        try FileManager.default.createDirectory(at: package.sourceURL, withIntermediateDirectories: true)
        let marker = AnglesitePackage.Marker(displayName: "Test Site")
        try package.writeMarker(marker)
        if let siteURL {
            try Data("SITE_URL=\(siteURL)\n".utf8)
                .write(to: package.sourceURL.appendingPathComponent(".site-config"))
        }
        return SitePickerModel.DiscoveredSite(
            id: marker.siteID, displayName: marker.displayName, packageURL: packageURL)
    }

    private func makeModel(
        store: InMemorySecretStore = InMemorySecretStore(),
        webAuthenticator: any SiteWebAuthenticating = EchoingWebAuthenticator(),
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = siteTransport(),
        conformanceStatus: @escaping @Sendable () async -> WorkersConformanceStatus = {
            try! WorkersConformanceReader.parse(Data(#"{"packages":{}}"#.utf8))
        }
    ) -> MicropubOnboardingModel {
        MicropubOnboardingModel(
            secretStore: store,
            discovery: MicropubEndpointDiscovery(transport: transport),
            indieAuthClient: SiteIndieAuthClient(transport: transport),
            webAuthenticator: webAuthenticator,
            conformanceStatus: conformanceStatus
        )
    }

    @Test("a site with no SITE_URL needs a deploy first — sign-in isn't offered")
    func siteWithoutURLNeedsDeploy() async throws {
        let model = makeModel()
        await model.configure(site: try makePackage(siteURL: nil))
        let state = model.state
        #expect(state == .needsDeployedSite)
        await model.signIn()
        let after = model.state
        #expect(after == .needsDeployedSite)
    }

    @Test("configure restores an existing Keychain session without any network I/O")
    func configureRestoresSession() async throws {
        let store = InMemorySecretStore()
        let site = try makePackage(siteURL: Self.siteOrigin)
        try store.writeMicropubAccessToken("stored-tok", siteID: site.id.uuidString)
        try store.writeMicropubDPoPKeyPair(DPoPKeyPair(), siteID: site.id.uuidString)
        struct NoNetwork: Error {}
        let model = makeModel(store: store, transport: { _ in throw NoNetwork() })
        await model.configure(site: site)
        let state = model.state
        #expect(state == .signedIn(me: Self.siteOrigin))
    }

    @Test("signIn walks discover → authorize → exchange and lands signed in with the token stored")
    func signInHappyPath() async throws {
        let store = InMemorySecretStore()
        let model = makeModel(store: store)
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        let configured = model.state
        #expect(configured == .signedOut)

        await model.signIn()
        let state = model.state
        #expect(state == .signedIn(me: "https://owner.example/"))
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == "tok-868")
        #expect(try store.readMicropubDPoPKeyPair(siteID: site.id.uuidString) != nil)
        let client = model.micropubClient
        #expect(client != nil)
    }

    @Test("dismissing the web-auth session is its own state, not a failure, and stores nothing")
    func cancellationIsDistinct() async throws {
        let store = InMemorySecretStore()
        let model = makeModel(store: store, webAuthenticator: CancellingWebAuthenticator())
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        await model.signIn()
        let state = model.state
        #expect(state == .cancelled)
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == nil)
    }

    @Test("a web-auth failure that isn't a dismissal is a failure, distinct from cancellation")
    func webAuthFailureIsFailure() async throws {
        let model = makeModel(webAuthenticator: FailingWebAuthenticator())
        await model.configure(site: try makePackage(siteURL: Self.siteOrigin))
        await model.signIn()
        guard case .failed(.signInFailed) = model.state else {
            Issue.record("expected .failed(.signInFailed), got \(model.state)")
            return
        }
    }

    @Test("a homepage with no rel=micropub fails by naming the missing capability")
    func micropubNotSupportedNamed() async throws {
        let model = makeModel(transport: { request in
            let body = #"<link rel="indieauth-metadata" href="/meta">"#
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await model.configure(site: try makePackage(siteURL: Self.siteOrigin))
        await model.signIn()
        let state = model.state
        #expect(state == .failed(.micropubNotSupported))
    }

    @Test("a reachable site with a broken metadata document is a sign-in failure, not 'unreachable'")
    func brokenMetadataIsSignInFailureNotUnreachable() async throws {
        // Homepage discovery succeeds, but the advertised metadata endpoint returns JSON
        // missing its endpoints — a server misconfiguration. "Check your connection" would be
        // actively wrong guidance here.
        let model = makeModel(transport: { request in
            let respond = { (body: String) -> (Data, HTTPURLResponse) in
                (Data(body.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.contains("oauth-authorization-server") {
                return respond(#"{"issuer":"https://owner.example"}"#)
            }
            return respond(#"""
                <link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server" />
                <link rel="micropub" href="/micropub" />
                """#)
        })
        await model.configure(site: try makePackage(siteURL: Self.siteOrigin))
        await model.signIn()
        guard case .failed(.signInFailed) = model.state else {
            Issue.record("expected .failed(.signInFailed), got \(model.state)")
            return
        }
    }

    @Test("an unreachable site fails as unreachable, not as a missing capability")
    func unreachableSiteNamed() async throws {
        struct Offline: Error {}
        let model = makeModel(transport: { _ in throw Offline() })
        await model.configure(site: try makePackage(siteURL: Self.siteOrigin))
        await model.signIn()
        guard case .failed(.siteUnreachable) = model.state else {
            Issue.record("expected .failed(.siteUnreachable), got \(model.state)")
            return
        }
    }

    @Test("MicropubClient's 401/403 signal clears the session and asks for re-auth")
    func unauthorizedTriggersReauth() async throws {
        let store = InMemorySecretStore()
        let model = makeModel(store: store)
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        await model.signIn()

        model.handleMicropubError(.unauthorized)
        let state = model.state
        #expect(state == .reauthorizationRequired)
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == nil)
        let client = model.micropubClient
        #expect(client == nil)

        // Re-auth is the same sign-in flow, offered again.
        await model.signIn()
        let after = model.state
        #expect(after == .signedIn(me: "https://owner.example/"))
    }

    @Test("a retryable Micropub error is not a re-auth signal")
    func retryableErrorIsNotReauth() async throws {
        let store = InMemorySecretStore()
        let model = makeModel(store: store)
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        await model.signIn()

        model.handleMicropubError(.serverError(status: 503, body: "down"))
        let state = model.state
        #expect(state == .signedIn(me: "https://owner.example/"))
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == "tok-868")
    }

    @Test("signOut clears the stored session and returns to signedOut")
    func signOutClears() async throws {
        let store = InMemorySecretStore()
        let model = makeModel(store: store)
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        await model.signIn()

        model.signOut()
        let state = model.state
        #expect(state == .signedOut)
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == nil)
        #expect(try store.readMicropubDPoPKeyPair(siteID: site.id.uuidString) == nil)
    }

    @Test("a callback whose state doesn't match the request never signs in")
    func staleStateRejected() async throws {
        struct StaleStateAuthenticator: SiteWebAuthenticating {
            func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
                URL(string: "\(callbackScheme)://indieauth-callback?code=c&state=stale")!
            }
        }
        let store = InMemorySecretStore()
        let model = makeModel(store: store, webAuthenticator: StaleStateAuthenticator())
        let site = try makePackage(siteURL: Self.siteOrigin)
        await model.configure(site: site)
        await model.signIn()
        guard case .failed(.signInFailed) = model.state else {
            Issue.record("expected .failed(.signInFailed), got \(model.state)")
            return
        }
        #expect(try store.readMicropubAccessToken(siteID: site.id.uuidString) == nil)
    }

    @Test("configure never triggers the conformance fetch — conformanceAdvisory stays nil until refreshed")
    func configureDoesNotFetchConformance() async throws {
        let model = makeModel(conformanceStatus: {
            Issue.record("conformance fetch must not run from configure()")
            return try! WorkersConformanceReader.parse(Data(#"{"packages":{}}"#.utf8))
        })
        await model.configure(site: try makePackage(siteURL: Self.siteOrigin))
        #expect(model.conformanceAdvisory == nil)
    }

    @Test("refreshConformanceAdvisory is nil once V-3's required packages are release-ready")
    func refreshConformanceAdvisoryNilWhenReady() async throws {
        let status = try WorkersConformanceReader.parse("""
        {
          "packages": {
            "@dwk/micropub": { "standard": "Micropub", "suites": { "micropub.rocks": { "status": "passing" } }, "integration": { "status": "passing" } },
            "@dwk/webmention": { "standard": "Webmention", "suites": { "webmention.rocks/sender": { "status": "passing" }, "webmention.rocks/receiver": { "status": "passing" } }, "integration": { "status": "passing" } },
            "@dwk/websub": { "standard": "WebSub", "suites": {}, "integration": { "status": "passing" } }
          }
        }
        """.data(using: .utf8)!)
        let model = makeModel(conformanceStatus: { status })
        await model.refreshConformanceAdvisory()
        #expect(model.conformanceAdvisory == nil)
    }

    @Test("refreshConformanceAdvisory surfaces an honest label while @dwk/micropub is still pending")
    func refreshConformanceAdvisoryReportsPending() async throws {
        let status = try WorkersConformanceReader.parse("""
        { "packages": { "@dwk/micropub": { "standard": "Micropub", "suites": { "micropub.rocks": { "status": "pending" } }, "integration": { "status": "pending" } } } }
        """.data(using: .utf8)!)
        let model = makeModel(conformanceStatus: { status })
        await model.refreshConformanceAdvisory()
        #expect(model.conformanceAdvisory == WorkerActivation.micropubConformanceAdvisory(conformance: status))
        #expect(model.conformanceAdvisory != nil)
    }
}
