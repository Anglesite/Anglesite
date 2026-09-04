import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CFRegistrarRegisterRequest: Encodable, Sendable {
    let domain_name: String
}
/// Shared by the immediate register response body and the poll (`registration-status`) response
/// body — unlike search/check, both report a bare `state` field directly on `result`, confirmed
/// against the live API docs (no `domains`-style wrapper here).
private struct CFRegistrarRegistrationState: Decodable, Sendable {
    let state: String
}

// MARK: - CloudflareRegistrarWriting conformance

extension HTTPCloudflareClient: CloudflareRegistrarWriting {
    /// `POST /accounts/{id}/registrar/registrations`. See
    /// ``CloudflareRegistrarWriting/registerDomain(name:apiToken:)``.
    ///
    /// Reuses `core.send(method:_:body:apiToken:)` for request construction and 401/403/non-2xx
    /// mapping (201 and 202 both already fall inside `send`'s 200..<300 success range) rather
    /// than duplicating that logic a third time alongside `mutate`/`post` — the only thing this
    /// call needs beyond `send` is branching on which 2xx status came back.
    public func registerDomain(name: String, apiToken: String) async throws -> RegistrarRegistrationOutcome {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        let (data, http) = try await core.send(
            method: "POST", "/accounts/\(accountID)/registrar/registrations",
            body: CFRegistrarRegisterRequest(domain_name: name), apiToken: apiToken)
        if http.statusCode == 202 {
            return try await pollRegistrationStatus(domain: name, accountID: accountID, apiToken: apiToken)
        }
        return Self.outcome(forState: try Self.decodeState(from: data))
    }

    private static func decodeState(from data: Data) throws -> String {
        let env: CFEnvelope<CFRegistrarRegistrationState>
        do {
            env = try JSONDecoder().decode(CFEnvelope<CFRegistrarRegistrationState>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success, let state = env.result?.state else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing registration state")
        }
        return state
    }

    private static func outcome(forState state: String) -> RegistrarRegistrationOutcome {
        switch state {
        case "succeeded": return .succeeded
        case "action_required": return .actionRequired
        case "blocked": return .blocked
        case "failed": return .failed(reason: "Cloudflare reported the registration failed.")
        default: return .stillProcessing
        }
    }

    /// Polls `registration-status` every 2.5s, up to 6 times (~15s total — matching the API's own
    /// "synchronous in most cases (10s timeout)" framing with one poll's margin past it). Resolves
    /// to `.stillProcessing` if `state` never leaves `in_progress` in that window. No task survives
    /// past this method returning — there is no background/long-lived polling.
    private func pollRegistrationStatus(
        domain: String, accountID: String, apiToken: String
    ) async throws -> RegistrarRegistrationOutcome {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(2500))
            let state = try await core.get(
                "/accounts/\(accountID)/registrar/registrations/\(domain)/registration-status",
                apiToken: apiToken, as: CFRegistrarRegistrationState.self)
            let outcome = Self.outcome(forState: state.state)
            if case .stillProcessing = outcome { continue }
            return outcome
        }
        return .stillProcessing
    }
}
