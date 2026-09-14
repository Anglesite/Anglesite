import Foundation

/// `AuditRunner` for the `.seo` category (#2004): flags built pages that are missing (or carry
/// malformed) the basic on-page signals that determine search and share-preview quality — a
/// `<title>`, a `<meta name="description">`, and a `<link rel="canonical">`.
///
/// Deliberately spawns nothing and ignores `executor`, the same posture
/// `SecurityTxtAuditRunner` documents: it reads `dist/**/*.html` directly off the filesystem with
/// `FileManager`. `AuditCommand` already runs the build step before any runner, so `dist/` is
/// fresh. `og:image` dimension checks are out of scope (#1995 tracks that slice) — `AnglesiteCore`
/// deliberately carries no image-decoding dependency (see `StandardSiteImageBlob`), and this
/// runner must not become the first exception.
public struct SEOAuditRunner: AuditRunner {
    /// ``AuditRunner`` conformance — these findings file under the report's SEO section.
    public let category: AuditReport.Finding.Category = .seo

    /// Search results and share-preview cards truncate descriptions past roughly this length;
    /// flagged as `.info` since a long description still works, it just reads clipped.
    private static let maxDescriptionLength = 160

    /// Nothing to configure — the runner is stateless (see the type doc).
    public init() {}

    /// Walks `siteDirectory/dist` for `.html` pages (skipping `404.html`, which legitimately has
    /// no canonical URL) and emits findings in sorted route order, so a re-audit produces a
    /// stable list. Throws ``Error/distMissing`` when `dist/` doesn't exist — `AuditCommand`
    /// records that as a skipped runner rather than failing the whole audit.
    public func run(
        siteDirectory: URL,
        executor: any AuditExecutor,
        logCenter: LogCenter,
        source: String
    ) async throws -> [AuditReport.Finding] {
        let distDirectory = siteDirectory.appendingPathComponent("dist")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: distDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw Error.distMissing
        }

        return Self.htmlPages(in: distDirectory).flatMap(Self.findings(for:))
    }

    /// Why the runner produced nothing at all. Conforms to `CustomStringConvertible` because
    /// `AuditCommand` records a thrown runner error via `"\(error)"` interpolation, which must
    /// stay owner-facing (mirrors `A11yAuditRunner.Error`).
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// `dist/` doesn't exist (or isn't a directory) — there is nothing built to inspect.
        case distMissing

        public var description: String {
            switch self {
            case .distMissing:
                return "the SEO check couldn't find a built site to inspect — see the Debug pane for details."
            }
        }
    }

    // MARK: - Page discovery

    /// One built page: its file location and the route the finding's `location` should report.
    struct Page {
        let url: URL
        let route: String
    }

    /// Every `dist/**/*.html` file except `404.html`, sorted by route.
    static func htmlPages(in distDirectory: URL) -> [Page] {
        guard let enumerator = FileManager.default.enumerator(
            at: distDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var pages: [Page] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "html", url.lastPathComponent != "404.html" else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            let relativePath = Self.relativePath(of: url, in: distDirectory)
            pages.append(Page(url: url, route: Self.route(forRelativePath: relativePath)))
        }
        return pages.sorted { $0.route < $1.route }
    }

    /// `url`'s path relative to `directory` (`dist/about/index.html` in `dist/` → `about/index.html`).
    ///
    /// Both sides are resolved through `resolvingSymlinksInPath()` before comparing: on macOS,
    /// `FileManager.default.temporaryDirectory` (what test fixtures pass as `directory`) returns
    /// an unresolved `/var/folders/...` path, while `FileManager.enumerator(at:)` (what produces
    /// `url`) yields the resolved `/private/var/folders/...` form — a bare string-prefix
    /// comparison silently fails for every file and this falls back to `lastPathComponent`,
    /// collapsing every page's route to the same value.
    static func relativePath(of url: URL, in directory: URL) -> String {
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let directoryPath = resolvedDirectory.path.hasSuffix("/") ? resolvedDirectory.path : resolvedDirectory.path + "/"
        let filePath = url.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(directoryPath) else { return url.lastPathComponent }
        return String(filePath.dropFirst(directoryPath.count))
    }

    /// `index.html` → `/`, `about/index.html` → `/about/`, a non-index file `foo.html` → `/foo`.
    static func route(forRelativePath relativePath: String) -> String {
        if relativePath == "index.html" {
            return "/"
        }
        if relativePath.hasSuffix("/index.html") {
            return "/" + relativePath.dropLast("index.html".count)
        }
        if relativePath.hasSuffix(".html") {
            return "/" + relativePath.dropLast(".html".count)
        }
        return "/" + relativePath
    }

    // MARK: - Findings

    /// The findings for one page: at most one each for title, description, and canonical.
    static func findings(for page: Page) -> [AuditReport.Finding] {
        guard let html = try? String(contentsOf: page.url, encoding: .utf8) else {
            // A build artifact this runner can't read shouldn't fail the whole audit — treat it
            // as clean rather than throwing, since `AuditCommand`'s throw contract is per-runner,
            // not per-page.
            return []
        }

        var findings: [AuditReport.Finding] = []

        if LinkMetadataParser.parse(html: html).title == nil {
            findings.append(AuditReport.Finding(
                category: .seo,
                severity: .critical,
                title: "Missing page title",
                detail: "\(page.route) has no <title>.",
                remediation: "Add a title: field to this page's frontmatter.",
                location: page.route
            ))
        }

        if let description = Self.metaDescription(in: html) {
            if description.count > maxDescriptionLength {
                findings.append(AuditReport.Finding(
                    category: .seo,
                    severity: .info,
                    title: "Description is too long",
                    detail: "\(page.route)'s description is \(description.count) characters; search results and share previews truncate past \(maxDescriptionLength).",
                    remediation: "Shorten this page's description: field to \(maxDescriptionLength) characters or fewer.",
                    location: page.route
                ))
            }
        } else {
            findings.append(AuditReport.Finding(
                category: .seo,
                severity: .warning,
                title: "Missing meta description",
                detail: "\(page.route) has no <meta name=\"description\">.",
                remediation: "Add a description: field to this page's frontmatter.",
                location: page.route
            ))
        }

        if !Self.hasCanonicalLink(in: html) {
            findings.append(AuditReport.Finding(
                category: .seo,
                severity: .warning,
                title: "Missing canonical link",
                detail: "\(page.route) has no <link rel=\"canonical\">.",
                remediation: "Verify this page's canonical URL is configured correctly.",
                location: page.route
            ))
        }

        return findings
    }

    /// The trimmed `content` of `<meta name="description">`, or nil when the tag is absent, has
    /// no `content`, or its content is empty after trimming.
    static func metaDescription(in html: String) -> String? {
        for attrs in HTMLLinkAttributeScanning.metaAttributeStrings(in: html) {
            guard let name = HTMLLinkAttributeScanning.attributeValue("name", in: attrs),
                  name.caseInsensitiveCompare("description") == .orderedSame,
                  let content = HTMLLinkAttributeScanning.attributeValue("content", in: attrs)
            else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Whether the document has a `<link rel="canonical">` with a non-empty `href`.
    static func hasCanonicalLink(in html: String) -> Bool {
        HTMLLinkAttributeScanning.tagAttributeStrings(in: html).contains { attrs in
            guard let rel = HTMLLinkAttributeScanning.attributeValue("rel", in: attrs),
                  rel.caseInsensitiveCompare("canonical") == .orderedSame,
                  let href = HTMLLinkAttributeScanning.attributeValue("href", in: attrs)
            else { return false }
            return !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
