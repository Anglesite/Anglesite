import Foundation

/// `AuditRunner` for dangling internal references in the built site (#1996) — the first
/// occupant of the report's `.seo` category. Runs the template's `scripts/broken-links.ts` with
/// `--json` through the shared `AuditExecutor` (container-routed when a container is live,
/// explicitly unavailable on the host — the build's `dist/` only ever exists in the guest's
/// working copy) and parses its structured output into `[AuditReport.Finding]`, exactly as
/// `A11yAuditRunner` does for `a11y-audit.ts`.
///
/// Findings are grouped by dead *target*, not by referencing page: a navigation link that's
/// broken in a layout is broken on every page, and one finding that says "linked from 40 pages"
/// points at one fix, whereas 40 identical findings would bury everything else in the sheet.
public struct BrokenLinkAuditRunner: AuditRunner {
    /// ``AuditRunner`` conformance — dangling links are a search/discoverability defect, so they
    /// file under SEO alongside the metadata checks that category is reserved for.
    public let category: AuditReport.Finding.Category = .seo

    /// Nothing to configure — the runner is stateless by design; everything it needs arrives
    /// per-call in `run(...)`.
    public init() {}

    /// Runs the script through `executor`, parses its `--json` stdout, and groups the problems
    /// into findings. `logCenter`/`source` receive one summary line per run on top of the
    /// script's own streamed output, so the debug pane records what was and wasn't checked.
    ///
    /// Exit codes 0 (clean) and 1 (problems found) both mean "the script ran". Exit code 2 is
    /// the script's own "couldn't scan" (no `dist/`), and a nil exit code is a pre-spawn refusal;
    /// both throw so `AuditCommand` records a skipped runner rather than a clean result.
    ///
    /// - Throws: ``Error`` when the script didn't run, produced no JSON, or used a vocabulary
    ///   this runner doesn't recognize.
    public func run(
        siteDirectory: URL,
        executor: any AuditExecutor,
        logCenter: LogCenter,
        source: String
    ) async throws -> [AuditReport.Finding] {
        let result = await executor.run(step: .brokenLinks, siteDirectory: siteDirectory, source: source)
        guard let exitCode = result.exitCode, [0, 1].contains(exitCode) else {
            throw Error.scriptFailed(exitCode: result.exitCode, output: result.output)
        }
        guard let jsonStart = result.output.firstIndex(of: "{") else {
            throw Error.noJSONInOutput
        }
        let report = try Self.parse(json: Data(result.output[jsonStart...].utf8))

        let externalNote = report.externalReferencesSkipped > 0
            ? "; \(report.externalReferencesSkipped) off-site link\(report.externalReferencesSkipped == 1 ? "" : "s") not checked"
            : ""
        await logCenter.append(
            source: source,
            stream: .stdout,
            text: "broken-link check: \(report.pagesScanned) page\(report.pagesScanned == 1 ? "" : "s"), "
                + "\(report.referencesChecked) internal reference\(report.referencesChecked == 1 ? "" : "s"), "
                + "\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s")\(externalNote)")

        // `src/` is on the host (the guest's clone came from it), so the route → source-file map
        // is built here rather than in the script.
        return Self.findings(from: report, sourceFilesByRoute: Self.sourceFilesByRoute(in: siteDirectory))
    }

    /// Why a run produced no findings at all. Conforms to `CustomStringConvertible` because
    /// `AuditCommand` records a thrown runner error via `"\(error)"` interpolation, and that text
    /// is rendered verbatim in the audit sheet — so it must stay owner-facing, never an enum dump.
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The script exited with an unexpected code (its own `2` = "no built pages"), or never
        /// spawned at all (`exitCode` nil). `output` carries whatever it printed, which is
        /// usually already an owner-facing message.
        case scriptFailed(exitCode: Int32?, output: String)
        /// The script ran (accepted exit code) but its stdout contained no JSON object.
        case noJSONInOutput
        /// The report used a problem kind outside `"missing-target"` / `"missing-anchor"`.
        /// Thrown rather than guessed at, so a vocabulary change in `broken-links.ts` fails
        /// loudly instead of silently miscategorizing findings.
        case unknownProblemKind(String)

