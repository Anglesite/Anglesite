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
    private let keychain: any SecretStore
    private var inFlight: Task<Void, Never>?

    init(
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        provisioner: any AISearchProvisioning = HTTPCloudflareClient(),
        keychain: any SecretStore = KeychainStore()
    ) {
        self.reader = reader
        self.writer = writer
        self.provisioner = provisioner
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

    private func runCheckPolicyAndResolveZone(domain: String, sourceDirectory: URL) async {
        guard let token = await apiToken() else {
            phase = .failed(reason: "No Cloudflare API token found. Add one in Settings → Credentials.")
            return
        }

        let policy: LicensingPolicy
        do {
            policy = try LicensingStore(sourceDirectory: sourceDirectory).load()
        } catch {
            phase = .failed(reason: "Couldn't read this site's AI usage policy: \(error.localizedDescription)")
            return
        }
        if let reason = AISearchExecutor.policyBlockReason(for: policy) {
            phase = .blockedByPolicy(reason: reason)
            return
        }

        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                phase = .failed(reason: "Zone not found for \"\(domain)\". Check the domain and ensure your API token has Zone Read permission.")
                return
            }
            phase = .awaitingCostConfirmation(domain: domain, zoneID: zoneID)
        } catch let error as CloudflareError {
            phase = .failed(reason: cloudflareErrorMessage(error))
        } catch {
            phase = .failed(reason: "Failed to resolve zone: \(error.localizedDescription)")
        }
    }

    private func runProvision(domain: String, zoneID: String) async {
        guard let token = await apiToken() else {
            phase = .failed(reason: "No Cloudflare API token found.")
            return
        }

        let executor = AISearchExecutor(reader: reader, writer: writer, provisioner: provisioner)
        do {
            let result = try await executor.provision(zoneID: zoneID, domain: domain, apiToken: token)
            phase = .succeeded(result)
        } catch let error as CloudflareError {
            phase = .failed(reason: cloudflareErrorMessage(error))
        } catch {
            phase = .failed(reason: "Failed to provision AI Search: \(error.localizedDescription)")
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
