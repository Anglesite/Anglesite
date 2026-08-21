import Foundation
import Observation
import AnglesiteCore
import AnglesiteSiteModel
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The seam between ``MicropubOnboardingModel`` and `ASWebAuthenticationSession`: presents the
/// authorize URL and resolves with the callback URL the session captured. The production
/// adapter lives in `AnglesiteMobile` (SwiftUI's `webAuthenticationSession` environment needs a
/// view); tests inject fakes, keeping this module free of AuthenticationServices.
public protocol SiteWebAuthenticating: Sendable {
    /// Presents `authorizeURL` and returns the captured `callbackScheme` URL. Throws
    /// ``SiteWebAuthenticationCancelled`` when the user dismissed the session — a distinct
    /// signal, per #868, never conflated with a network failure.
    func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL
}

/// The user closed the web-auth sheet without completing sign-in. Its own error type so the
/// model (and UI) can treat dismissal as a calm, expected outcome rather than a failure.
public struct SiteWebAuthenticationCancelled: Error, Equatable {
    public init() {}
}

/// Drives IndieAuth onboarding for the iOS Micropub posting client (#868): pick a site from the
/// iCloud list (`SitePickerModel`, #866) → discover its `micropub` + `indieauth-metadata`
/// endpoints → sign in against *the site's own* IndieAuth server via
/// `ASWebAuthenticationSession` → keep the DPoP-bound token in the Keychain, scoped to this
/// site and distinct from both the Mac's Cloudflare token and the Mac reader's Microsub
/// session. App glue only — protocol logic lives in `AnglesiteCore`
/// (`MicropubEndpointDiscovery`, `SiteIndieAuthClient`, `DPoPKeyPair`), mirroring
/// `MicrosubReaderModel`'s split on the Mac.
@MainActor
@Observable
public final class MicropubOnboardingModel {
    /// Why a sign-in attempt didn't produce a session — semantic cases, not display strings,
    /// so the view layer owns all user-facing (localizable) text.
    public enum FailureReason: Equatable, Sendable {
        /// The site's homepage advertises no `rel="micropub"` — its Worker doesn't ship the
        /// V-3 Micropub capability yet. The UI names the requirement instead of degrading.
        case micropubNotSupported
        /// The site's homepage advertises no `rel="indieauth-metadata"`.
        case indieAuthNotSupported
        /// The site couldn't be reached at all (offline, DNS, non-2xx homepage).
        case siteUnreachable(String)
        /// Everything else: a bad callback, a rejected token exchange, a Keychain write error.
        case signInFailed(String)
    }

    public enum State: Equatable {
        /// `configure(site:)` hasn't run yet.
        case idle
        /// The package's `Source/.site-config` has no `SITE_URL` — the site has never been
        /// deployed, so there is nothing to sign in against.
        case needsDeployedSite
        case signedOut
        /// Fetching the homepage rels + IndieAuth metadata.
        case discovering
        /// The web-auth session is presented; waiting on the user.
        case authorizing
        /// Redeeming the authorization code for a token.
        case exchanging
        case signedIn(me: String)
        /// The user dismissed the web-auth session — distinct from `.failed` by issue
        /// requirement: dismissal is a choice, not an error to alarm about.
        case cancelled
        /// `MicropubClient` reported 401/403 — the stored session is gone and sign-in must
        /// run again. Distinct from `.signedOut` so the UI can say *why*.
        case reauthorizationRequired
        case failed(FailureReason)
    }

    public private(set) var state: State = .idle

    /// A ready-to-use client for the site's Micropub endpoint after a fresh sign-in. `nil`
    /// before sign-in and after a restored-from-Keychain session (the endpoint is re-discovered
    /// on the next sign-in or by the composer's own flow; discovery is not persisted).
    public private(set) var micropubClient: MicropubClient?

    /// Honest-labeling advisory for posting's V-3 conformance gate (#800/#801), set by
    /// ``refreshConformanceAdvisory()``. `nil` until that runs, and again once V-3 is
    /// release-ready — never blocks or hides sign-in/posting either way; see
    /// `WorkerActivation.micropubConformanceAdvisory`'s doc comment.
    public private(set) var conformanceAdvisory: String?

