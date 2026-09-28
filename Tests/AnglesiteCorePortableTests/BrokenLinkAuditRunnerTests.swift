// Lives in the portable target on purpose: the runner is pure Foundation, and this is the only
// test target the Linux CI leg executes (AnglesiteCoreTests isn't purity-swept — see
// Package.swift). Runs on macOS too, where it is plain coverage. The scan engine itself is
// `scripts/broken-links.ts`, covered by `scripts/broken-links.test.ts` in the template's suite.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("BrokenLinkAuditRunner (#1996)")
struct BrokenLinkAuditRunnerTests {

    /// Serves one canned step result, recording which step was asked for.
    private actor StepRecorder {
        var steps: [AuditStep] = []
        func record(_ step: AuditStep) { steps.append(step) }
    }

    private struct CannedExecutor: AuditExecutor {
        let result: AuditStepResult
        let recorder: StepRecorder
        func run(step: AuditStep, siteDirectory: URL, source: String) async -> AuditStepResult {
            await recorder.record(step)
            return result
        }
    }

    /// A throwaway `Source/` populated from `files` (relative path → contents).
    private static func site(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokenLinkAuditRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func run(
        exitCode: Int32?,
        output: String,
        files: [String: String] = [:],
        logCenter: LogCenter = LogCenter()
    ) async throws -> (findings: [AuditReport.Finding], steps: [AuditStep]) {
        let root = try site(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = StepRecorder()
        let executor = CannedExecutor(result: .init(exitCode: exitCode, output: output), recorder: recorder)
        let findings = try await BrokenLinkAuditRunner().run(
            siteDirectory: root, executor: executor, logCenter: logCenter, source: "test")
        return (findings, await recorder.steps)
    }

    private static func json(_ problems: [String], pages: Int = 2, refs: Int = 3, external: Int = 0) -> String {
        """
        {"version":1,"pagesScanned":\(pages),"referencesChecked":\(refs),"externalReferencesSkipped":\(external),
         "problems":[\(problems.joined(separator: ","))]}
        """
    }

    // MARK: - Running the script

    @Test("asks the executor for the broken-links step and treats a clean exit 0 as no findings")
    func cleanRun() async throws {
        let logCenter = LogCenter()
        let (findings, steps) = try await Self.run(exitCode: 0, output: Self.json([], pages: 2, refs: 1), logCenter: logCenter)
        #expect(findings.isEmpty)
        #expect(steps == [.brokenLinks])
        let lines = await logCenter.snapshot().filter { $0.source == "test" }.map(\.text)
        #expect(lines == ["broken-link check: 2 pages, 1 internal reference, 0 problems"])
    }

    @Test("exit 1 (problems found) still counts as a completed run, and the log notes unchecked off-site links")
    func problemsRun() async throws {
        let logCenter = LogCenter()
        let (findings, _) = try await Self.run(
            exitCode: 1,
            output: Self.json([#"{"kind":"missing-target","page":"/","reference":"/gone/","resolvedPath":"/gone/"}"#], external: 5),
            logCenter: logCenter)
        #expect(findings.count == 1)
        let lines = await logCenter.snapshot().filter { $0.source == "test" }.map(\.text)
        #expect(lines == ["broken-link check: 2 pages, 3 internal references, 1 problem; 5 off-site links not checked"])
    }

    @Test("exit 2 (the script's own 'no built pages') throws so AuditCommand records a skip")
    func noBuiltPagesThrows() async throws {
        await #expect(throws: BrokenLinkAuditRunner.Error.scriptFailed(exitCode: 2, output: "dist/ not found")) {
            try await Self.run(exitCode: 2, output: "dist/ not found")
        }
    }

    @Test("a nil exit code (pre-spawn refusal) throws with the refusal reason as the owner-facing text")
    func refusalThrows() async throws {
        let refusal = "Container isn't running — open/start the site's preview first."
        await #expect(throws: BrokenLinkAuditRunner.Error.scriptFailed(exitCode: nil, output: refusal)) {
            try await Self.run(exitCode: nil, output: refusal)
        }
        #expect("\(BrokenLinkAuditRunner.Error.scriptFailed(exitCode: nil, output: refusal))" == refusal)
        #expect("\(BrokenLinkAuditRunner.Error.scriptFailed(exitCode: 2, output: ""))".contains("code 2"))
    }

    @Test("output with no JSON object throws noJSONInOutput")
    func noJSONThrows() async throws {
        await #expect(throws: BrokenLinkAuditRunner.Error.noJSONInOutput) {
            try await Self.run(exitCode: 0, output: "nothing to see here")
        }
    }

    @Test("leading non-JSON output (npm banners, warnings) before the object is skipped")
    func leadingNoiseSkipped() async throws {
        let (findings, _) = try await Self.run(exitCode: 0, output: "> site@1.0.0 links\n> npx tsx scripts/broken-links.ts --json\n\n" + Self.json([]))
        #expect(findings.isEmpty)
    }

    // MARK: - Parsing

    @Test("parse decodes the wire report, including both problem kinds")
    func parseReport() throws {
        let report = try BrokenLinkAuditRunner.parse(json: Data(Self.json([
            #"{"kind":"missing-target","page":"/a/","reference":"/x","resolvedPath":"/x"}"#,
            ##"{"kind":"missing-anchor","page":"/b/","reference":"#s","resolvedPath":"/b/#s"}"##,
        ], pages: 7, refs: 9, external: 2).utf8))
        #expect(report == .init(pagesScanned: 7, referencesChecked: 9, externalReferencesSkipped: 2, problems: [
            .init(kind: .missingTarget, page: "/a/", reference: "/x", resolvedPath: "/x"),
            .init(kind: .missingAnchor, page: "/b/", reference: "#s", resolvedPath: "/b/#s"),
        ]))
    }

    @Test("parse carries the distinct off-site URLs alongside the occurrence count (#2026)")
    func parseExternalReferences() throws {
        let raw = """
        {"version":1,"pagesScanned":1,"referencesChecked":0,"externalReferencesSkipped":3,
         "externalReferences":["https://a.example/x","https://b.example/"],"problems":[]}
        """
        let report = try BrokenLinkAuditRunner.parse(json: Data(raw.utf8))
        #expect(report.externalReferencesSkipped == 3)
        #expect(report.externalReferences == ["https://a.example/x", "https://b.example/"])
    }

    @Test("a report without externalReferences (an older template copy) parses to an empty list")
    func missingExternalReferencesKey() throws {
        let report = try BrokenLinkAuditRunner.parse(json: Data(Self.json([], external: 4).utf8))
        #expect(report.externalReferencesSkipped == 4)
        #expect(report.externalReferences == [])
    }

    @Test("an unknown problem kind throws rather than being guessed at")
    func unknownKindThrows() {
        let raw = Self.json([#"{"kind":"missing-planet","page":"/","reference":"/x","resolvedPath":"/x"}"#])
        #expect(throws: BrokenLinkAuditRunner.Error.unknownProblemKind("missing-planet")) {
            try BrokenLinkAuditRunner.parse(json: Data(raw.utf8))
        }
    }

    @Test("malformed JSON throws a decoding error")
    func malformedThrows() {
        #expect(throws: (any Error).self) {
            try BrokenLinkAuditRunner.parse(json: Data("{ not json".utf8))
        }
    }

    // MARK: - Findings

    @Test("a dead link becomes one critical SEO finding pointing at its source file")
    func deadLinkFinding() async throws {
        let (findings, _) = try await Self.run(
            exitCode: 1,
            output: Self.json([#"{"kind":"missing-target","page":"/","reference":"/gone/","resolvedPath":"/gone/"}"#]),
            files: ["src/pages/index.astro": "---\n---\n<a href=\"/gone/\">g</a>"])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.category == .seo)
        #expect(finding.severity == .critical)
        #expect(finding.title == "Broken link")
        #expect(finding.location == "/")
        #expect(finding.detail.contains("“/gone/”"))
        #expect(finding.remediation == "Fix or remove the link to “/gone/” in src/pages/index.astro.")
    }

    @Test("a collection entry's route maps back to its content file")
    func collectionRouteMapsToContentFile() async throws {
        let (findings, _) = try await Self.run(
            exitCode: 1,
            output: Self.json([#"{"kind":"missing-target","page":"/albums/hello-album/","reference":"/images/one.jpg","resolvedPath":"/images/one.jpg"}"#]),
            files: ["src/content/albums/hello-album.md": "---\ntitle: x\n---"])
        #expect(findings[0].remediation == "Fix or remove the link to “/images/one.jpg” in src/content/albums/hello-album.md.")
    }

    @Test("the same dead target across many pages is one finding that names the count")
    func groupedByTarget() throws {
        let problems = ["/a/", "/b/", "/c/", "/d/"].map {
            BrokenLinkAuditRunner.Problem(kind: .missingTarget, page: $0, reference: "/nav-gone/", resolvedPath: "/nav-gone/")
        }
        let report = BrokenLinkAuditRunner.Report(pagesScanned: 5, referencesChecked: 4, externalReferencesSkipped: 0, problems: problems)
        let findings = BrokenLinkAuditRunner.findings(from: report, sourceFilesByRoute: [:])
        #expect(findings.count == 1)
        #expect(findings[0].location == "4 pages")
        #expect(findings[0].detail.hasSuffix("Linked from /a/, /b/ and 2 more pages."))
        #expect(findings[0].remediation?.contains("Site Settings → Redirects") == true)
    }

    @Test("two and three referencing pages are listed in full")
    func smallGroupsListed() {
        let make = { (pages: [String]) -> AuditReport.Finding in
            let problems = pages.map { BrokenLinkAuditRunner.Problem(kind: .missingTarget, page: $0, reference: "/x", resolvedPath: "/x") }
            let report = BrokenLinkAuditRunner.Report(pagesScanned: 3, referencesChecked: 3, externalReferencesSkipped: 0, problems: problems)
            return BrokenLinkAuditRunner.findings(from: report, sourceFilesByRoute: [:])[0]
        }
        #expect(make(["/a/", "/b/"]).detail.hasSuffix("Linked from /a/ and /b/."))
        #expect(make(["/a/", "/b/", "/c/"]).detail.hasSuffix("Linked from /a/, /b/ and /c/."))
        #expect(make(["/a/", "/b/"]).location == "2 pages")
    }

    @Test("a missing anchor is a warning, not a critical finding, and names the fragment")
    func missingAnchorIsWarning() {
        let report = BrokenLinkAuditRunner.Report(pagesScanned: 2, referencesChecked: 1, externalReferencesSkipped: 0, problems: [
            .init(kind: .missingAnchor, page: "/", reference: "/about/#nope", resolvedPath: "/about/#nope"),
        ])
        let findings = BrokenLinkAuditRunner.findings(from: report, sourceFilesByRoute: ["/": "src/pages/index.astro"])
        #expect(findings.map(\.severity) == [.warning])
        #expect(findings[0].title == "Link to a missing section")
        #expect(findings[0].detail.contains("(#nope)"))
        #expect(findings[0].remediation == "Update the “/about/#nope” link in src/pages/index.astro to an existing heading, or drop the #nope part.")
    }

    @Test("findings keep a stable identity across runs so the sheet updates rows in place")
    func stableIdentity() {
        let report = BrokenLinkAuditRunner.Report(pagesScanned: 1, referencesChecked: 1, externalReferencesSkipped: 0, problems: [
            .init(kind: .missingTarget, page: "/", reference: "/x", resolvedPath: "/x"),
        ])
        let a = BrokenLinkAuditRunner.findings(from: report, sourceFilesByRoute: [:])[0]
        let b = BrokenLinkAuditRunner.findings(from: report, sourceFilesByRoute: [:])[0]
        #expect(a.id == b.id)
    }

    // MARK: - Source mapping

    @Test("sourceFilesByRoute maps pages and content entries, ignoring non-content files")
    func sourceMapping() throws {
        let root = try Self.site([
            "src/pages/index.astro": "",
            "src/pages/about/index.astro": "",
            "src/pages/rss.xml.ts": "",
            "src/content/posts/hello.mdoc": "",
            "src/content/config.ts": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let map = BrokenLinkAuditRunner.sourceFilesByRoute(in: root)
        #expect(map["/"] == "src/pages/index.astro")
        #expect(map["/about"] == "src/pages/about/index.astro")
        #expect(map["/posts/hello"] == "src/content/posts/hello.mdoc")
        #expect(map.values.contains("src/pages/rss.xml.ts") == false)
        #expect(map.values.contains("src/content/config.ts") == false)
        #expect(BrokenLinkAuditRunner.normalizedRoute("/blog/x/") == "/blog/x")
        #expect(BrokenLinkAuditRunner.normalizedRoute("/") == "/")
    }
}
