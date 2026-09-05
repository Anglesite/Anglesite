import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URL Scanner `POST .../urlscanner/v2/scan` response — a flat object, unlike the rest of this
/// file's v4 endpoints: no `{success, result, errors}` envelope (confirmed against the live API
/// reference). Only `uuid` (the scan id to poll) is needed here.
private struct CFURLScanSubmission: Decodable, Sendable { let uuid: String }

/// One Agent Readiness check's result, as nested under
/// `meta.processors.agentReadiness.checks.<category>.<checkID>` in a finished scan's result.
private struct CFAgentReadinessCheck: Decodable, Sendable { let status: String }

/// The four *scored* Agent Readiness categories. `commerce` (x402/UCP/ACP) is deliberately
/// omitted — Cloudflare tracks it but excludes it from the tier, per the blog announcement.
private struct CFAgentReadinessChecks: Decodable, Sendable {
    let botAccessControl: [String: CFAgentReadinessCheck]?
    let contentAccessibility: [String: CFAgentReadinessCheck]?
    let discoverability: [String: CFAgentReadinessCheck]?
    let discovery: [String: CFAgentReadinessCheck]?
}

private struct CFAgentReadinessNextLevel: Decodable, Sendable { let name: String; let target: Int }

private struct CFAgentReadiness: Decodable, Sendable {
    let level: Int
    let levelName: String
    let checks: CFAgentReadinessChecks
    let nextLevel: CFAgentReadinessNextLevel?
}

private struct CFScanResult: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        struct Processors: Decodable, Sendable { let agentReadiness: CFAgentReadiness? }
        let processors: Processors?
    }
    let meta: Meta?
}

// MARK: - AgentReadinessScanning conformance

extension HTTPCloudflareClient: AgentReadinessScanning {
    /// `POST /accounts/{id}/urlscanner/v2/scan` with `options.agentReadiness: true`. Submitted
    /// `unlisted` — the app shouldn't publish an owner's scan to Cloudflare's public URL Scanner
    /// listing without their say-so. Reuses `core.resolveAccountID` since URL Scanner is
    /// account-scoped too.
    public func submitAgentReadinessScan(url: URL, apiToken: String) async throws -> UUID {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        struct ScanRequest: Encodable, Sendable {
            struct Options: Encodable, Sendable { let agentReadiness: Bool }
            let url: String
            let visibility: String
            let options: Options
        }
        let body = ScanRequest(url: url.absoluteString, visibility: "unlisted", options: .init(agentReadiness: true))
        let (data, _) = try await core.send(method: "POST", "/accounts/\(accountID)/urlscanner/v2/scan", body: body, apiToken: apiToken)
        let submission: CFURLScanSubmission
        do {
            submission = try JSONDecoder().decode(CFURLScanSubmission.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard let scanID = UUID(uuidString: submission.uuid) else { throw CloudflareError.malformedResponse }
        return scanID
    }

    /// `GET /accounts/{id}/urlscanner/v2/result/{scan_id}`. Two different "not ready yet" shapes
    /// both map to `nil` rather than an error, so callers can poll in a loop without
    /// special-casing either: a 404 (the URL Scanner API's documented behavior for an in-flight
    /// scan id that hasn't produced *any* result yet), and a 200 whose `meta.processors` doesn't
    /// carry an `agentReadiness` section yet. That second case matters because the scan's base
    /// result (page load, requests) can land before its async processors — `agentReadiness`
    /// included — finish; without it, the very first poll (or every poll before that processor
    /// completes) would otherwise hard-fail with `.malformedResponse` instead of just meaning "not
    /// done yet". This was flagged in review (#1248) as unverified against a live scan — Cloudflare
    /// doesn't document a separate in-progress marker (e.g. on `task`) to distinguish that from a
    /// scan that's genuinely finished with no Agent Readiness data at all, so a persistently
    /// missing section still resolves the same way an in-progress one does: the caller's poll loop
    /// times out and surfaces "didn't finish in time" rather than a hard error either way. A
    /// response that doesn't even decode as the expected shape is left as `.malformedResponse` —
    /// that's a different, more clearly broken case than an optional inner section being absent.
    public func agentReadinessResult(scanID: UUID, apiToken: String) async throws -> AgentReadinessReport? {
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        let (data, http) = try await core.fetchRaw(
            "/accounts/\(accountID)/urlscanner/v2/result/\(scanID.uuidString.lowercased())",
            apiToken: apiToken, passthroughStatuses: [404])
        if http.statusCode == 404 { return nil }
        let result: CFScanResult
        do {
            result = try JSONDecoder().decode(CFScanResult.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard let readiness = result.meta?.processors?.agentReadiness else {
            return nil
        }
        return Self.mapAgentReadinessReport(readiness)
    }

    /// Maps the raw wire shape to the public report, translating each check id through
    /// `AgentReadinessCatalog` for owner-friendly copy. A category with no checks in the response
    /// (all four are optional on the wire) is dropped rather than shown empty.
    private static func mapAgentReadinessReport(_ raw: CFAgentReadiness) -> AgentReadinessReport {
        func category(_ dict: [String: CFAgentReadinessCheck]?, id: String) -> AgentReadinessReport.Category? {
            guard let dict, !dict.isEmpty else { return nil }
            let checks = dict.map { checkID, rawCheck -> AgentReadinessReport.Check in
                let info = AgentReadinessCatalog.checkInfo(for: checkID)
                let status = AgentReadinessReport.Check.Status(rawValue: rawCheck.status.lowercased()) ?? .neutral
                return AgentReadinessReport.Check(
                    id: checkID, displayName: info.displayName, status: status,
                    hint: status == .pass ? info.passHint : info.failHint,
                    anglesiteProvides: info.anglesiteProvides)
            }.sorted { $0.displayName < $1.displayName }
            return AgentReadinessReport.Category(
                id: id, displayName: AgentReadinessCatalog.categoryDisplayName(for: id), checks: checks)
        }

        let categories = [
            category(raw.checks.discoverability, id: "discoverability"),
            category(raw.checks.contentAccessibility, id: "contentAccessibility"),
            category(raw.checks.botAccessControl, id: "botAccessControl"),
            category(raw.checks.discovery, id: "discovery"),
        ].compactMap { $0 }

        return AgentReadinessReport(
            level: raw.level, levelName: raw.levelName, categories: categories,
            nextLevel: raw.nextLevel.map { AgentReadinessReport.NextLevel(name: $0.name, target: $0.target) })
    }
}
