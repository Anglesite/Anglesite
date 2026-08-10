import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteIOS
@testable import AnglesiteCore

/// A dictionary-backed `SecretStore` so tests seed the `micropub:<siteID>` slots #868's
/// onboarding writes without touching the real Keychain.
private final class DictionarySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String] = [:]

    func read(account: String) throws -> String? {
        lock.withLock { entries[account] }
    }

    func write(_ value: String, account: String) throws {
        lock.withLock {
            if value.isEmpty { entries[account] = nil } else { entries[account] = value }
        }
    }

    func delete(account: String) throws {
        lock.withLock { entries[account] = nil }
    }
}

/// Exercises `StoredMicropubSessions` (#869's rebase-time integration with #868): assembling a
/// session from the stored credential + fresh endpoint discovery, per
/// `MicropubOnboardingModel`'s restored-session contract (discovery is never persisted).
struct StoredMicropubSessionsTests {
    private static let site = SitePickerModel.DiscoveredSite(
        id: UUID(),
        displayName: "Owner Site",
        packageURL: URL(fileURLWithPath: "/tmp/Owner.anglesite"))

    private static func response(
        _ code: Int, headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://owner.example/")!, statusCode: code,
            httpVersion: nil, headerFields: headers)!
    }

    /// A homepage response advertising both rels the discovery requires.
    private static let discoveryResponse: (Data, HTTPURLResponse) = (
        Data(),
        response(200, headers: [
            "Link": "<https://owner.example/micropub>; rel=\"micropub\", "
                + "<https://owner.example/.well-known/oauth-authorization-server>; rel=\"indieauth-metadata\"",
        ])
    )

    private static func onboardedStore() throws -> DictionarySecretStore {
        let store = DictionarySecretStore()
        try store.writeMicropubAccessToken("stored-token", siteID: site.id.uuidString)
        try store.writeMicropubDPoPKeyPair(DPoPKeyPair(), siteID: site.id.uuidString)
        return store
    }

    @Test("no stored credential resolves to nil without any network I/O")
    func noCredentialIsSignedOut() async {
        nonisolated(unsafe) var requests = 0
        let provider = StoredMicropubSessions(
            secretStore: DictionarySecretStore(),
            discovery: MicropubEndpointDiscovery(transport: { _ in
                requests += 1
                return Self.discoveryResponse
            }),
            clientTransport: { _ in
                requests += 1
                return (Data(), Self.response(200))
            },
            resolveSiteURL: { _ in "https://owner.example" }
        )

        let session = await provider.session(for: Self.site)

        #expect(session == nil)
        #expect(requests == 0, "a signed-out site must not hit the network")
    }

    @Test("a stored credential re-discovers the endpoint and probes the media endpoint")
    func restoredSessionAssembles() async throws {
        let provider = StoredMicropubSessions(
            secretStore: try Self.onboardedStore(),
            discovery: MicropubEndpointDiscovery(transport: { _ in Self.discoveryResponse }),
            clientTransport: { request in
                // The q=config probe presents the stored, DPoP-bound credential.
                #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP stored-token")
                let config = try JSONSerialization.data(withJSONObject: [
                    "media-endpoint": "https://owner.example/media",
                    "q": ["config", "source"],
                ])
                return (config, Self.response(200))
            },
            resolveSiteURL: { _ in "https://owner.example" }
        )

        let session = try #require(await provider.session(for: Self.site))

        #expect(session.micropubEndpoint == URL(string: "https://owner.example/micropub")!)
        #expect(session.mediaEndpoint == URL(string: "https://owner.example/media")!)
        #expect(session.accessToken == "stored-token")
    }

    @Test("a failed q=config still yields a session, just without a media endpoint")
    func mediaProbeFailureIsNotFatal() async throws {
        let provider = StoredMicropubSessions(
            secretStore: try Self.onboardedStore(),
            discovery: MicropubEndpointDiscovery(transport: { _ in Self.discoveryResponse }),
            clientTransport: { _ in throw URLError(.timedOut) },
            resolveSiteURL: { _ in "https://owner.example" }
        )

        let session = try #require(await provider.session(for: Self.site))

        #expect(session.mediaEndpoint == nil)
        #expect(session.micropubEndpoint == URL(string: "https://owner.example/micropub")!)
    }

    @Test("an unreachable or rel-less site resolves to nil")
    func discoveryFailureIsSignedOut() async throws {
        let provider = StoredMicropubSessions(
            secretStore: try Self.onboardedStore(),
            discovery: MicropubEndpointDiscovery(transport: { _ in
                (Data(), Self.response(200))   // no Link header, no rels
            }),
            clientTransport: { _ in (Data(), Self.response(200)) },
            resolveSiteURL: { _ in "https://owner.example" }
        )

        let session = await provider.session(for: Self.site)
        #expect(session == nil)
    }

    @Test("an undeployed site (no resolvable site URL) resolves to nil")
    func undeployedSiteIsSignedOut() async throws {
        let provider = StoredMicropubSessions(
            secretStore: try Self.onboardedStore(),
            discovery: MicropubEndpointDiscovery(transport: { _ in Self.discoveryResponse }),
            clientTransport: { _ in (Data(), Self.response(200)) },
            resolveSiteURL: { _ in nil }
        )

        let session = await provider.session(for: Self.site)
        #expect(session == nil)
    }
}
