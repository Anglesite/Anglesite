import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CFAISearchInstance: Decodable, Sendable { let id: String; let name: String? }

// MARK: - AISearchProvisioning conformance

extension HTTPCloudflareClient: AISearchProvisioning {
    /// `POST /accounts/{id}/ai-search/instances`, creating a web-crawler-backed AI Search
    /// instance for `domain`. Resolves the account first via `core.resolveAccountID`.
    ///
    /// Unlike the other write paths, a 400 here is passed through and its error envelope
    /// decoded (#1486): Cloudflare validates the source website at create time, and a source
    /// with no reachable sitemap fails with code 7028 `missing_sitemap` (confirmed live,
    /// 2026-08-15) — for an Anglesite site that nearly always means "not deployed yet", which
    /// deserves better than a bare "HTTP 400". Code 7028 maps to
    /// ``AISearchProvisionError/missingSitemap``; any other decodable 400 surfaces Cloudflare's
    /// own message as ``CloudflareError/api(message:)``; an undecodable 400 body keeps the old
    /// ``CloudflareError/http(status:)`` behavior.
    ///
    /// Flat shape, no `namespaces` segment — follows developers.cloudflare.com/ai-search/
    /// get-started/api/'s verbatim curl examples. Cloudflare's auto-generated API reference
    /// disagrees (documents a namespaced /namespaces/{name}/instances path instead) — see
    /// Global Constraints. The flat shape is what the live API accepts (confirmed 2026-08-15,
    /// same verification session that surfaced the 7028 behavior).
    public func createAISearchInstance(
        domain: String, instanceID: String, apiToken: String
    ) async throws -> AISearchInstance {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        struct CreateBody: Encodable, Sendable {
            let id: String
            let type: String
            let source: String
        }
        let (data, http) = try await core.send(
            method: "POST", "/accounts/\(accountID)/ai-search/instances",
            body: CreateBody(id: instanceID, type: "web-crawler", source: domain),
            apiToken: apiToken, passthroughStatuses: [400])
        if http.statusCode == 400 { throw Self.createFailureError(from: data) }
        let result = try CloudflareHTTPCore.decodeEnvelopeResult(from: data, as: CFAISearchInstance.self)
        return AISearchInstance(id: result.id, name: result.name ?? instanceID)
    }

    /// Maps a create's 400 body to the most actionable error available: code 7028 →
    /// ``AISearchProvisionError/missingSitemap``, code 7022
    /// (`ai_search_with_this_name_already_exist`) → ``AISearchProvisionError/instanceAlreadyExists``
    /// (#1478), any other decodable envelope with a message → ``CloudflareError/api(message:)``,
    /// everything else → ``CloudflareError/http(status:)`` (the pre-#1486 behavior).
    private static func createFailureError(from data: Data) -> any Error {
        guard let env = try? JSONDecoder().decode(CFEnvelope<CFEmpty>.self, from: data),
              let errors = env.errors, !errors.isEmpty else {
            return CloudflareError.http(status: 400)
        }
        if errors.contains(where: { $0.code == 7028 }) { return AISearchProvisionError.missingSitemap }
        if errors.contains(where: { $0.code == 7022 }) { return AISearchProvisionError.instanceAlreadyExists }
        return CloudflareError.api(message: errors[0].message)
    }

    /// `GET /accounts/{id}/ai-search/instances/{id}`, returning just the instance's configured
    /// `source` (the crawled domain). See ``AISearchProvisioning/aiSearchInstanceSource(instanceID:apiToken:)``.
    public func aiSearchInstanceSource(instanceID: String, apiToken: String) async throws -> String {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        struct CFAISearchInstanceDetail: Decodable, Sendable { let source: String }
        let result = try await core.get(
            "/accounts/\(accountID)/ai-search/instances/\(instanceID)", apiToken: apiToken,
            as: CFAISearchInstanceDetail.self)
        return result.source
    }
}
