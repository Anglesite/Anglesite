// Sources/AnglesiteIOS/MicropubSession.swift
import Foundation
import AnglesiteCore
import AnglesiteSiteModel

/// The credential + endpoint bundle the compose surfaces need to talk to one site's Micropub
/// endpoint (#869) — the seam between the posting UI and the IndieAuth onboarding flow (#868),
/// which mints the underlying credentials (endpoint discovery from the site's well-knowns,
/// `ASWebAuthenticationSession` sign-in, Keychain storage). The compose stack only ever
/// *consumes* a session; with none resolvable it shows its signed-out state.
public struct MicropubSession: Sendable {
    /// The site's Micropub endpoint (absolute URL, no query).
    public let micropubEndpoint: URL
    /// The media endpoint uploads go to, when discovery found one (`q=config`).
    public let mediaEndpoint: URL?
    /// The IndieAuth access token, DPoP-bound to `dpopKeyPair`.
    public let accessToken: String
    /// The key pair the token is bound to — the same grant's pair, or every call fails auth.
    public let dpopKeyPair: DPoPKeyPair

    /// Memberwise creation — public so providers and tests can build sessions.
    public init(
        micropubEndpoint: URL,
        mediaEndpoint: URL?,
        accessToken: String,
        dpopKeyPair: DPoPKeyPair
    ) {
        self.micropubEndpoint = micropubEndpoint
        self.mediaEndpoint = mediaEndpoint
        self.accessToken = accessToken
        self.dpopKeyPair = dpopKeyPair
    }

    /// A `MicropubClient` presenting this session's credential.
    ///
    /// - Parameter transport: Defaults to the client's plain-`URLSession` transport; tests
    ///   inject a fake.
    /// - Returns: A ready client.
    public func makeClient(
        transport: @escaping MicropubClient.Transport = MicropubClient.defaultTransport
    ) -> MicropubClient {
        MicropubClient(
            endpoint: micropubEndpoint,
            mediaEndpoint: mediaEndpoint,
            accessToken: accessToken,
            dpopKeyPair: dpopKeyPair,
            transport: transport
        )
    }
}

/// Hands the compose stack a site's Micropub session, or `nil` when the site hasn't been
/// onboarded yet (or its stored credential is gone and needs a fresh sign-in). Production is
/// ``StoredMicropubSessions``; tests substitute their own.
public protocol MicropubSessionProviding: Sendable {
    /// The session for `site`, or `nil` when none can be assembled.
    func session(for site: SitePickerModel.DiscoveredSite) async -> MicropubSession?
}

/// Assembles a session from what the IndieAuth onboarding flow (#868) persisted: the
/// `micropub:<siteID>` token + DPoP key pair from the Keychain, plus a fresh endpoint
/// discovery — `MicropubOnboardingModel` deliberately does not persist discovery, leaving the
/// re-discovery on restore to "the composer's own flow", which is this type.
public struct StoredMicropubSessions: MicropubSessionProviding {
    private let secretStore: any SecretStore
    private let discovery: MicropubEndpointDiscovery
    private let clientTransport: MicropubClient.Transport
    /// `DeployCoordinator.resolveSiteURL` behind a seam so tests don't need a real
    /// `.site-config` on disk.
    private let resolveSiteURL: @Sendable (URL) -> String?

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - secretStore: Where #868's onboarding stored the per-site credential.
    ///   - discovery: Finds the site's `micropub` endpoint from its homepage rels.
    ///   - clientTransport: Transport for the `q=config` media-endpoint probe.
    ///   - resolveSiteURL: Maps a package's `Source/` directory to its deployed URL.
    public init(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        discovery: MicropubEndpointDiscovery = MicropubEndpointDiscovery(),
        clientTransport: @escaping MicropubClient.Transport = MicropubClient.defaultTransport,
        resolveSiteURL: @escaping @Sendable (URL) -> String? = {
            DeployCoordinator.resolveSiteURL(siteDirectory: $0)
        }
    ) {
        self.secretStore = secretStore
        self.discovery = discovery
        self.clientTransport = clientTransport
        self.resolveSiteURL = resolveSiteURL
    }

    public func session(for site: SitePickerModel.DiscoveredSite) async -> MicropubSession? {
        await session(
            siteID: site.id.uuidString,
            sourceDirectory: AnglesitePackage(url: site.packageURL).sourceURL)
    }

    /// The same assembly as ``session(for:)``, addressed by a site's raw identity instead of a
    /// `SitePickerModel.DiscoveredSite` — for callers (the Mac's CMS-mode save path, #800) that
    /// already hold a site's `Source/` directory directly and would otherwise have to fabricate a
    /// `packageURL` just to have this method re-derive the same directory from it.
    ///
    /// - Parameters:
    ///   - siteID: The site's stable marker UUID string (`SiteStore.Site.id` on the Mac,
    ///     `SitePickerModel.DiscoveredSite.id.uuidString` on iOS).
    ///   - sourceDirectory: The site's `Source/` directory, resolved to a deployed URL for
    ///     endpoint discovery.
    /// - Returns: The assembled session, or `nil` when no credential is stored, the site isn't
    ///   deployed yet, or endpoint discovery fails.
    public func session(siteID: String, sourceDirectory: URL) async -> MicropubSession? {
        guard let token = try? secretStore.readMicropubAccessToken(siteID: siteID),
              !token.isEmpty,
              let keyPair = try? secretStore.readMicropubDPoPKeyPair(siteID: siteID)
        else { return nil }
        // `.site-config` is real file I/O inside a possibly-still-materializing iCloud
        // package — hop off the main actor, same as `MicropubOnboardingModel.configure`.
        let resolve = resolveSiteURL
        let siteURL = await Task.detached(priority: .userInitiated) {
            resolve(sourceDirectory).flatMap(URL.init(string:))
        }.value
        guard let siteURL,
              let endpoints = try? await discovery.discover(siteURL: siteURL)
        else { return nil }
        // Media endpoint via `q=config`, best-effort: without it composing and publishing
        // still work — only in-form image uploads report the not-configured error.
        let probe = MicropubClient(
            endpoint: endpoints.micropub, accessToken: token, dpopKeyPair: keyPair,
            transport: clientTransport)
        let mediaEndpoint = (try? await probe.configuration())?.mediaEndpoint
        return MicropubSession(
            micropubEndpoint: endpoints.micropub,
            mediaEndpoint: mediaEndpoint,
            accessToken: token,
            dpopKeyPair: keyPair
        )
    }
}

/// The empty provider: every site reads as signed out. Previews and tests of the signed-out
/// surface use this.
public struct NoMicropubSessions: MicropubSessionProviding {
    /// Creates the empty provider.
    public init() {}

    public func session(for site: SitePickerModel.DiscoveredSite) async -> MicropubSession? {
        nil
    }
}