    private var siteID: String?
    private var siteURL: URL?
    private let secretStore: any SecretStore
    private let discovery: MicropubEndpointDiscovery
    private let indieAuthClient: SiteIndieAuthClient
    private let webAuthenticator: any SiteWebAuthenticating
    /// Fetches the current `@dwk/workers` conformance snapshot for ``refreshConformanceAdvisory()``.
    /// A closure, not a concrete `WorkersConformanceFetcher`, so tests can substitute a fixture
    /// without any network I/O — the same DI shape `discovery`/`indieAuthClient` already use via
    /// their injected `transport` closures. Never called by ``configure(site:)`` itself, so every
    /// existing "no network I/O" test on `configure` stays true; callers opt in explicitly.
    private let conformanceStatus: @Sendable () async -> WorkersConformanceStatus

    public init(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        discovery: MicropubEndpointDiscovery = MicropubEndpointDiscovery(),
        indieAuthClient: SiteIndieAuthClient = SiteIndieAuthClient(),
        webAuthenticator: any SiteWebAuthenticating,
        conformanceStatus: @escaping @Sendable () async -> WorkersConformanceStatus = { await MicropubOnboardingModel.fetchProductionConformanceStatus() }
    ) {
        self.secretStore = secretStore
        self.discovery = discovery
        self.indieAuthClient = indieAuthClient
        self.webAuthenticator = webAuthenticator
        self.conformanceStatus = conformanceStatus
    }

    /// Refreshes ``conformanceAdvisory`` from the injected `conformanceStatus` fetch — call
    /// separately from ``configure(site:)``, e.g. sequentially after it in the same `.task`.
    /// Safe to await directly rather than detaching into its own `Task`: `configure(site:)`
    /// already drives every other piece of visible state, so SwiftUI has already re-rendered
    /// sign-in/connect by the time this runs, and awaiting it inline (instead of a separate
    /// unstructured `Task`) ties its lifetime to the enclosing `.task`, so it's cancelled — not
    /// orphaned — if the view disappears mid-fetch (#800 review feedback).
    public func refreshConformanceAdvisory() async {
        conformanceAdvisory = WorkerActivation.micropubConformanceAdvisory(conformance: await conformanceStatus())
    }

    /// Production default for `conformanceStatus`: the shared bounded-timeout production fetcher
    /// (see `WorkersConformanceFetcher.productionBounded()`), the same one `DeployModel` uses for
    /// its debug-pane advisory.
    public static func fetchProductionConformanceStatus() async -> WorkersConformanceStatus {
        await WorkersConformanceFetcher.productionBounded().status()
    }

    /// Records which site this model signs in for, resolves its deployed URL from
    /// `Source/.site-config` (via `DeployCoordinator.resolveSiteURL`, which does its own
    /// default-`FileManager` I/O), and restores an already-signed-in session from the
    /// Keychain. No network I/O. The `.site-config` read is real file I/O inside a
    /// possibly-still-materializing iCloud package, so it hops off the main actor like
    /// `SitePickerModel`'s marker reads.
    public func configure(site: SitePickerModel.DiscoveredSite) async {
        let id = site.id.uuidString
        siteID = id
        let sourceURL = AnglesitePackage(url: site.packageURL).sourceURL
        let resolved = await Task.detached(priority: .userInitiated) {
            DeployCoordinator.resolveSiteURL(siteDirectory: sourceURL).flatMap { URL(string: $0) }
        }.value
        siteURL = resolved
        guard let resolved else {
            state = .needsDeployedSite
            return
        }
        if let token = try? secretStore.readMicropubAccessToken(siteID: id), !token.isEmpty,
           (try? secretStore.readMicropubDPoPKeyPair(siteID: id)) != nil {
            // The `me` claim isn't persisted separately — a single-owner site's IndieAuth
            // canonicalizes to its own origin, same reasoning as `MicrosubReaderModel`.
            state = .signedIn(me: resolved.absoluteString)
        } else {
            state = .signedOut
        }
    }

