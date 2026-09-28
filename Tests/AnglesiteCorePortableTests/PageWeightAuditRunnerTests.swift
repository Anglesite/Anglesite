// Portable target for the same reason as `BrokenLinkAuditRunnerTests`: the runner is pure
// Foundation, and this is the test target the Linux CI leg executes. The scan engine itself is
// `scripts/page-weight.ts`, covered by `scripts/page-weight.test.ts` in the template's suite.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("PageWeightAuditRunner (#2020)")
struct PageWeightAuditRunnerTests {

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

    private static func run(
        exitCode: Int32?,
        output: String,
        logCenter: LogCenter = LogCenter()
    ) async throws -> (findings: [AuditReport.Finding], steps: [AuditStep]) {
        let recorder = StepRecorder()
        let executor = CannedExecutor(result: .init(exitCode: exitCode, output: output), recorder: recorder)
        let findings = try await PageWeightAuditRunner().run(
            siteDirectory: URL(fileURLWithPath: "/site/Source"), executor: executor, logCenter: logCenter, source: "test")
        return (findings, await recorder.steps)
    }

    private static func json(_ problems: [String], pages: Int = 2, heaviest: Int = 40_960, external: Int = 0) -> String {
        """
        {"version":1,"pagesScanned":\(pages),"heaviestPageBytes":\(heaviest),"externalReferencesSkipped":\(external),
         "problems":[\(problems.joined(separator: ","))]}
        """
    }

    // MARK: - Running the script

    @Test("asks the executor for the page-weight step and treats a clean exit 0 as no findings")
    func cleanRun() async throws {
        let logCenter = LogCenter()
        let (findings, steps) = try await Self.run(exitCode: 0, output: Self.json([]), logCenter: logCenter)
        #expect(findings.isEmpty)
        #expect(steps == [.pageWeight])
        let lines = await logCenter.snapshot().filter { $0.source == "test" }.map(\.text)
        #expect(lines == ["page-weight check: 2 pages, heaviest 40 KB, 0 problems"])
    }

    @Test("exit 1 still counts as a completed run, and the log notes uncounted off-site references")
    func problemsRun() async throws {
        let logCenter = LogCenter()
        let (findings, _) = try await Self.run(
            exitCode: 1,
            output: "npm noise\n" + Self.json([#"{"kind":"heavy-page","page":"/","bytes":2097152}"#], pages: 1, heaviest: 2_097_152, external: 3),
            logCenter: logCenter)
        #expect(findings.count == 1)
        let lines = await logCenter.snapshot().filter { $0.source == "test" }.map(\.text)
        #expect(lines == ["page-weight check: 1 page, heaviest 2.0 MB, 1 problem; 3 off-site references not counted"])
    }

    @Test("exit 2 (no dist/) and a pre-spawn refusal both throw, so the runner is recorded as skipped",
          arguments: [Int32?.some(2), nil])
    func failedRunThrows(exitCode: Int32?) async {
        await #expect(throws: PageWeightAuditRunner.Error.scriptFailed(exitCode: exitCode, output: "no dist")) {
            _ = try await Self.run(exitCode: exitCode, output: "no dist")
        }
    }

    @Test("output without JSON throws")
    func noJSON() async {
        await #expect(throws: PageWeightAuditRunner.Error.noJSONInOutput) {
            _ = try await Self.run(exitCode: 0, output: "nothing to see")
        }
    }

    @Test("an unknown problem kind throws, naming it")
    func unknownKind() async {
        await #expect(throws: PageWeightAuditRunner.Error.unknownProblemKind("slow-font")) {
            _ = try await Self.run(exitCode: 1, output: Self.json([#"{"kind":"slow-font","page":"/"}"#]))
        }
    }

    // MARK: - Findings

    @Test("each kind maps to its severity, all under .performance")
    func severityMapping() async throws {
        let (findings, _) = try await Self.run(exitCode: 1, output: Self.json([
            #"{"kind":"heavy-page","page":"/a/","bytes":1800000}"#,
            #"{"kind":"img-missing-dimensions","page":"/a/","count":2,"examples":["/x.png","/y.png"]}"#,
            #"{"kind":"very-heavy-page","page":"/b/","bytes":5000000}"#,
            #"{"kind":"non-web-image-format","asset":"/photo.heic","bytes":10,"pages":["/"]}"#,
            #"{"kind":"oversized-image","asset":"/hero.jpg","bytes":819200,"pages":["/","/a/"]}"#,
        ]))
        #expect(findings.map(\.severity) == [.warning, .info, .critical, .critical, .warning])
        #expect(findings.allSatisfy { $0.category == .performance })
        #expect(findings.map(\.location) == ["/a/", "/a/", "/b/", "/photo.heic", "/hero.jpg"])
    }

    @Test("an oversized image is one finding naming its size and the pages using it")
    func oversizedImageWording() throws {
        let report = PageWeightAuditRunner.Report(
            pagesScanned: 5, heaviestPageBytes: 0, externalReferencesSkipped: 0,
            problems: [.init(kind: .oversizedImage, asset: "/hero.jpg", bytes: 819_200, pages: ["/", "/a/", "/b/", "/c/"])])
        let finding = try #require(PageWeightAuditRunner.findings(from: report).first)
        #expect(finding.title == "Image is larger than it needs to be")
        #expect(finding.detail == "“/hero.jpg” is 800 KB. Used on /, /a/ and 2 more pages.")
    }

    @Test("a non-web format names the format, and an unreferenced file says it still ships")
    func nonWebFormatWording() throws {
        let report = PageWeightAuditRunner.Report(
            pagesScanned: 1, heaviestPageBytes: 0, externalReferencesSkipped: 0,
            problems: [.init(kind: .nonWebImageFormat, asset: "/scan.tiff", bytes: 10, pages: [])])
        let finding = try #require(PageWeightAuditRunner.findings(from: report).first)
        #expect(finding.detail.hasPrefix("“/scan.tiff” is a TIFF file"))
        #expect(finding.detail.hasSuffix("No page uses it, but it’s still published with the site."))
    }

    @Test("missing dimensions reports the count and examples for the page")
    func missingDimensionsWording() throws {
        let report = PageWeightAuditRunner.Report(
            pagesScanned: 1, heaviestPageBytes: 0, externalReferencesSkipped: 0,
            problems: [.init(kind: .imgMissingDimensions, page: "/", count: 1, examples: ["/x.png"])])
        let finding = try #require(PageWeightAuditRunner.findings(from: report).first)
        #expect(finding.detail == "1 image on / has no width or height, so the text shifts as it arrives, e.g. “/x.png”.")
    }

    @Test("formatBytes matches the script: binary KB below a megabyte, one decimal of MB above",
          arguments: [(0, "0 KB"), (512 * 1024, "512 KB"), (1_048_576, "1.0 MB"), (1_572_864, "1.5 MB"), (5_000_000, "4.8 MB")])
    func formatBytes(bytes: Int, expected: String) {
        #expect(PageWeightAuditRunner.formatBytes(bytes) == expected)
    }

    @Test("the default runner set includes the page-weight runner")
    func registered() {
        #expect(AuditCommand.defaultRunners.contains { $0 is PageWeightAuditRunner })
    }
}
