import Foundation

/// `AuditRunner` for what a first-time visitor downloads (#2020) — the first occupant of the
/// report's `.performance` category. Runs the template's `scripts/page-weight.ts` with `--json`
/// through the shared `AuditExecutor` (container-routed when a container is live, explicitly
/// unavailable on the host — `dist/` only exists in the guest's working copy) and maps its
/// structured output into `[AuditReport.Finding]`, as `BrokenLinkAuditRunner` does for
/// `broken-links.ts`.
///
/// No Lighthouse, no headless browser, no network: the script measures on-disk bytes in `dist/`,
/// so the result is deterministic across runs and machines. Image findings arrive already grouped
/// by asset — one hero image used site-wide is one fix, not one row per page.
public struct PageWeightAuditRunner: AuditRunner {
    /// ``AuditRunner`` conformance.
    public let category: AuditReport.Finding.Category = .performance

    public init() {}

    /// Runs the script through `executor`, parses its `--json` stdout, and maps the problems into
    /// findings. One summary line per run goes to `logCenter`/`source` on top of the script's own
    /// streamed output.
    ///
    /// Exit codes 0 (clean) and 1 (problems found) both mean "the script ran". Exit code 2 is the
    /// script's own "couldn't scan" (no `dist/`), and a nil exit code is a pre-spawn refusal; both
    /// throw so `AuditCommand` records a skipped runner rather than a clean result.
    ///
    /// - Throws: ``Error`` when the script didn't run, produced no JSON, or used a vocabulary this
    ///   runner doesn't recognize.
    public func run(
        siteDirectory: URL,
        executor: any AuditExecutor,
        logCenter: LogCenter,
        source: String
    ) async throws -> [AuditReport.Finding] {
        let result = await executor.run(step: .pageWeight, siteDirectory: siteDirectory, source: source)
        guard let exitCode = result.exitCode, [0, 1].contains(exitCode) else {
            throw Error.scriptFailed(exitCode: result.exitCode, output: result.output)
        }
        guard let jsonStart = result.output.firstIndex(of: "{") else {
            throw Error.noJSONInOutput
        }
        let report = try Self.parse(json: Data(result.output[jsonStart...].utf8))

        let externalNote = report.externalReferencesSkipped > 0
            ? "; \(report.externalReferencesSkipped) off-site reference\(report.externalReferencesSkipped == 1 ? "" : "s") not counted"
            : ""
        await logCenter.append(
            source: source,
            stream: .stdout,
            text: "page-weight check: \(report.pagesScanned) page\(report.pagesScanned == 1 ? "" : "s"), "
                + "heaviest \(Self.formatBytes(report.heaviestPageBytes)), "
                + "\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s")\(externalNote)")

        return Self.findings(from: report)
    }

    /// Why a run produced no findings at all. Owner-facing `description` for the same reason as
    /// ``BrokenLinkAuditRunner/Error``: `AuditCommand` renders it verbatim in the audit sheet.
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The script exited with an unexpected code (its own `2` = "no built pages"), or never
        /// spawned at all (`exitCode` nil).
        case scriptFailed(exitCode: Int32?, output: String)
        /// The script ran (accepted exit code) but its stdout contained no JSON object.
        case noJSONInOutput
        /// The report used a problem kind this runner doesn't know — thrown rather than guessed
        /// at, so a vocabulary change in `page-weight.ts` fails loudly.
        case unknownProblemKind(String)

