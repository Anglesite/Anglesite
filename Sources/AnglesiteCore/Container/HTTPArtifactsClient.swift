import Foundation
// URLSession types live in FoundationNetworking on non-Darwin platforms.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failure taxonomy for the Cloudflare Artifacts REST API, mirroring `GitHubRepoAPIError` so
/// `ArtifactsRepoProvider` (slice 3, #1266) can map cases to owner-facing messages the same way.
/// Duplicate-name failures arrive as `.api(message:)` with Cloudflare's own message — the API's
/// error codes are unverified in private beta, so none are special-cased yet.
public enum ArtifactsAPIError: Error, Equatable, Sendable {
    /// The request never got an HTTP response (offline, DNS, TLS).
    case network
    /// 401/403 — the token lacks Artifacts access (or beta enrollment).
    case unauthorized(status: Int)
    /// Any other non-2xx status.
    case http(status: Int)
    /// A 2xx envelope with `success: false`; carries Cloudflare's first error message verbatim.
    case api(message: String)
    /// A 2xx envelope that didn't decode.
    case malformedResponse
}

/// Cloudflare Artifacts REST client. Endpoint path and response shape are private-beta
/// assumptions (#1266) — kept in this one file, alongside `RepoHost.artifactsHostName`, so beta
/// verification is a single-file correction. Only creates the remote repository; wiring `origin`
/// and pushing is `ArtifactsRepoProvider`'s job (slice 3), matching the `HTTPGitHubClient` split.
public struct HTTPArtifactsClient: Sendable {
    private let baseURL: URL
    private let transport: CloudflareTransport

    /// Creates a client. Both parameters exist for tests — production callers take the defaults.
    public init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Creates a repository under the account and returns it as a `RemoteRepo` with
    /// `host == .cloudflareArtifacts` and `owner == accountID`.
    ///
    /// - Parameters:
    ///   - name: The repository name to create.
    ///   - isPrivate: Whether the repository should be private.
    ///   - accountID: The Cloudflare account under which to create the repository; becomes the
    ///     returned `RemoteRepo`'s `owner`.
    ///   - token: A Cloudflare API token authorized for Artifacts on `accountID`.
    /// - Returns: The created repository as a `RemoteRepo`.
    /// - Throws: ``ArtifactsAPIError`` — `.network` if the request never got a response,
    ///   `.unauthorized(status:)` for a 401/403, `.http(status:)` for any other non-2xx status,
    ///   `.api(message:)` for a 2xx envelope with `success: false`, or `.malformedResponse` for a
    ///   2xx envelope that didn't decode or that yielded an unusable browse URL.
    public func createRepo(name: String, isPrivate: Bool, accountID: String, token: String) async throws -> RemoteRepo {
        struct Body: Encodable {
            let name: String
            let isPrivate: Bool
            enum CodingKeys: String, CodingKey { case name, isPrivate = "private" }
        }
        let data = try await send(
            path: "accounts/\(accountID)/artifacts/repos",
            method: "POST",
            body: try JSONEncoder().encode(Body(name: name, isPrivate: isPrivate)),
            token: token)

        struct Result: Decodable { let name: String }
        let result: Result = try Self.decodeEnvelope(data)
        guard let url = RepoHost.cloudflareArtifacts.browseURL(owner: accountID, name: result.name) else {
            throw ArtifactsAPIError.malformedResponse
        }
        return RemoteRepo(url: url, owner: accountID, name: result.name, host: .cloudflareArtifacts)
    }

    /// True when the account can list Artifacts repos — the #1266 private-beta gate. Strict on
    /// purpose: only a 2xx `success: true` envelope counts, so a 404 from an account without
    /// beta access reads as unavailable (`CloudflareCapabilityProber`'s permissive not-401/403
    /// rule would get this wrong). Advisory like all probes — callers may re-probe.
    ///
    /// - Parameters:
    ///   - accountID: The Cloudflare account to probe.
    ///   - token: A Cloudflare API token to probe with.
    /// - Returns: `true` when a 2xx `success: true` envelope came back; `false` for any other
    ///   outcome, including a transport failure or non-2xx status — this never throws.
    public func probeAvailability(accountID: String, token: String) async -> Bool {
        struct Repo: Decodable {}
        guard let data = try? await send(
            path: "accounts/\(accountID)/artifacts/repos?per_page=1",
            method: "GET", body: nil, token: token)
        else { return false }
        return (try? Self.decodeEnvelope(data) as [Repo]) != nil
    }

    /// Sends one authenticated request; maps transport/status failures to `ArtifactsAPIError`.
    private func send(path: String, method: String, body: Data?, token: String) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw ArtifactsAPIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw ArtifactsAPIError.network
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ArtifactsAPIError.unauthorized(status: http.statusCode)
        default: throw ArtifactsAPIError.http(status: http.statusCode)
        }
    }

    /// Unwraps Cloudflare's `{success, errors, result}` envelope; `success: false` becomes
    /// `.api(message:)` with the first error message.
    private static func decodeEnvelope<T: Decodable>(_ data: Data) throws -> T {
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw ArtifactsAPIError.malformedResponse
        }
        guard envelope.success, let result = envelope.result else {
            throw ArtifactsAPIError.api(message: envelope.errors?.first?.message ?? "Cloudflare returned an unexpected response.")
        }
        return result
    }

    private struct Envelope<R: Decodable>: Decodable {
        let success: Bool
        let errors: [APIMessage]?
        let result: R?
        struct APIMessage: Decodable { let message: String }
    }
}
