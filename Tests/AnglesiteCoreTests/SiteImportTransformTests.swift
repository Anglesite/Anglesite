import Foundation
import Testing

@testable import AnglesiteCore

@Suite struct SiteImportTransformTests {
    @Test func wpSiteGoldenRun() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures/SiteImport/wp-site", withExtension: nil)!
        let snapshot = try JSONDecoder().decode(
            ImportSnapshot.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("snapshot.json")))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "[]\n".write(to: source.appendingPathComponent("redirects.json"), atomically: true, encoding: .utf8)

        var steps: [ImportStep] = []
        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: fixtures,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { steps.append($0) })

        let expectedRoot = fixtures.appendingPathComponent("expected")
        let enumerator = FileManager.default.enumerator(at: expectedRoot, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let expectedFile as URL in enumerator where try expectedFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = expectedFile.path.replacingOccurrences(of: expectedRoot.path + "/", with: "")
            let produced = source.appendingPathComponent(relative)
            #expect(FileManager.default.contentsEqual(atPath: produced.path, andPath: expectedFile.path),
                    "mismatch at \(relative)")
        }
        #expect(report.writeProblems.isEmpty)
        #expect(steps.first == .resolvingContent)
        #expect(try ImportReport.load(from: config) == report)
    }

    @Test func unreadableRedirectsFileIsLeftUntouched() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures/SiteImport/wp-site", withExtension: nil)!
        let snapshot = try JSONDecoder().decode(
            ImportSnapshot.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("snapshot.json")))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Existing, non-empty, but not decodable as UTF-8 — stands in for any redirects.json the
        // app can see but cannot read. Its bytes are the owner's data and must survive the run.
        let redirectsURL = source.appendingPathComponent("redirects.json")
        let undecodable = Data([0xFF, 0xFE, 0x00, 0x80, 0x81])
        try undecodable.write(to: redirectsURL)

        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: fixtures,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { _ in })

        #expect(try Data(contentsOf: redirectsURL) == undecodable)
        #expect(report.writeProblems.contains { $0.message.contains("Could not read redirects.json") })
        // The rest of the import still landed.
        #expect(report.writtenPaths.contains("src/content/blog/hello-wordpress.md"))
    }

    @Test func missingRedirectsFileStartsFromAnEmptySet() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures/SiteImport/wp-site", withExtension: nil)!
        let snapshot = try JSONDecoder().decode(
            ImportSnapshot.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("snapshot.json")))
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: fixtures,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { _ in })

        let written = try String(contentsOf: source.appendingPathComponent("redirects.json"), encoding: .utf8)
        // `JSONEncoder` escapes the forward slashes in the emitted paths.
        #expect(written.contains(#"\/blog\/hello-wordpress\/"#))
        #expect(!report.writeProblems.contains { $0.message.contains("redirects.json") })
    }

    @Test func missingSourceDirectoryThrows() throws {
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [], assets: [], conversions: [:])
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteImportTransformTests-missing-\(UUID().uuidString)", isDirectory: true)
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteImportTransformTests-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }

        #expect(throws: ImportTransformError.sourceDirectoryMissing(missing.path)) {
            try ImportTransform.run(
                snapshot: snapshot, snapshotDirectory: missing,
                sourceDirectory: missing, configDirectory: config,
                now: Date(timeIntervalSince1970: 0), onStep: { _ in })
        }
    }
}
