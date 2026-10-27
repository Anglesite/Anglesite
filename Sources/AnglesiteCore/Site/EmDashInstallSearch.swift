import Foundation
import Observation

/// The New Site wizard's search for EmDash installs the owner already has (#2106): reads the
/// owner's Cloudflare sign-in, finds the installs in their account, and holds the one they pick.
/// Copy-free like the rest of AnglesiteCore: the app words each state.
@MainActor
@Observable
public final class EmDashInstallSearch {
    public enum State: Equatable {
        /// Nothing searched yet.
        case idle
        /// No Cloudflare sign-in on this Mac: the owner has to sign in before anything can be found.
        case needsSignIn
        case searching
        /// The installs found, possibly none.
        case found([EmDashInstall])
        case failed(Failure)
    }

    public enum Failure: Equatable {
        /// The sign-in works but can't read EmDash's databases.
        case cannotReadDatabases
        /// Cloudflare refused the saved sign-in.
        case signInRefused
        /// The sign-in didn't lead to a Cloudflare account.
        case noAccount
        /// Signing in didn't finish.
        case signInFailed
        /// Cloudflare couldn't be reached, or answered unexpectedly.
        case unavailable
    }

    public typealias TokenSource = @Sendable () async throws -> String?
    public typealias AccountIDSource = @Sendable (_ token: String) async -> String?
    public typealias InstallsSource = @Sendable (_ accountID: String, _ token: String) async throws -> [EmDashInstall]

    public private(set) var state: State = .idle
    /// The Worker name of the install the owner picked, if any.
    public var selectedWorkerName: String?

    private let tokenSource: TokenSource
    private let accountIDSource: AccountIDSource
    private let installsSource: InstallsSource

    /// Production sources: the owner's saved Cloudflare sign-in, their first account, and
    /// ``EmDashInstallFinder`` over the live API.
    public static let defaultTokenSource: TokenSource = {
        try await CloudflareAPICredentials.resolve(secretStore: PlatformSecretStore.make())
    }
    public static let defaultAccountIDSource: AccountIDSource = {
        await CloudflareAccountLookup.resolveAccountID(
            apiToken: $0, baseURL: HTTPCloudflareClient.base, transport: HTTPCloudflareClient.defaultTransport)
    }
    public static let defaultInstallsSource: InstallsSource = {
        try await EmDashInstallFinder(accountID: $0, apiToken: $1).installs()
    }

    public init(
        tokenSource: @escaping TokenSource = EmDashInstallSearch.defaultTokenSource,
        accountIDSource: @escaping AccountIDSource = EmDashInstallSearch.defaultAccountIDSource,
        installsSource: @escaping InstallsSource = EmDashInstallSearch.defaultInstallsSource
    ) {
        self.tokenSource = tokenSource
        self.accountIDSource = accountIDSource
        self.installsSource = installsSource
    }

    /// The picked install, when it's one of those found.
    public var selectedInstall: EmDashInstall? {
        guard case .found(let installs) = state else { return nil }
        return installs.first { $0.workerName == selectedWorkerName }
    }

    /// The picked install, when it can be connected.
    public var connectableSelection: EmDashInstall? {
        selectedInstall.flatMap { $0.problem == nil ? $0 : nil }
    }

    /// Which search is current: a search started later supersedes an earlier one, whose
    /// results are dropped.
    private var generation = 0

    /// Finds the installs in the owner's account. Picks the only connectable one when there's
    /// exactly one, keeps an earlier pick that's still there, and drops one that isn't.
    ///
    /// Starting another search (Try Again, or the choice toggled back) supersedes this one: only
    /// the latest search ever writes the state. A cancelled search leaves the state ``State/idle``,
    /// never a failure, so the next look starts fresh.
    public func search() async {
        generation += 1
        let current = generation
        state = .searching
        let isCurrent = { [weak self] in self?.generation == current && !Task.isCancelled }
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            finish(current, cancelled: .idle, otherwise: error is CancellationError ? .idle : .failed(.signInRefused))
            return
        }
        guard isCurrent() else { return finish(current, cancelled: .idle, otherwise: .idle) }
        guard let token, !token.isEmpty else { return finish(current, cancelled: .idle, otherwise: .needsSignIn) }
        let accountID = await accountIDSource(token)
        guard isCurrent() else { return finish(current, cancelled: .idle, otherwise: .idle) }
        guard let accountID else { return finish(current, cancelled: .idle, otherwise: .failed(.noAccount)) }
        do {
            let installs = try await installsSource(accountID, token)
            guard isCurrent() else { return finish(current, cancelled: .idle, otherwise: .idle) }
            state = .found(installs)
            if !installs.contains(where: { $0.workerName == selectedWorkerName }) {
                let connectable = installs.filter { $0.problem == nil }
                selectedWorkerName = connectable.count == 1 ? connectable[0].workerName : nil
            }
        } catch is CancellationError {
            finish(current, cancelled: .idle, otherwise: .idle)
        } catch EmDashInstallFinder.FindError.cannotReadDatabases {
            finish(current, cancelled: .idle, otherwise: .failed(.cannotReadDatabases))
        } catch CloudflareError.unauthorized {
            finish(current, cancelled: .idle, otherwise: .failed(.signInRefused))
        } catch {
            finish(current, cancelled: .idle, otherwise: .failed(.unavailable))
        }
    }

    /// Ends search `current` with `otherwise`, or `cancelled` when the task was cancelled. A
    /// superseded search writes nothing.
    private func finish(_ current: Int, cancelled: State, otherwise: State) {
        guard generation == current else { return }
        state = Task.isCancelled ? cancelled : otherwise
    }

    /// Back to ``State/idle``, superseding any search in flight, so the next look starts fresh:
    /// the owner switched away from connecting an existing site.
    public func reset() {
        generation += 1
        state = .idle
    }

    /// Records that the app's Cloudflare sign-in didn't finish (not a cancel).
    public func signInFailed() {
        state = .failed(.signInFailed)
    }
}
