import Foundation
import Testing
@testable import AnglesiteCore

/// Tests for `SEOAuditRunner` (#2004): title/description/canonical findings for the `.seo`
/// category. Fixtures are hand-written HTML under a temp `dist/` — no container, no network,
/// no `tsx`, matching the runner's "reads the filesystem directly" posture (see its doc comment).
@Suite("SEOAuditRunner (#2004)")
struct SEOAuditRunnerTests {
    private static func site(_ pages: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SEOAuditRunnerTests-\(UUID().uuidString)")
        let dist = root.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        for (relativePath, html) in pages {
            let fileURL = dist.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func run(_ pages: [String: String]) async throws -> [AuditReport.Finding] {
        let root = try site(pages)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await SEOAuditRunner().run(
            siteDirectory: root, executor: HostAuditExecutor(), logCenter: .shared, source: "test"
        )
    }

    private static let cleanPage = """
    <html><head>
      <title>About Acme</title>
      <meta name="description" content="A short, useful description of this page.">
      <link rel="canonical" href="https://example.com/about/">
    </head><body></body></html>
    """

    @Test("a site whose pages all carry a title, description, and canonical produces zero findings")
    func cleanSiteProducesNoFindings() async throws {
        let findings = try await Self.run(["index.html": Self.cleanPage, "about/index.html": Self.cleanPage])
        #expect(findings.isEmpty)
    }

    @Test("a page missing a title produces exactly one critical finding at its route")
    func missingTitleProducesCriticalFinding() async throws {
        let html = """
        <html><head>
          <meta name="description" content="A short, useful description of this page.">
          <link rel="canonical" href="https://example.com/">
        </head><body></body></html>
        """
        let findings = try await Self.run(["index.html": html])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .critical)
        #expect(findings[0].category == .seo)
        #expect(findings[0].location == "/")
    }

    @Test("an empty title is treated the same as a missing one")
    func emptyTitleProducesCriticalFinding() async throws {
        let html = """
        <html><head>
          <title></title>
          <meta name="description" content="A short, useful description of this page.">
          <link rel="canonical" href="https://example.com/">
        </head><body></body></html>
        """
        let findings = try await Self.run(["index.html": html])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .critical)
    }

    @Test("a page missing a meta description produces exactly one warning finding")
    func missingDescriptionProducesWarningFinding() async throws {
        let html = """
        <html><head>
          <title>About Acme</title>
          <link rel="canonical" href="https://example.com/">
        </head><body></body></html>
        """
        let findings = try await Self.run(["index.html": html])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .warning)
        #expect(findings[0].title.lowercased().contains("description"))
    }

    @Test("a page missing a canonical link produces exactly one warning finding")
    func missingCanonicalProducesWarningFinding() async throws {
        let html = """
        <html><head>
          <title>About Acme</title>
          <meta name="description" content="A short, useful description of this page.">
        </head><body></body></html>
        """
        let findings = try await Self.run(["index.html": html])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .warning)
        #expect(findings[0].title.lowercased().contains("canonical"))
    }

    @Test("a description over 160 characters produces an info finding and no warning")
    func longDescriptionProducesInfoFinding() async throws {
        let longDescription = String(repeating: "a", count: 161)
        let html = """
        <html><head>
          <title>About Acme</title>
          <meta name="description" content="\(longDescription)">
          <link rel="canonical" href="https://example.com/">
        </head><body></body></html>
        """
        let findings = try await Self.run(["index.html": html])
        #expect(findings.count == 1)
        #expect(findings[0].severity == .info)
        #expect(!findings.contains { $0.severity == .warning })
    }

    @Test("route derivation: dist/index.html is / and dist/about/index.html is /about/")
    func routeDerivationForIndexFiles() async throws {
        let broken = """
        <html><head></head><body></body></html>
        """
        let findings = try await Self.run(["index.html": broken, "about/index.html": broken])
        let locations = Set(findings.map(\.location))
        #expect(locations.contains("/"))
        #expect(locations.contains("/about/"))
    }

    @Test("dist/404.html is skipped entirely, even though it has no title/description/canonical")
    func skips404() async throws {
        let broken = "<html><head></head><body></body></html>"
        let findings = try await Self.run(["404.html": broken])
        #expect(findings.isEmpty)
    }

    @Test("a missing dist/ throws distMissing")
    func missingDistThrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SEOAuditRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: SEOAuditRunner.Error.self) {
            _ = try await SEOAuditRunner().run(
                siteDirectory: root, executor: HostAuditExecutor(), logCenter: .shared, source: "test"
            )
        }
    }

    @Test("a missing dist/ surfaces as a skipped runner through AuditCommand, while the rest of the audit still succeeds")
    func missingDistSurfacesAsSkippedRunnerThroughAuditCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SEOAuditRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let hostExecutor = HostAuditExecutor(
            supervisor: supervisor,
            logCenter: center,
            resolveCommand: { step in
                switch step {
                case .build: return { _ in .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
                case .a11y: return { _ in .unavailable(reason: "not used by this fixture") }
                }
            }
        )
        let cmd = AuditCommand(logCenter: center, executor: hostExecutor, runners: [SEOAuditRunner()])
        let result = await cmd.audit(siteID: "site", siteDirectory: root)
        guard case .succeeded(let report, _) = result else {
            Issue.record("expected .succeeded (a runner throwing isn't fatal), got \(result)")
            return
        }
        #expect(report.findings.isEmpty)
        #expect(report.runnersExecuted.isEmpty)
        #expect(report.runnersSkipped.count == 1)
        #expect(report.runnersSkipped.first?.category == .seo)
    }
}
