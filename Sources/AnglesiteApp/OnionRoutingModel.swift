import SwiftUI
import AnglesiteCore

/// Onion Routing zone settings model. Presents a single toggle for `opportunistic_onion`,
/// reads the current status from Cloudflare, and applies changes with the user's API token.
/// Follows the same domain-input / phase pattern as `HardenModel`/`DomainModel` — the site's
/// package display name is not a domain, so the zone is resolved from user-entered input rather
/// than assumed from the site.
@MainActor
@Observable
final class OnionRoutingModel {
    enum Phase: Equatable {
        case idle
        case loading(domain: String)
        case configured(domain: String, enabled: Bool)
        case saving(domain: String)
        case error(message: String)
    }

    private(set) var phase: Phase = .idle
    var sheetPresented: Bool = false
    var domainInput: String = ""

    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    private let keychain: any SecretStore
    private var inFlight: Task<Void, Never>?

    init(
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        keychain: any SecretStore = KeychainStore()
    ) {
        self.reader = reader
        self.writer = writer
        self.keychain = keychain
    }

    var isRunning: Bool {
        switch phase {
        case .loading, .saving: return true
        default: return false
        }
    }

    func openSheet() {
        guard !isRunning else { return }
        phase = .idle
        domainInput = ""
        sheetPresented = true
    }

    func dismissSheet() {
        inFlight?.cancel()
        inFlight = nil
        sheetPresented = false
    }

    /// Matches `HardenModel.retryFromFailed()` — returns to the domain-input step without
    /// clearing what the user already typed.
    func retryFromError() {
        guard !isRunning else { return }
        phase = .idle
    }

    func load() {
        let domain = domainInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !isRunning else { return }
        phase = .loading(domain: domain)
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.loadOnionRouting(domain: domain)
        }
    }

    func toggle() {
        guard case .configured(let domain, let enabled) = phase else { return }
        guard !isRunning else { return }

        phase = .saving(domain: domain)
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.saveOnionRouting(domain: domain, enabled: !enabled)
        }
    }

    // MARK: - Private

    private func apiToken() async -> String? {
        try? await CloudflareAPICredentials.resolve(secretStore: keychain)
    }

    private func loadOnionRouting(domain: String) async {
        guard let token = await apiToken() else {
            phase = .error(message: CloudflareTokenMessage.notFoundWithHint)
            return
        }

        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                phase = .error(message: "Zone not found for \"\(domain)\". Check the domain and ensure your API token has Zone Read permission.")
                return
            }

            let zoneState = try await reader.zoneState(zoneID: zoneID, domain: domain, apiToken: token)
            phase = .configured(domain: domain, enabled: zoneState.onionRouting)
        } catch let error as CloudflareError {
            phase = .error(message: cloudflareErrorMessage(error))
        } catch {
            phase = .error(message: "Failed to load zone settings: \(error.localizedDescription)")
        }
    }

    private func saveOnionRouting(domain: String, enabled: Bool) async {
        guard let token = await apiToken() else {
            phase = .error(message: CloudflareTokenMessage.notFound)
            return
        }

        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                phase = .error(message: "Zone not found for \"\(domain)\". Check the domain and ensure your API token has Zone Read permission.")
                return
            }

            try await writer.enableOnionRouting(zoneID: zoneID, enabled: enabled, apiToken: token)
            phase = .configured(domain: domain, enabled: enabled)
        } catch let error as CloudflareError {
            phase = .error(message: cloudflareErrorMessage(error))
        } catch {
            phase = .error(message: "Failed to save zone settings: \(error.localizedDescription)")
        }
    }

    private func cloudflareErrorMessage(_ error: CloudflareError) -> String {
        switch error {
        case .unauthorized:
            return "API token is unauthorized. Check that it has Zone Settings Edit permission."
        case .http(let status):
            return "Cloudflare API returned HTTP \(status)."
        case .api(let message):
            return "Cloudflare API error: \(message)"
        case .malformedResponse:
            return "Unexpected response from Cloudflare API."
        }
    }
}
