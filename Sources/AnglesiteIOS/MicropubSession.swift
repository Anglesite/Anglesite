// Sources/AnglesiteIOS/MicropubSession.swift
import Foundation
import AnglesiteCore

/// The credential + endpoint bundle the compose surfaces need to talk to one site's Micropub
/// endpoint (#869) — the seam between this issue's posting UI and the sibling IndieAuth
/// onboarding issue (#868), which is where sessions are actually minted (endpoint discovery from
/// the site's well-knowns, `ASWebAuthenticationSession` sign-in, Keychain storage). The compose
/// stack only ever *consumes* a session; with no provider wired it shows its signed-out state.
public struct MicropubSession: Sendable {
    /// The site's Micropub endpoint (absolute URL, no query).
    public let micropubEndpoint: URL
    /// The media endpoint uploads go to, when discovery found one (`q=config`).
    public let mediaEndpoint: URL?
    /// The IndieAuth access token, DPoP-bound to `dpopKeyPair`.
    public let accessToken: String
    /// The key pair the token is bound to — the same grant's pair, or every call fails auth.
    public let dpopKeyPair: DPoPKeyPair

    /// Memberwise creation — public so the onboarding flow (#868) and tests can build sessions.
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
/// onboarded yet (or its token was revoked and needs a fresh sign-in). Implemented by the
/// IndieAuth onboarding flow (#868); the shell threads one provider through its screens.
public protocol MicropubSessionProviding: Sendable {
    /// The session for the site identified by `siteID` (the `.anglesite` package's stable site
    /// UUID), or `nil` when none exists yet.
    func session(forSite siteID: UUID) async -> MicropubSession?
}

/// The no-onboarding-yet default: every site reads as signed out, so the shell renders its
/// sign-in-required state until #868's provider replaces this.
public struct NoMicropubSessions: MicropubSessionProviding {
    /// Creates the empty provider.
    public init() {}

    public func session(forSite siteID: UUID) async -> MicropubSession? { nil }
}
