import SwiftUI
import AnglesiteCore

/// Drives the AI Search onboarding sheet: policy preflight → zone resolution → cost
/// confirmation → provisioning. Mirrors `HardenModel` exactly — same `@MainActor @Observable`
/// shape, same `apiToken()`/`cloudflareErrorMessage(_:)` helpers, same
/// `inFlight: Task<Void, Never>?` cancellation pattern, and the same #1289-review fix of
/// flipping `phase` out of its resting state synchronously (before the `Task` — and its
/// `await apiToken()` hop — starts) so `isRunning` can never under-report while a token
/// resolves or a second call races the first.
@MainActor
@Observable
final class AISearchModel {
    enum Phase: Equatable {
        case idle
        case resolvingZone(domain: String)
        case blockedByPolicy(reason: String)
        case awaitingCostConfirmation(domain: String, zoneID: String)
        case provisioning(domain: String)
        case succeeded(AISearchExecutor.ProvisionedResult)
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    var sheetPresented: Bool = false
    var domainInput: String = ""

    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    private let provisioner: any AISearchProvisioning
    private let preflight: any SitemapPreflighting
    private let keychain: any SecretStore
    private var inFlight: Task<Void, Never>?

    /// The owner-facing fix for a sitemap that isn't live at the domain — shared by the
    /// preflight short-circuit (#1494) and the create-time 7028 mapping (#1486) so the two
    /// paths can't drift apart.
    static let missingSitemapGuidance =
        "Your site's sitemap isn't reachable yet. Publish the site first, then set up AI Search."

    init(
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        provisioner: any AISearchProvisioning = HTTPCloudflareClient(),
        preflight: any SitemapPreflighting = HTTPSitemapPreflight(),
        keychain: any SecretStore = KeychainStore()
    ) {
        self.reader = reader
        self.writer = writer
        self.provisioner = provisioner
        self.preflight = preflight
        self.keychain = keychain
    }

    var isRunning: Bool {
        switch phase {
        case .resolvingZone, .provisioning: return true
        default: return false
        }
    }

    func openSheet() {
        guard !isRunning else { return }
        phase = .idle
        domainInput = ""
        sheetPresented = true
    }

    func checkPolicyAndResolveZone(sourceDirectory: URL) {
        let domain = domainInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !isRunning else { return }

        // Flip out of `.idle` synchronously, before the Task (and its `await apiToken()` hop,
        // which can now do a real OAuth-refresh network round trip) even starts — matching
        // HardenModel.resolveAndPlan()'s #1289-review fix, so `isRunning` can't under-report
        // while a token resolves.
        phase = .resolvingZone(domain: domain)

        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runCheckPolicyAndResolveZone(domain: domain, sourceDirectory: sourceDirectory)
        }
    }