        /// Owner-facing text — see the enum doc.
        public var description: String {
            switch self {
            case .scriptFailed(let exitCode, let output):
                if !output.isEmpty { return output }
                return "the page-weight check exited unexpectedly (code \(exitCode?.description ?? "unknown"))"
            case .noJSONInOutput:
                return "the page-weight check didn’t produce a report — see the Debug pane for details."
            case .unknownProblemKind(let raw):
                return "the page-weight check reported an unrecognized problem kind (\"\(raw)\")."
            }
        }
    }

    // MARK: - Wire format

    /// `scripts/page-weight.ts --json` output. Mirrors the script's `PageWeightReport`.
    public struct Report: Sendable, Equatable {
        /// HTML pages found and weighed.
        public let pagesScanned: Int
        /// The heaviest page's total bytes.
        public let heaviestPageBytes: Int
        /// Off-site references seen and counted as 0 (never fetched).
        public let externalReferencesSkipped: Int
        /// See ``Problem``; already sorted by the script (pages first, then assets).
        public let problems: [Problem]

        /// Memberwise; public so tests can build reports without going through JSON.
        public init(pagesScanned: Int, heaviestPageBytes: Int, externalReferencesSkipped: Int, problems: [Problem]) {
            self.pagesScanned = pagesScanned
            self.heaviestPageBytes = heaviestPageBytes
            self.externalReferencesSkipped = externalReferencesSkipped
            self.problems = problems
        }
    }

    /// One problem. Page-level kinds carry `page`; asset-level kinds carry `asset` and `pages`.
    public struct Problem: Sendable, Equatable {
        /// What went wrong; raw values are the script's wire vocabulary.
        public enum Kind: String, Sendable, Equatable {
            /// The page's total download is over 1.5 MB.
            case heavyPage = "heavy-page"
            /// The page's total download is over 4 MB.
            case veryHeavyPage = "very-heavy-page"
            /// One image is over 500 KB.
            case oversizedImage = "oversized-image"
            /// A BMP, TIFF or HEIC/HEIF file ships in `dist/`.
            case nonWebImageFormat = "non-web-image-format"
            /// `<img>` elements on the page declare neither `width` nor `height`.
            case imgMissingDimensions = "img-missing-dimensions"
        }

        /// See ``Kind``.
        public let kind: Kind
        /// Route of the page, for page-level kinds.
        public let page: String?
        /// Site-absolute path of the asset, for asset-level kinds.
        public let asset: String?
        /// The page's total weight, or the asset's size.
        public let bytes: Int?
        /// Pages referencing the asset (possibly empty for an unreferenced file).
        public let pages: [String]
        /// How many images lack dimensions, for ``Kind/imgMissingDimensions``.
        public let count: Int?
        /// Up to three of their `src` values.
        public let examples: [String]

        /// Memberwise; public so tests can build problems directly.
        public init(
            kind: Kind, page: String? = nil, asset: String? = nil, bytes: Int? = nil,
            pages: [String] = [], count: Int? = nil, examples: [String] = []
        ) {
            self.kind = kind
            self.page = page
            self.asset = asset
            self.bytes = bytes
            self.pages = pages
            self.count = count
            self.examples = examples
        }
    }

    /// The script's JSON as decoded, `kind` still a `String` — see ``BrokenLinkAuditRunner``'s
    /// equivalent for why.
    private struct WireReport: Decodable {
        struct WireProblem: Decodable {
            let kind: String
            let page: String?
            let asset: String?
            let bytes: Int?
            let pages: [String]?
            let count: Int?
            let examples: [String]?
        }
        let pagesScanned: Int
        let heaviestPageBytes: Int
        let externalReferencesSkipped: Int
        let problems: [WireProblem]
    }

    /// Parses a `page-weight.ts --json` report. Exposed for tests.
    ///
    /// - Throws: ``Error/unknownProblemKind(_:)`` for an unrecognized `kind`, or the decoder's own
    ///   error for malformed JSON.
    public static func parse(json data: Data) throws -> Report {
        let wire = try JSONDecoder().decode(WireReport.self, from: data)
        let problems = try wire.problems.map { problem in
            guard let kind = Problem.Kind(rawValue: problem.kind) else {
                throw Error.unknownProblemKind(problem.kind)
            }
            return Problem(
                kind: kind, page: problem.page, asset: problem.asset, bytes: problem.bytes,
                pages: problem.pages ?? [], count: problem.count, examples: problem.examples ?? [])
        }
        return Report(
            pagesScanned: wire.pagesScanned,
            heaviestPageBytes: wire.heaviestPageBytes,
            externalReferencesSkipped: wire.externalReferencesSkipped,
            problems: problems)
    }

    // MARK: - Findings

    /// One finding per problem, in the report's order. Pure and static so tests can exercise the
    /// wording without a script.
    static func findings(from report: Report) -> [AuditReport.Finding] {
        report.problems.map { problem in
            let page = problem.page ?? "a page"
            let asset = problem.asset ?? "an image"
            let size = problem.bytes.map(formatBytes) ?? "an unknown size"
            switch problem.kind {
            case .veryHeavyPage:
                return AuditReport.Finding(
                    category: .performance,
                    severity: .critical,
                    title: "Page is very slow to load",
                    detail: "A first visit to \(page) downloads \(size) — more than 4 MB. On a phone connection that can take many seconds, and many visitors leave before it finishes.",
                    remediation: "Shrink or remove the largest images, videos and scripts on this page.",
                    location: page)
            case .heavyPage:
                return AuditReport.Finding(
                    category: .performance,
                    severity: .warning,
                    title: "Page is slow to load",
                    detail: "A first visit to \(page) downloads \(size) — more than 1.5 MB, which is slow on a phone connection.",
                    remediation: "Shrink the largest images on this page, or move some of them to their own pages.",
                    location: page)
            case .oversizedImage:
                return AuditReport.Finding(
                    category: .performance,
                    severity: .warning,
                    title: "Image is larger than it needs to be",
                    detail: "“\(asset)” is \(size). \(usedOn(problem.pages))",
                    remediation: "Resize it to the largest size it’s shown at and save it as WebP or JPEG — most photos look the same at a fraction of the size.",
                    location: asset)
            case .nonWebImageFormat:
                let format = (asset.split(separator: ".").last.map { $0.uppercased() }) ?? "this"
                return AuditReport.Finding(
                    category: .performance,
                    severity: .critical,
                    title: "Image in a format browsers can’t show",
                    detail: "“\(asset)” is a \(format) file, which most browsers won’t display, so visitors see a broken image. \(usedOn(problem.pages))",
                    remediation: "Convert it to JPEG, PNG or WebP and use the converted file instead.",
                    location: asset)
            case .imgMissingDimensions:
                let count = problem.count ?? problem.examples.count
                let examples = problem.examples.map { "“\($0)”" }.joined(separator: ", ")
                return AuditReport.Finding(
                    category: .performance,
                    severity: .info,
                    title: "Images without a size make the page jump while it loads",
                    detail: "\(count) image\(count == 1 ? "" : "s") on \(page) \(count == 1 ? "has" : "have") no width or height, so the text shifts as \(count == 1 ? "it arrives" : "they arrive")"
                        + (examples.isEmpty ? "." : ", e.g. \(examples)."),
                    remediation: "Give each image its width and height so the browser can save its space before it arrives.",
                    location: page)
            }
        }
    }

    /// "Used on /a/.", "Used on /a/ and /b/.", …, or the unreferenced case.
    private static func usedOn(_ pages: [String]) -> String {
        switch pages.count {
        case 0: return "No page uses it, but it’s still published with the site."
        case 1: return "Used on \(pages[0])."
        case 2: return "Used on \(pages[0]) and \(pages[1])."
        case 3: return "Used on \(pages[0]), \(pages[1]) and \(pages[2])."
        default: return "Used on \(pages[0]), \(pages[1]) and \(pages.count - 2) more pages."
        }
    }

    /// Binary KB/MB, matching the script's `formatBytes` so the sheet and the Debug pane agree.
    /// Hand-rolled rather than `ByteCountFormatter`, which is decimal and platform-dependent.
    static func formatBytes(_ bytes: Int) -> String {
        let kb = 1024.0, mb = 1024.0 * 1024.0
        let value = Double(bytes)
        if value >= mb {
            let tenths = (value / mb * 10).rounded() / 10
            return "\(String(format: "%.1f", tenths)) MB"
        }
        return "\(Int((value / kb).rounded())) KB"
    }
}