        /// Owner-facing text — see the enum doc.
        public var description: String {
            switch self {
            case .scriptFailed(let exitCode, let output):
                if !output.isEmpty { return output }
                return "the broken-link check exited unexpectedly (code \(exitCode?.description ?? "unknown"))"
            case .noJSONInOutput:
                return "the broken-link check didn't produce a report — see the Debug pane for details."
            case .unknownProblemKind(let raw):
                return "the broken-link check reported an unrecognized problem kind (\"\(raw)\")."
            }
        }
    }

    // MARK: - Wire format

    /// `scripts/broken-links.ts --json` output. Mirrors the script's `BrokenLinkReport`.
    public struct Report: Sendable, Equatable {
        /// HTML pages found and scanned.
        public let pagesScanned: Int
        /// Internal references resolved against `dist/` (after dedup within a page).
        public let referencesChecked: Int
        /// Off-site `http(s)` references seen and deliberately not checked — reported so the
        /// summary can say "N links weren't verified" rather than implying they were (#2001).
        public let externalReferencesSkipped: Int
        /// The distinct off-site URLs behind ``externalReferencesSkipped`` (#2026), first-seen
        /// order, fragment stripped. The script caps it at 500 while the count stays exact, so
        /// this can be shorter than the count implies. Empty when a site's template copy predates
        /// the field. For the opt-in external verification (#2001) to probe.
        public let externalReferences: [String]
        /// See ``Problem``; already sorted by page, then resolved path, by the script.
        public let problems: [Problem]

        /// Memberwise; public so tests can build reports without going through JSON.
        public init(
            pagesScanned: Int,
            referencesChecked: Int,
            externalReferencesSkipped: Int,
            externalReferences: [String] = [],
            problems: [Problem]
        ) {
            self.pagesScanned = pagesScanned
            self.referencesChecked = referencesChecked
            self.externalReferencesSkipped = externalReferencesSkipped
            self.externalReferences = externalReferences
            self.problems = problems
        }
    }

    /// One reference that didn't resolve — the script dedupes per `(kind, page, resolvedPath)`.
    public struct Problem: Sendable, Equatable {
        /// What went wrong; raw values are the script's wire vocabulary.
        public enum Kind: String, Sendable, Equatable {
            /// No file in `dist/` serves the path, and no redirect or runtime route covers it.
            case missingTarget = "missing-target"
            /// The page exists but has no element with the referenced `#fragment` id.
            case missingAnchor = "missing-anchor"
        }

        /// See ``Kind``.
        public let kind: Kind
        /// Route of the page (or CSS file) holding the reference, e.g. `/blog/hello/` — the
        /// same shape `A11yAuditRunner` reports, so both categories read alike in the sheet.
        public let page: String
        /// The reference exactly as written in the markup, so the owner can search for it.
        public let reference: String
        /// The site-absolute path it resolved to (fragment included for ``Kind/missingAnchor``).
        public let resolvedPath: String

        /// Memberwise; public so tests can build problems directly.
        public init(kind: Kind, page: String, reference: String, resolvedPath: String) {
            self.kind = kind
            self.page = page
            self.reference = reference
            self.resolvedPath = resolvedPath
        }
    }

    /// The script's JSON as decoded, before `kind` is validated — `kind` stays a `String` here so
    /// an unknown value throws ``Error/unknownProblemKind(_:)`` naming it, rather than the
    /// decoder's platform-specific "data corrupted" wording.
    private struct WireReport: Decodable {
        struct WireProblem: Decodable {
            let kind: String
            let page: String
            let reference: String
            let resolvedPath: String
        }
        let pagesScanned: Int
        let referencesChecked: Int
        let externalReferencesSkipped: Int
        /// Optional so a report from a template copy that predates #2026 still decodes.
        let externalReferences: [String]?
        let problems: [WireProblem]
    }

    /// Parses a `broken-links.ts --json` report. Exposed for tests.
    ///
    /// - Throws: ``Error/unknownProblemKind(_:)`` for an unrecognized `kind`, or the decoder's
    ///   own error for malformed JSON.
    public static func parse(json data: Data) throws -> Report {
        let wire = try JSONDecoder().decode(WireReport.self, from: data)
        let problems = try wire.problems.map { problem in
            guard let kind = Problem.Kind(rawValue: problem.kind) else {
                throw Error.unknownProblemKind(problem.kind)
            }
            return Problem(kind: kind, page: problem.page, reference: problem.reference, resolvedPath: problem.resolvedPath)
        }
        return Report(
            pagesScanned: wire.pagesScanned,
            referencesChecked: wire.referencesChecked,
            externalReferencesSkipped: wire.externalReferencesSkipped,
            externalReferences: wire.externalReferences ?? [],
            problems: problems)
    }

    // MARK: - Findings

    /// Groups `report.problems` by `(kind, resolvedPath)` and emits one finding per group, in
    /// the report's order. Pure and static so tests can exercise the wording without a script.
    ///
    /// - Parameters:
    ///   - report: The parsed report.
    ///   - sourceFilesByRoute: Normalized page route → `Source/`-relative file, from
    ///     ``sourceFilesByRoute(in:)``. Used only to sharpen the remediation when a single
    ///     referencing page maps back to one source file.
    /// - Returns: One finding per distinct dead target.
    static func findings(
        from report: Report,
        sourceFilesByRoute: [String: String]
    ) -> [AuditReport.Finding] {
        struct GroupKey: Hashable { let kind: Problem.Kind; let path: String }
        var order: [GroupKey] = []
        var groups: [GroupKey: [Problem]] = [:]
        for problem in report.problems {
            let key = GroupKey(kind: problem.kind, path: problem.resolvedPath)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(problem)
        }

        return order.map { key in
            let problems = groups[key] ?? []
            var pages: [String] = []
            for problem in problems where !pages.contains(problem.page) { pages.append(problem.page) }
            let reference = problems.first?.reference ?? key.path

            let linkedFrom: String
            switch pages.count {
            case 1: linkedFrom = "Linked from \(pages[0])."
            case 2: linkedFrom = "Linked from \(pages[0]) and \(pages[1])."
            case 3: linkedFrom = "Linked from \(pages[0]), \(pages[1]) and \(pages[2])."
            default: linkedFrom = "Linked from \(pages[0]), \(pages[1]) and \(pages.count - 2) more pages."
            }

            let sourceFile = pages.count == 1 ? sourceFilesByRoute[normalizedRoute(pages[0])] : nil
            let location = pages.count == 1 ? pages[0] : "\(pages.count) pages"
            switch key.kind {
            case .missingTarget:
                return AuditReport.Finding(
                    category: .seo,
                    severity: .critical,
                    title: "Broken link",
                    detail: "“\(key.path)” isn’t in the built site, so visitors who follow it get a “not found” page. \(linkedFrom)",
                    remediation: sourceFile.map { "Fix or remove the link to “\(reference)” in \($0)." }
                        ?? "Fix or remove the link to “\(reference)”, or add a redirect for \(key.path) in Site Settings → Redirects if the page moved.",
                    location: location)
            case .missingAnchor:
                let fragment = key.path.split(separator: "#", maxSplits: 1).last.map(String.init) ?? key.path
                return AuditReport.Finding(
                    category: .seo,
                    severity: .warning,
                    title: "Link to a missing section",
                    detail: "“\(key.path)” points at a section (#\(fragment)) that isn’t on that page, so the browser lands at the top instead. \(linkedFrom)",
                    remediation: sourceFile.map { "Update the “\(reference)” link in \($0) to an existing heading, or drop the #\(fragment) part." }
                        ?? "Update the “\(reference)” link to an existing heading on that page, or drop the #\(fragment) part.",
                    location: location)
            }
        }
    }

    // MARK: - Source mapping

    /// Best-effort map from a normalized page route to the `Source/`-relative file that produces
    /// it, over `src/pages/**` and `src/content/**`, via `SiteContentChunker.route(forRelativePath:)`.
    /// Collection routes don't always match the template's URL scheme, and layouts never appear
    /// here at all — a miss just means the finding gets the generic remediation.
    static func sourceFilesByRoute(in siteDirectory: URL) -> [String: String] {
        let extensions: Set<String> = ["astro", "md", "mdx", "mdoc", "markdown"]
        var map: [String: String] = [:]
        for subtree in ["src/pages", "src/content"] {
            let root = siteDirectory.appendingPathComponent(subtree)
            for file in regularFiles(under: root).sorted() {
                guard extensions.contains((file as NSString).pathExtension.lowercased()) else { continue }
                let relative = subtree + "/" + file
                let route = normalizedRoute(SiteContentChunker.route(forRelativePath: relative))
                if map[route] == nil { map[route] = relative }
            }
        }
        return map
    }

    /// `/blog/x/` and `/blog/x` compare equal; `/` stays `/`.
    static func normalizedRoute(_ route: String) -> String {
        guard route.count > 1, route.hasSuffix("/") else { return route }
        return String(route.dropLast())
    }

    /// Every regular file under `root`, as `/`-joined paths relative to it (unsorted).
    private static func regularFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            files.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return files
    }
}
