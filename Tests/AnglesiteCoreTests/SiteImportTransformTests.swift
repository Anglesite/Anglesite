import Foundation
import Testing

@testable import AnglesiteCore

@Suite struct SiteImportTransformTests {
    /// A real 1x1 PNG, so `LinkImageAsset.format(sniffing:)` sniffs it as `.png`.
    private static let pngBytes = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

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

        // Processing order is `ResolvedContent.items` order: publish date descending.
        #expect(report.writtenPaths == ["src/content/blog/second-post.md",
                                        "src/content/blog/hello-wordpress.md",
                                        "src/pages/about.md"])
        // Both posts reference one remote image; each is installed under the post's own slug,
        // with the extension the captured bytes sniff as (PNG) rather than the URL's `.jpg`.
        #expect(report.installedImagePaths == ["public/images/link-second-post-1.png",
                                               "public/images/link-hello-wordpress-1.png"])
        #expect(report.plan.imageCount == 2)
        // No remote image URL survives into the emitted body.
        for path in report.writtenPaths {
            let written = try String(contentsOf: source.appendingPathComponent(path), encoding: .utf8)
            #expect(!written.contains("wp-content/uploads"), "remote image URL left in \(path)")
        }
    }

    /// The `photos` collection's required `image:` comes from the item's `.photo` hint, not from
    /// the Markdown body — so it needs the same remote-URL → local-path rewrite the body gets, or
    /// the entry ships pointing at the old site's origin and the strict CSP blocks it.
    @Test func photoFrontmatterPointsAtTheLocalizedImage() throws {
        let imageURL = "https://photo.example/img/sunset.jpg"
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "url":["https://photo.example/photos/sunset"],
          "published":["2024-05-01T12:00:00Z"],
          "photo":["\(imageURL)"]}}]}
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://photo.example",
            probes: SiteProbes(),
            pages: [CapturedPage(url: "https://photo.example/photos/sunset",
                                 extraction: ExtractionRecord(markdown: "Sunset.", mf2JSON: mf2))],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/sunset.png")],
            conversions: [:])

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshotDirectory = work.appendingPathComponent("snapshot", isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        for directory in [snapshotDirectory.appendingPathComponent("assets"), source, config] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.pngBytes.write(to: snapshotDirectory.appendingPathComponent("assets/sunset.png"))

        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: snapshotDirectory,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { _ in })

        #expect(report.writeProblems.isEmpty)
        #expect(report.writtenPaths == ["src/content/photos/sunset.md"])
        #expect(report.installedImagePaths == ["public/images/link-sunset-1.png"])
        let written = try String(
            contentsOf: source.appendingPathComponent("src/content/photos/sunset.md"), encoding: .utf8)
        #expect(written.contains(#"image: "/images/link-sunset-1.png""#))
        #expect(!written.contains(imageURL))
    }

    /// The counterpart: an image with no captured bytes can't be localized, so the frontmatter
    /// keeps the remote URL — but never silently. The refusal is recorded as a write problem.
    @Test func unlocalizablePhotoKeepsRemoteURLAndReportsIt() throws {
        let imageURL = "https://photo.example/img/gone.jpg"
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "url":["https://photo.example/photos/gone"],
          "published":["2024-05-01T12:00:00Z"],
          "photo":["\(imageURL)"]}}]}
        """
        let snapshot = ImportSnapshot(
            siteURL: "https://photo.example",
            probes: SiteProbes(),
            pages: [CapturedPage(url: "https://photo.example/photos/gone",
                                 extraction: ExtractionRecord(markdown: "Gone.", mf2JSON: mf2))],
            assets: [], conversions: [:])

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        for directory in [source, config] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: work) }

        let report = try ImportTransform.run(
            snapshot: snapshot, snapshotDirectory: work,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { _ in })

        #expect(report.installedImagePaths.isEmpty)
        #expect(report.writeProblems.contains { $0.sourceURL == imageURL })
        let written = try String(
            contentsOf: source.appendingPathComponent("src/content/photos/gone.md"), encoding: .utf8)
        #expect(written.contains("image: \"\(imageURL)\""))
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
