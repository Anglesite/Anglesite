import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the Workers Issues relay at `issues.anglesite.dwk.io` (#2095 slice 3; relay in
/// `Workers/issues-relay`, design `docs/superpowers/specs/2026-09-30-worker-issues-autofix-design.md`
/// §4). Registers a site so the relay accepts its Workers Issues automation deliveries, renews
/// the registration on every publish, and revokes it when the owner turns the feature off.
///
/// The hostname is sent only so the relay can check its allowlist; the relay discards it.
/// Secrets never reach a log line or error string built here.
public struct WorkerIssuesRelayClient: Sendable {
    /// Same injectable-HTTP seam as ``GreenHostChecker/Transport``.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The relay's origin — Anglesite-operated infrastructure (decision D7).
    public static let defaultBaseURL = URL(string: "https://issues.anglesite.dwk.io")!

    public enum Failure: Error, Equatable, Sendable {
        /// The relay refused the registration token or the site's secret.
        case unauthorized
        /// The site's hostname isn't on the relay's allowlist (`*.dwk.io` during the first rollout).
        case hostnameNotAllowed
        /// Any other non-2xx status.
        case rejected(status: Int)
        /// The relay couldn't be reached.
        case network
        /// A 2xx whose body didn't decode.
        case invalidResponse
    }

    /// A successful registration or renewal.
    public struct Registration: Equatable, Sendable {
        /// A fresh webhook secret — present on first registration or rotation, `nil` on renewal
        /// (the site keeps the secret it already has).
        public let secret: String?
        /// Where the site's Workers Issues automation must deliver.
        public let hookURL: URL
        /// When the registration lapses unless a later publish renews it.
        public let expiresAt: Date

        public init(secret: String?, hookURL: URL, expiresAt: Date) {
            self.secret = secret
            self.hookURL = hookURL
            self.expiresAt = expiresAt
        }
    }

    private let baseURL: URL
    private let transport: Transport

    public init(baseURL: URL = WorkerIssuesRelayClient.defaultBaseURL, transport: @escaping Transport = WorkerIssuesRelayClient.defaultTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `POST /sites`. Passing the site's `currentSecret` renews without rotating it.
    public func register(
        siteID: String, hostname: String, catalogCommit: String, registrationToken: String, currentSecret: String?
    ) async -> Result<Registration, Failure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("sites"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(registrationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let currentSecret { request.setValue(currentSecret, forHTTPHeaderField: "X-Site-Secret") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "siteID": siteID, "hostname": hostname, "catalogCommit": catalogCommit,
        ])

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            return .failure(.network)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: return .failure(.unauthorized)
        case 403: return .failure(.hostnameNotAllowed)
        default: return .failure(.rejected(status: http.statusCode))
        }
        struct Body: Decodable {
            let hookPath: String
            let expiresAt: String
            let secret: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              body.hookPath.hasPrefix("/hook/"),
              let hookURL = URL(string: body.hookPath, relativeTo: baseURL)?.absoluteURL,
              let expiresAt = Self.parseDate(body.expiresAt)
        else { return .failure(.invalidResponse) }
        return .success(Registration(secret: body.secret, hookURL: hookURL, expiresAt: expiresAt))
    }

    /// `DELETE /sites/:siteID`, authorized by the site's own secret.
    public func revoke(siteID: String, secret: String) async -> Result<Void, Failure> {
        var request = URLRequest(url: baseURL.appendingPathComponent("sites").appendingPathComponent(siteID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        do {
            let (_, http) = try await transport(request)
            switch http.statusCode {
            case 200..<300: return .success(())
            case 401: return .failure(.unauthorized)
            default: return .failure(.rejected(status: http.statusCode))
            }
        } catch {
            return .failure(.network)
        }
    }

    public static let defaultTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The relay emits `Date.prototype.toISOString()` — ISO 8601 with milliseconds.
    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Keeps one site's relay registration in step with what its last publish actually deployed
/// (#2095 slice 3). Runs after every successful publish: registers or renews while the site's
/// Worker has Workers Issues on, and revokes once it doesn't. Never fails the publish — every
/// problem comes back as an ``Outcome`` for the caller to log or surface.
public enum WorkerIssuesReconciler {
    public enum Outcome: Equatable, Sendable {
        /// Issues is off and nothing was registered — nothing to do.
        case inactive
        /// Issues is on but the owner hasn't entered the relay registration token yet.
        case needsRegistrationToken
        /// Issues is on but the site has no public hostname yet (never published to a domain).
        case noHostname
        /// Registered or renewed. `secretRotated` means the Cloudflare automation must be
        /// (re)pointed at `hookURL` with the new secret before reports flow.
        case registered(hookURL: URL, expiresAt: Date, secretRotated: Bool)
        /// Issues was turned off; the registration was revoked and the local secret removed.
        case revoked
        /// The keychain couldn't be read or written without prompting.
        case secretStoreUnavailable
        case failed(WorkerIssuesRelayClient.Failure)
    }

    /// Whether the site Worker's generated config (`Config/wrangler.toml`) opts into Workers
    /// Issues — the ground truth of what the last publish deployed, rather than a re-derivation of
    /// `WorkerComposition`'s "does this site compose a Worker at all" rule.
    public static func issuesEnabled(inWranglerToml toml: String?) -> Bool {
        toml?.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "[observability.issues]" } ?? false
    }

    public static func reconcile(
        siteID: String,
        issuesEnabled: Bool,
        siteURL: URL?,
        catalogCommit: String = WorkerCatalogPin.commit,
        secrets: any SecretStore,
        client: WorkerIssuesRelayClient = WorkerIssuesRelayClient()
    ) async -> Outcome {
        let secretAccount = SecretAccounts.workerIssuesWebhookSecret(siteID: siteID)
        let currentSecret: String?
        do {
            currentSecret = try secrets.read(account: secretAccount)
        } catch {
            return .secretStoreUnavailable
        }

        guard issuesEnabled else {
            guard let currentSecret else { return .inactive }
            // Best-effort: if the relay is unreachable the registration simply lapses (30-day
            // expiry), so the local secret goes either way.
            _ = await client.revoke(siteID: siteID, secret: currentSecret)
            do { try secrets.delete(account: secretAccount) } catch { return .secretStoreUnavailable }
            return .revoked
        }

        let token: String?
        do {
            token = try secrets.read(account: SecretAccounts.workerIssuesRegistrationToken)
        } catch {
            return .secretStoreUnavailable
        }
        guard let token, !token.isEmpty else { return .needsRegistrationToken }
        guard let hostname = siteURL?.host?.lowercased(), !hostname.isEmpty else { return .noHostname }

        switch await client.register(
            siteID: siteID, hostname: hostname, catalogCommit: catalogCommit,
            registrationToken: token, currentSecret: currentSecret)
        {
        case .failure(let failure):
            return .failed(failure)
        case .success(let registration):
            if let fresh = registration.secret {
                do { try secrets.write(fresh, account: secretAccount) } catch { return .secretStoreUnavailable }
            }
            return .registered(
                hookURL: registration.hookURL, expiresAt: registration.expiresAt,
                secretRotated: registration.secret != nil)
        }
    }

    /// The post-publish entry point both deploy paths call (`DeployModel.runDeploy`,
    /// `SiteOperations.deployWithWorkerComposition`): reads what the publish actually deployed from
    /// `Config/wrangler.toml`, reconciles, records the result in `Config/settings.plist`, and writes
    /// one line to the Debug pane. Secrets never reach the log.
    @discardableResult
    public static func reconcileAfterPublish(
        siteID: String,
        configDirectory: URL,
        siteURL: URL?,
        configStore: SiteConfigStore,
        secrets: any SecretStore,
        logCenter: LogCenter = .shared,
        client: WorkerIssuesRelayClient = WorkerIssuesRelayClient()
    ) async -> Outcome {
        let outcome = await reconcile(
            siteID: siteID,
            issuesEnabled: issuesEnabled(inWranglerToml: WranglerConfigFile.read(configDirectory: configDirectory)),
            siteURL: siteURL, secrets: secrets, client: client)
        _ = try? await configStore.update { $0.workerIssuesRelay = apply(outcome, to: $0.workerIssuesRelay) }
        if let message = logMessage(for: outcome) {
            await logCenter.append(source: "deploy:\(siteID)", stream: .stdout, text: message)
        }
        return outcome
    }

    /// Debug-pane text for an outcome; `nil` when there's nothing worth saying.
    public static func logMessage(for outcome: Outcome) -> String? {
        switch outcome {
        case .inactive:
            return nil
        case .needsRegistrationToken:
            return "Worker error reports: add the relay registration token in Settings ▸ Advanced ▸ Developer Tools to start sending reports."
        case .noHostname:
            return "Worker error reports: waiting for the site's first public address before registering with the relay."
        case .registered(let hookURL, let expiresAt, let rotated):
            let expiry = ISO8601DateFormatter().string(from: expiresAt)
            return rotated
                ? "Worker error reports: registered with the relay (\(hookURL.absoluteString)); finish the one-time Cloudflare automation step in the site's Workers settings. Renews on each publish; lapses \(expiry)."
                : "Worker error reports: relay registration renewed until \(expiry)."
        case .revoked:
            return "Worker error reports: turned off; the relay registration was revoked."
        case .secretStoreUnavailable:
            return "Worker error reports: skipped — the keychain couldn't be read without asking. Publish again from the app to allow it."
        case .failed(let failure):
            return "Worker error reports: relay registration failed (\(failure)). The site published normally."
        }
    }

    /// Folds an outcome into the site's persisted state. A rotated secret invalidates whatever
    /// automation the owner set up before, so it resets `automationConfirmed`; revocation or an
    /// inactive site clears the state. Other outcomes (token missing, relay down) leave the last
    /// known registration as it was.
    public static func apply(_ outcome: Outcome, to state: WorkerIssuesRelayState?) -> WorkerIssuesRelayState? {
        switch outcome {
        case .registered(let hookURL, let expiresAt, let rotated):
            return WorkerIssuesRelayState(
                hookURL: hookURL, expiresAt: expiresAt,
                automationConfirmed: rotated ? false : (state?.automationConfirmed ?? false))
        case .revoked, .inactive:
            return nil
        case .needsRegistrationToken, .noHostname, .secretStoreUnavailable, .failed:
            return state
        }
    }
}

/// A site's relay registration as last recorded (`Config/settings.plist`). The webhook secret
/// itself lives only in the secret store (``SecretAccounts/workerIssuesWebhookSecret(siteID:)``).
public struct WorkerIssuesRelayState: Sendable, Codable, Equatable {
    /// Where the site's Workers Issues automation must deliver.
    public var hookURL: URL
    public var expiresAt: Date
    /// Whether the owner confirmed they created the Cloudflare automation for the current secret.
    /// Automations have no documented public API yet (design §8 Q1), so this is a one-time guided
    /// dashboard step rather than something Anglesite provisions itself.
    public var automationConfirmed: Bool

    public init(hookURL: URL, expiresAt: Date, automationConfirmed: Bool) {
        self.hookURL = hookURL
        self.expiresAt = expiresAt
        self.automationConfirmed = automationConfirmed
    }
}