    func confirmCost() {
        guard case .awaitingCostConfirmation(let domain, let zoneID) = phase else { return }

        // Flip to `.provisioning` synchronously before the Task starts (see
        // checkPolicyAndResolveZone()'s comment) — this also closes the double-click hole
        // HardenModel.apply() used to have: a second confirmCost() call while the token was
        // still resolving now sees phase already out of `.awaitingCostConfirmation` and no-ops.
        phase = .provisioning(domain: domain)

        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runProvision(domain: domain, zoneID: zoneID)
        }
    }

    func dismissSheet() {
        inFlight?.cancel()
        inFlight = nil
        sheetPresented = false
        phase = .idle
    }

    // MARK: - Private

    private func apiToken() async -> String? {
        try? await CloudflareAPICredentials.resolve(secretStore: keychain)
    }

    /// See `HardenModel.setPhase(_:)` — same helper, same rationale, kept in sync since the two
    /// models deliberately mirror each other (#1479).
    private func setPhase(_ newPhase: Phase) {
        guard !Task.isCancelled else { return }
        phase = newPhase
    }

    private func runCheckPolicyAndResolveZone(domain: String, sourceDirectory: URL) async {
        guard let token = await apiToken() else {
            setPhase(.failed(reason: CloudflareTokenMessage.notFoundWithHint))
            return
        }

        let policy: LicensingPolicy
        do {
            policy = try LicensingStore(sourceDirectory: sourceDirectory).load()
        } catch {
            setPhase(.failed(reason: "Couldn't read this site's AI usage policy: \(error.localizedDescription)"))
            return
        }
        if let reason = AISearchExecutor.policyBlockReason(for: policy) {
            setPhase(.blockedByPolicy(reason: reason))
            return
        }

        // Advisory sitemap probe (#1494): a definitive "not there" surfaces the deploy-first
        // fix *before* the owner is asked to confirm cost, instead of after a failed create.
        // Only `.unreachable` (404/410) blocks — ambiguous answers and transport failures
        // proceed and let the create itself decide, with the 7028 mapping (#1486) as the
        // backstop, so a flaky probe can never wedge the wizard. `async let`, not a
        // sequential await: the probe only needs `domain`, so it overlaps zone resolution
        // instead of stacking its (up to 5s) round trip on top.
        async let sitemapReachability = preflight.checkSitemap(domain: domain)
        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                setPhase(.failed(reason: "Zone not found for \"\(domain)\". Check the domain and ensure your API token has Zone Read permission."))
                return
            }
            let reachability = await sitemapReachability
            // Cancellation can surface as a *value*, not a thrown error: the preflight's
            // catch-all folds a cancelled request into `.indeterminate`, and a stub reader
            // may not throw at all. `setPhase(_:)` (the same guard used everywhere else in
            // this runner) catches that case too, so a superseded task can't write a stale
            // phase over the current task's — the classic wrong-domain footgun.
            if reachability == .unreachable {
                setPhase(.failed(reason: Self.missingSitemapGuidance))
                return
            }
            setPhase(.awaitingCostConfirmation(domain: domain, zoneID: zoneID))
        } catch let error as CloudflareError {
            setPhase(.failed(reason: cloudflareErrorMessage(error)))
        } catch {
            setPhase(.failed(reason: "Failed to resolve zone: \(error.localizedDescription)"))
        }
    }

    private func runProvision(domain: String, zoneID: String) async {
        guard let token = await apiToken() else {
            setPhase(.failed(reason: CloudflareTokenMessage.notFound))
            return
        }

        let executor = AISearchExecutor(reader: reader, writer: writer, provisioner: provisioner)
        do {
            let result = try await executor.provision(zoneID: zoneID, domain: domain, apiToken: token)
            setPhase(.succeeded(result))
        } catch AISearchProvisionError.missingSitemap {
            // Cloudflare 7028: the crawler can't find a sitemap at the domain. The app knows
            // the fix (the sitemap ships in every build but isn't live until the first
            // deploy), so say that — not the API code (#1486).
            setPhase(.failed(reason: Self.missingSitemapGuidance))
        } catch AISearchProvisionError.instanceIDCollision {
            // An existing AI Search instance already owns this domain's derived id but was
            // created for a different domain (#1478) — rare, but must not be reported as
            // success against someone else's instance.
            setPhase(.failed(reason: "An AI Search instance name conflict was found for this domain. This is unusual — contact support if it persists."))
        } catch let error as CloudflareError {
            setPhase(.failed(reason: cloudflareErrorMessage(error)))
        } catch {
            setPhase(.failed(reason: "Failed to provision AI Search: \(error.localizedDescription)"))
        }
    }

    private func cloudflareErrorMessage(_ error: CloudflareError) -> String {
        switch error {
        case .unauthorized:
            return "API token is unauthorized. Check that it has AI Search Edit permission for this account."
        case .http(let status):
            return "Cloudflare API returned HTTP \(status)."
        case .api(let message):
            return "Cloudflare API error: \(message)"
        case .malformedResponse:
            return "Unexpected response from Cloudflare API."
        }
    }
}