    /// Runs the full onboarding flow: discovery → authorize (web-auth session) → code
    /// exchange → Keychain store. Also the re-auth path after `.reauthorizationRequired` —
    /// re-authenticating is the same flow, just entered with a reason on screen.
    public func signIn() async {
        guard let siteID, let siteURL else { return }
        switch state {
        case .idle, .needsDeployedSite, .discovering, .authorizing, .exchanging:
            return
        case .signedOut, .signedIn, .cancelled, .reauthorizationRequired, .failed:
            break
        }

        state = .discovering
        let endpoints: SiteMicropubEndpoints
        let request: SiteIndieAuthRequest
        do {
            endpoints = try await discovery.discover(siteURL: siteURL)
            request = try await indieAuthClient.makeAuthorizationRequest(
                metadataURL: endpoints.indieAuthMetadata,
                scope: SiteIndieAuthAppAuth.micropubScope,
                clientID: SiteIndieAuthAppAuth.clientID(siteURL: siteURL),
                redirectURI: SiteIndieAuthAppAuth.redirectURI(siteURL: siteURL)
            )
        } catch let error as MicropubDiscoveryError {
            state = .failed(Self.reason(for: error))
            return
        } catch {
            // Anything past homepage discovery — e.g. `SiteIndieAuthError.discoveryUnavailable`
            // for a reachable-but-broken metadata document — is a sign-in failure, not a
            // connectivity problem: "check your connection" would be wrong guidance when the
            // fix is server-side.
            state = .failed(.signInFailed(String(describing: error)))
            return
        }

        state = .authorizing
        let callbackURL: URL
        do {
            callbackURL = try await webAuthenticator.authenticate(
                authorizeURL: request.authorizeURL,
                callbackScheme: SiteIndieAuthAppAuth.callbackScheme
            )
        } catch is SiteWebAuthenticationCancelled {
            state = .cancelled
            return
        } catch {
            state = .failed(.signInFailed(String(describing: error)))
            return
        }

        state = .exchanging
        do {
            let code = try SiteIndieAuthClient.authorizationCode(
                from: callbackURL, matching: request,
                expectedCallback: SiteIndieAuthAppAuth.expectedCallback
            )
            let keyPair = DPoPKeyPair()
            let token = try await indieAuthClient.exchange(code: code, for: request, dpopKeyPair: keyPair)
            try secretStore.writeMicropubAccessToken(token.accessToken, siteID: siteID)
            try secretStore.writeMicropubDPoPKeyPair(keyPair, siteID: siteID)
            micropubClient = MicropubClient(
                endpoint: endpoints.micropub, accessToken: token.accessToken, dpopKeyPair: keyPair
            )
            state = .signedIn(me: token.me)
        } catch {
            state = .failed(.signInFailed(String(describing: error)))
        }
    }

    /// `MicropubClient`'s (#867) auth signal: on `.unauthorized` (a 401/403 from the site's
    /// endpoint) the stored session is dead — clear it as one unit and ask for re-auth. Every
    /// other Micropub error is the caller's to retry/queue; it says nothing about the session.
    public func handleMicropubError(_ error: MicropubError) {
        guard case .unauthorized = error, let siteID else { return }
        try? secretStore.clearMicropubSession(siteID: siteID)
        micropubClient = nil
        state = .reauthorizationRequired
    }

    /// Clears the stored session (token + key pair, one unit) and returns to `.signedOut`.
    public func signOut() {
        if let siteID { try? secretStore.clearMicropubSession(siteID: siteID) }
        micropubClient = nil
        state = .signedOut
    }

    private static func reason(for error: MicropubDiscoveryError) -> FailureReason {
        switch error {
        case .micropubNotAdvertised: .micropubNotSupported
        case .indieAuthNotAdvertised: .indieAuthNotSupported
        case .unreachable(let detail): .siteUnreachable(detail)
        }
    }
}
