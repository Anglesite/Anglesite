import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A page on an EmDash site that the render backstop withheld from readers (#2097, #2055 slice 4).
///
/// The backstop (`Resources/Template/scripts/emdash-gate/render-backstop.ts`) records one row per
/// withheld path in the site's D1 database, in `anglesite_withheld_pages`. It records only the
/// kinds of check that failed, never the text that failed them.
public struct WithheldPage: Sendable, Equatable, Identifiable {
    /// Why a page was withheld, in terms the owner can act on (decision D1). The app words each case.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// Something on the page looks like a password, API key or private key.
        case secret
        /// The page shows content meant only for the owner's contacts.
        case restrictedContent
        /// The page links to a site-editing admin page.
        case adminLink
        /// The page couldn't be checked, so it was held back to be safe.
        case uncheckable

        /// The backstop's check categories (`Issue.category` in `scripts/gate-checks.ts`) mapped
        /// onto owner reasons. An unknown category reads as `uncheckable`: the page was held back
        /// for a reason this build doesn't recognise.
        public init(category: String) {
            switch category {
            case "exposed-token": self = .secret
            case "restricted-content-in-dist": self = .restrictedContent
            case "keystatic-route": self = .adminLink
            default: self = .uncheckable
            }
        }
    }

    /// The page's path on the site, e.g. `/articles/council-vote/`.
    public let path: String
    public let reasons: [Reason]
    /// When the backstop first and most recently withheld the page (ISO 8601).
    public let firstSeen: Date?
    public let lastSeen: Date?

    public var id: String { path }

    public init(path: String, reasons: [Reason], firstSeen: Date?, lastSeen: Date?) {
        self.path = path
        self.reasons = reasons
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Cloudflare D1 HTTP API client for an EmDash site's `anglesite_withheld_pages` table (#2097).
/// Same injectable-transport pattern as ``ExperimentEventsD1Client``: the token is passed in, and
/// `baseURL` and `transport` can point at a stub.
public struct WithheldPagesD1Client: Sendable {
    /// The table the render backstop writes (`WITHHELD_TABLE` in `render-backstop.ts`).
    public static let table = "anglesite_withheld_pages"

    private struct Row: Decodable {
        let path: String
        let categories: String
        let first_seen: String
        let last_seen: String
    }

    private struct QueryResult: Decodable {
        let results: [Row]?
        let success: Bool
    }

    private struct Envelope: Decodable {
        let success: Bool
        let result: [QueryResult]?
        let errors: [APIError]?
    }

    private struct APIError: Decodable {
        let message: String?
    }

    private struct QueryBody: Encodable {
        let sql: String
        let params: [String]
    }

    private let baseURL: String
    private let accountID: String
    private let databaseID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        databaseID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.databaseID = databaseID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Every withheld page, most recently withheld first. A site whose backstop has never withheld
    /// anything has no table yet; that reads as no pages rather than an error.
    public func list() async throws -> [WithheldPage] {
        let sql = "SELECT path, categories, first_seen, last_seen FROM \(Self.table) ORDER BY last_seen DESC"
        let rows: [Row]
        do {
            rows = try await query(sql: sql, params: [])
        } catch WithheldPagesError.noSuchTable {
            return []
        }
        return rows.map { row in
            let categories = (try? JSONDecoder().decode([String].self, from: Data(row.categories.utf8))) ?? []
            var reasons: [WithheldPage.Reason] = []
            for reason in categories.map(WithheldPage.Reason.init(category:)) where !reasons.contains(reason) {
                reasons.append(reason)
            }
            return WithheldPage(
                path: row.path,
                reasons: reasons.isEmpty ? [.uncheckable] : reasons,
                firstSeen: Self.date(row.first_seen),
                lastSeen: Self.date(row.last_seen))
        }
    }

    /// Removes a page's row once the app has confirmed the page is showing again.
    public func clear(path: String) async throws {
        do {
            _ = try await query(sql: "DELETE FROM \(Self.table) WHERE path = ?", params: [path])
        } catch WithheldPagesError.noSuchTable {
            return
        }
    }

    enum WithheldPagesError: Error {
        case noSuchTable
    }

    private func query(sql: String, params: [String]) async throws -> [Row] {
        guard let url = URL(string: "\(baseURL)/accounts/\(accountID)/d1/database/\(databaseID)/query") else {
            throw CloudflareError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(QueryBody(sql: sql, params: params))

        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        // D1 reports a query against a table that doesn't exist as a failed query, not a 404.
        if let messages = envelope?.errors?.compactMap(\.message),
           messages.contains(where: { $0.contains("no such table") }) {
            throw WithheldPagesError.noSuchTable
        }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        guard let envelope, envelope.success, let first = envelope.result?.first else {
            throw CloudflareError.malformedResponse
        }
        return first.results ?? []
    }

    private static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Loads an EmDash site's withheld pages for the site window (#2097).
public enum EmDashWithheldPages {
    /// Whether a page is no longer withheld. The default fetches it (see ``isServing``).
    public typealias ServingProbe = @Sendable (URL) async -> Bool

    /// The withheld pages still withheld, or `nil` when the site isn't set up for this: not an
    /// EmDash site with a known database (`SiteSettings.emdashD1DatabaseID`), no Cloudflare token,
    /// or the account lookup failed.
    ///
    /// A page that the site now serves, or that is gone (`isServing`, against `.site-config`'s
    /// `SITE_URL`), is cleared from the table and left out, so a fixed or deleted page's notice
    /// goes away on its own. If the
    /// site URL isn't known, nothing is cleared: every recorded page is still shown.
    public static func loadIfConfigured(
        sourceDirectory: URL,
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport,
        isServing: ServingProbe = EmDashWithheldPages.isServing
    ) async -> [WithheldPage]? {
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let databaseID = settings.emdashD1DatabaseID, !databaseID.isEmpty,
              let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty,
              let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return nil }
        let client = WithheldPagesD1Client(
            accountID: accountID, databaseID: databaseID, apiToken: token, baseURL: baseURL, transport: transport)
        return await load(client: client, siteURL: siteURL(sourceDirectory: sourceDirectory), isServing: isServing)
    }

    /// The core of ``loadIfConfigured(sourceDirectory:configDirectory:secretStore:baseURL:transport:isServing:)``.
    /// Returns `nil` if the table can't be read.
    public static func load(client: WithheldPagesD1Client, siteURL: URL?, isServing: ServingProbe) async -> [WithheldPage]? {
        guard let pages = try? await client.list() else { return nil }
        guard let siteURL else { return pages }
        var stillWithheld: [WithheldPage] = []
        for page in pages {
            if let url = probeURL(path: page.path, siteURL: siteURL), await isServing(url) {
                // Best-effort: if the delete fails, the row comes back next time and is re-checked.
                try? await client.clear(path: page.path)
            } else {
                stillWithheld.append(page)
            }
        }
        return stillWithheld
    }

    /// What the owner saw when they hid the withheld-pages notice: each page with its reasons. The
    /// notice comes back when this changes, so a new page, or a new reason on a page already
    /// listed (a secret where there was an admin link), is shown again.
    public static func noticeKey(_ pages: [WithheldPage]) -> [String] {
        pages.map { page in ([page.path] + page.reasons.map(\.rawValue)).joined(separator: "\n") }
    }

    /// The URL to probe for a recorded path, or `nil` if the path could resolve anywhere but the
    /// site itself. The path is the request's pathname, so it can start with `//`, which a URL
    /// resolves as another host; a `200` from that host must never clear a page still withheld.
    static func probeURL(path: String, siteURL: URL) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: siteURL)?.absoluteURL,
              url.scheme == siteURL.scheme, url.host == siteURL.host, url.port == siteURL.port
        else { return nil }
        return url
    }

    /// The site's public URL, from `.site-config`'s `SITE_URL` (https only).
    static func siteURL(sourceDirectory: URL) -> URL? {
        guard let contents = try? String(contentsOf: sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8),
              let value = SiteConfigFile.value(forKey: "SITE_URL", in: contents),
              let url = URL(string: value), url.scheme == "https"
        else { return nil }
        return url
    }

    /// Fetches the page and reports whether it's no longer withheld: it answered `200`, or it's
    /// gone (`404`, `410`) because the owner deleted or unpublished it, leaving nothing to fix. The
    /// backstop's withheld response is a `503`; that, any other status, and any failure to fetch
    /// keep the page listed.
    public static let isServing: ServingProbe = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return isResolved(status: (response as? HTTPURLResponse)?.statusCode)
    }

    /// Whether a probe's status means the page is no longer withheld (see ``isServing``).
    static func isResolved(status: Int?) -> Bool {
        [200, 404, 410].contains(status ?? 0)
    }
}
