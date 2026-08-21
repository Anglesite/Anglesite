import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared "resolve the token's first visible Cloudflare account id" lookup (#1567 review) — used
/// by every `*Sync`/`*IfConfigured` orchestrator that needs an account id but has no
/// separately-stored one to key off (unlike #587's `ProvisionedResources.inboxAccountID`). A
/// personal Anglesite deployment has exactly one Cloudflare account per token, so "just take the
/// first account" is always correct. Previously duplicated privately, byte-for-byte, in both
/// `MicropubContentSync` and `ReceivedInteractionSync` — consolidated here so `ContactsAllowlistSync`
/// doesn't add a third copy.
enum CloudflareAccountLookup {
    private struct CFAccount: Decodable, Sendable { let id: String }
    private struct CFEnvelope: Decodable, Sendable { let success: Bool; let result: [CFAccount]? }

    static func resolveAccountID(apiToken: String, baseURL: String, transport: CloudflareTransport) async -> String? {
        guard let url = URL(string: "\(baseURL)/accounts?per_page=1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = try? await transport(request), (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(CFEnvelope.self, from: data), envelope.success
        else { return nil }
        return envelope.result?.first?.id
    }
}
