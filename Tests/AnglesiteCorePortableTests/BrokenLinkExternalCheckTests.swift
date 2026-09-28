// The opt-in off-site half of the broken-link audit (#2001): `BrokenLinkAuditRunner` probing the
// `externalReferences` the script reports (#2026) through `ExternalLinkProbing` (#2027). Portable
// target for the same reason as `BrokenLinkAuditRunnerTests`. No test touches the network — the
// probe is always a fake here.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("BrokenLinkAuditRunner off-site check (#2001)")
struct BrokenLinkExternalCheckTests {

    /// Answers from a fixed table (unlisted URLs are `.reachable`) and records what it was asked.
    private actor FakeProbe: ExternalLinkProbing {
        let answers: [URL: LinkReachability]
        private(set) var calls: [[URL]] = []
        init(_ answers: [URL: LinkReachability] = [:]) { self.answers = answers }
        func probe(_ urls: [URL]) async -> [URL: LinkReachability] {
            calls.append(urls)
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, answers[$0] ?? .reachable) })
        }
    }

    private struct CannedExecutor: AuditExecutor {
        let output: String
        func run(step: AuditStep, siteDirectory: URL, source: String) async -> AuditStepResult {
            .init(exitCode: 0, output: output)
        }
    }

    private static func json(external: [String]) -> String {
        let list = external.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"version":1,"pagesScanned":1,"referencesChecked":0,"externalReferencesSkipped":\(external.count),
         "externalReferences":[\(list)],"problems":[]}
        """
    }

    private static func run(
        external: [String],
        enabled: Bool,
        probe: FakeProbe,
        logCenter: LogCenter = LogCenter()
    ) async throws -> [AuditReport.Finding] {
        let site = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)/Source")
        let runner = BrokenLinkAuditRunner(externalLinks: .init(isEnabled: { _ in enabled }, probe: probe))
        return try await runner.run(
            siteDirectory: site, executor: CannedExecutor(output: json(external: external)),
            logCenter: logCenter, source: "test")
    }

    private let gone = URL(string: "https://gone.example/page")!
    private let challenged = URL(string: "https://walled.example/")!
    private let fine = URL(string: "https://fine.example/")!

    // MARK: - Opt-in gate

    @Test("off by default in effect: a disabled check never probes and adds nothing")
    func disabledNeverProbes() async throws {
        let probe = FakeProbe([gone: .unreachable])
        let findings = try await Self.run(external: [gone.absoluteString], enabled: false, probe: probe)
        #expect(findings.isEmpty)
        #expect(await probe.calls.isEmpty)
    }

    @Test("enabled with no off-site links never touches the probe")
    func enabledWithoutLinks() async throws {
        let probe = FakeProbe()
        let findings = try await Self.run(external: [], enabled: true, probe: probe)
        #expect(findings.isEmpty)
        #expect(await probe.calls.isEmpty)
    }

    @Test("enabled: every distinct reported URL is probed once, in one call")
    func enabledProbesReportedURLs() async throws {
        let probe = FakeProbe()
        _ = try await Self.run(external: [gone.absoluteString, fine.absoluteString], enabled: true, probe: probe)
        #expect(await probe.calls == [[gone, fine]])
    }

    // MARK: - Findings

    @Test("a gone link is a warning, an unsettled one is a single info note, a reachable one is nothing")
    func severityMapping() async throws {
        let probe = FakeProbe([gone: .unreachable, challenged: .indeterminate])
        let findings = try await Self.run(
            external: [gone.absoluteString, challenged.absoluteString, fine.absoluteString],
            enabled: true, probe: probe)
        #expect(findings.count == 2)
        let warning = try #require(findings.first { $0.severity == .warning })
        #expect(warning.category == .seo)
        #expect(warning.title == "Link to another site no longer works")
        #expect(warning.detail.contains(gone.absoluteString))
        #expect(warning.location == gone.absoluteString)
        let info = try #require(findings.first { $0.severity == .info })
        #expect(info.title == "Some links to other sites couldn’t be checked")
        #expect(info.detail.hasPrefix("1 link to another site"))
        #expect(!findings.contains { $0.severity == .critical })
    }

    @Test("unsettled links fold into one info finding however many there are")
    func unsettledFoldIntoOne() {
        let results = Dictionary(uniqueKeysWithValues: (0..<40).map {
            (URL(string: "https://walled\($0).example/")!, LinkReachability.indeterminate)
        })
        let findings = BrokenLinkAuditRunner.externalLinkFindings(from: results)
        #expect(findings.count == 1)
        #expect(findings[0].severity == .info)
        #expect(findings[0].detail.hasPrefix("40 links to other sites"))
    }

    @Test("gone links are sorted by URL so re-runs keep a stable order")
    func goneLinksSorted() {
        let results: [URL: LinkReachability] = [
            URL(string: "https://c.example/")!: .unreachable,
            URL(string: "https://a.example/")!: .unreachable,
            URL(string: "https://b.example/")!: .unreachable,
        ]
        let locations = BrokenLinkAuditRunner.externalLinkFindings(from: results).map(\.location)
        #expect(locations == ["https://a.example/", "https://b.example/", "https://c.example/"])
    }

    @Test("all reachable adds no findings")
    func allReachable() {
        #expect(BrokenLinkAuditRunner.externalLinkFindings(from: [fine: .reachable]).isEmpty)
    }

    @Test("the log records what the off-site check found, after the internal-scan line")
    func logLine() async throws {
        let logCenter = LogCenter()
        let probe = FakeProbe([gone: .unreachable, challenged: .indeterminate])
        _ = try await Self.run(
            external: [gone.absoluteString, challenged.absoluteString, fine.absoluteString],
            enabled: true, probe: probe, logCenter: logCenter)
        let lines = await logCenter.snapshot().filter { $0.source == "test" }.map(\.text)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("broken-link check:"))
        #expect(lines[1] == "off-site link check: 3 checked, 1 no longer work, 1 couldn't be verified")
    }

    // MARK: - The live setting

    @Test("the live gate reads SiteSettings.externalLinkCheckEnabled from the package's Config/")
    func liveGateReadsSettings() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("ext-pkg-\(UUID().uuidString).anglesite")
        defer { try? FileManager.default.removeItem(at: package) }
        let layout = AnglesitePackage(url: package)
        try FileManager.default.createDirectory(at: layout.sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.configURL, withIntermediateDirectories: true)
        let live = BrokenLinkAuditRunner.ExternalLinkCheck.live

        // No settings file yet: off.
        #expect(await live.isEnabled(layout.sourceURL) == false)

        let store = SiteConfigStore(configDirectory: layout.configURL)
        try await store.save(SiteSettings(externalLinkCheckEnabled: true))
        #expect(await live.isEnabled(layout.sourceURL) == true)

        try await store.save(SiteSettings(externalLinkCheckEnabled: false))
        #expect(await live.isEnabled(layout.sourceURL) == false)
    }

    @Test("a plain directory that isn't inside a package reads as off")
    func liveGateOffOutsidePackage() async {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("ext-plain-\(UUID().uuidString)")
        #expect(await BrokenLinkAuditRunner.ExternalLinkCheck.live.isEnabled(plain) == false)
    }
}
