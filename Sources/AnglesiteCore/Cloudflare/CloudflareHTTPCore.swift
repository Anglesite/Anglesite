import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pagination metadata returned alongside list results.
struct CFResultInfo: Decodable, Sendable {
    let page: Int
    let total_pages: Int
}

/// Standard Cloudflare v4 response envelope.
struct CFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: T?
    struct APIError: Decodable, Sendable {
        let message: String
        /// Cloudflare's numeric error code (e.g. 7028 `missing_sitemap`). Optional because
        /// only paths that branch on a specific code consult it, and older envelope fixtures
        /// omit it.
        let code: Int?
    }
    let errors: [APIError]?
    let result_info: CFResultInfo?
}

/// Placeholder for write responses where we only check `success`.
struct CFEmpty: Decodable, Sendable {}

struct CFAccount: Decodable, Sendable { let id: String }

/// Shared HTTP primitives for the Cloudflare v4 REST API — envelope decode, pagination,
/// auth header, and `CloudflareError` mapping. Extracted from `HTTPCloudflareClient` (#1818)
/// so every conformance file that struct is split into (and any future Cloudflare v4 client)
/// can share one implementation instead of relying on Swift's file-scoped `private` to fake a
/// single translation unit.
struct CloudflareHTTPCore: Sendable {
    private let baseURL: String
    private let transport: CloudflareTransport

    init(baseURL: String, transport: @escaping CloudflareTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// GET `path`, decode `CFEnvelope<T>`, return the whole envelope or throw a mapped error.
    func getEnvelope<T: Decodable & Sendable>(_ path: String, apiToken: String, as: T.Type) async throws -> CFEnvelope<T> {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        return try await getEnvelope(url: url, apiToken: apiToken, as: T.self)
    }

    /// GET `url`, decode `CFEnvelope<T>`, return the whole envelope or throw a mapped error.
    /// Takes a pre-built `URL` (rather than a path string) so callers with query values that need
    /// real percent-encoding — e.g. free-text search keywords that may contain `&`/`=`/`+` — can
    /// build the request with `URLComponents`/`URLQueryItem` instead of manual string interpolation.
    func getEnvelope<T: Decodable & Sendable>(url: URL, apiToken: String, as: T.Type) async throws -> CFEnvelope<T> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        let env: CFEnvelope<T>
        do {
            env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        return env
    }

    /// GET `path` and return the decoded `result`, or throw `.api` when it is absent.
    func get<T: Decodable & Sendable>(_ path: String, apiToken: String, as type: T.Type) async throws -> T {
        let env = try await getEnvelope(path, apiToken: apiToken, as: type)
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// GET `url` and return the decoded `result`, or throw `.api` when it is absent. See
    /// `getEnvelope(url:apiToken:as:)` for why this pre-built-`URL` variant exists.
    func get<T: Decodable & Sendable>(url: URL, apiToken: String, as type: T.Type) async throws -> T {
        let env = try await getEnvelope(url: url, apiToken: apiToken, as: type)
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// Fetch every item across pages (Cloudflare caps `per_page` at 100, so a single page
    /// silently truncates a list with more than 100 items). `path` must already include its
    /// own query string (e.g. `...?per_page=100`); `&page=N` is appended per request.
    func paginated<T: Decodable & Sendable>(_ path: String, apiToken: String, as type: T.Type) async throws -> [T] {
        var all: [T] = []
        var page = 1
        while true {
            let env = try await getEnvelope("\(path)&page=\(page)", apiToken: apiToken, as: [T].self)
            all.append(contentsOf: env.result ?? [])
            guard let info = env.result_info, info.page < info.total_pages else { break }
            page += 1
        }
        return all
    }

    /// Builds and sends a `method` request to `path` with an encoded `body`, then maps
    /// 401/403 to ``CloudflareError/unauthorized`` and any other non-2xx status to
    /// ``CloudflareError/http(status:)``. `passthroughStatuses` lets a caller opt specific
    /// statuses out of the `.http` mapping so it can inspect the response body itself (e.g. a
    /// 400 whose error envelope carries an actionable Cloudflare error code).
    func send<Body: Encodable & Sendable>(
        method: String,
        _ path: String,
        body: Body,
        apiToken: String,
        passthroughStatuses: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await transport(request)
        if passthroughStatuses.contains(http.statusCode) { return (data, http) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        return (data, http)
    }

    /// GET `path` with no body, mapping 401/403 to ``CloudflareError/unauthorized`` and any other
    /// non-2xx status to ``CloudflareError/http(status:)`` — the read-side counterpart to `send`,
    /// for endpoints (like URL Scanner) that don't wrap responses in the `{success, result,
    /// errors}` v4 envelope `getEnvelope`/`get` assume, so those helpers don't fit.
    /// `passthroughStatuses` lets a caller opt specific non-2xx statuses out of the `.http`
    /// mapping to inspect the raw response itself (e.g. a 404 that means "not ready yet" rather
    /// than "doesn't exist").
    func fetchRaw(
        _ path: String, apiToken: String, passthroughStatuses: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if passthroughStatuses.contains(http.statusCode) { return (data, http) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        return (data, http)
    }

    func mutate<Body: Encodable & Sendable>(
        method: String,
        _ path: String,
        body: Body,
        apiToken: String
    ) async throws {
        let (data, _) = try await send(method: method, path, body: body, apiToken: apiToken)
        let env: CFEnvelope<CFEmpty>
        do {
            env = try JSONDecoder().decode(CFEnvelope<CFEmpty>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        if !env.success {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
    }

    /// POST `path` with `body`, decode `CFEnvelope<T>`, return its `result` — like `get`, but for
    /// POST calls that need the decoded payload back (unlike `mutate`, which only checks success).
    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String, body: Body, apiToken: String, as type: T.Type
    ) async throws -> T {
        let (data, _) = try await send(method: "POST", path, body: body, apiToken: apiToken)
        return try Self.decodeEnvelopeResult(from: data, as: T.self)
    }

    /// Decodes a `CFEnvelope<T>` response body and returns its `result`, mapping an
    /// undecodable body to ``CloudflareError/malformedResponse`` and a `success: false` or
    /// missing `result` to ``CloudflareError/api(message:)``.
    static func decodeEnvelopeResult<T: Decodable & Sendable>(from data: Data, as type: T.Type) throws -> T {
        let env: CFEnvelope<T>
        do {
            env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// Resolves the token's first visible account id — every account-scoped Cloudflare v4
    /// endpoint (Registrar, URL Scanner, AI Search, Workers) needs this.
    func resolveAccountID(apiToken: String) async throws -> String {
        let accounts = try await get("/accounts?per_page=1", apiToken: apiToken, as: [CFAccount].self)
        guard let accountID = accounts.first?.id else {
            throw CloudflareError.api(message: "no Cloudflare account visible to this token")
        }
        return accountID
    }
}
