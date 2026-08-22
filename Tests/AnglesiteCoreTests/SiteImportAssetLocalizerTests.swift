import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportAssetLocalizerTests {
    /// A real 1x1 PNG, so `LinkImageAsset.format(sniffing:)` sniffs it as `.png`.
    private static let pngBytes = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    /// Creates an isolated snapshot directory (with the PNG written under it) and an isolated
    /// site directory, both cleaned up by the caller via the returned URLs.
    private func makeFixture() throws -> (snapshotDirectory: URL, siteDirectory: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetLocalizerTests-\(UUID().uuidString)", isDirectory: true)
        let snapshotDirectory = base.appendingPathComponent("snapshot", isDirectory: true)
        let siteDirectory = base.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siteDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: snapshotDirectory.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Self.pngBytes.write(to: snapshotDirectory.appendingPathComponent("assets/photo.png"))
        return (snapshotDirectory, siteDirectory)
    }

    private func cleanup(_ snapshotDirectory: URL) {
        try? FileManager.default.removeItem(at: snapshotDirectory.deletingLastPathComponent())
    }

    @Test func installsCapturedImageAndRewritesMarkdown() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let imageURL = "https://example.com/photo.png"
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/photo.png")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "See ![alt](\(imageURL))",
            imageURLs: [imageURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        // LinkImageAsset.fileName (existing, not modified here) always prefixes "link-", so the
        // installed path is /images/link-<slug>-<n>.<ext>, not /images/<slug>-<n>.<ext>.
        #expect(result.markdown == "See ![alt](/images/link-hello-1.png)")
        #expect(result.installedPaths == ["public/images/link-hello-1.png"])
        #expect(result.problems.isEmpty)

        let installedFile = siteDirectory.appendingPathComponent("public/images/link-hello-1.png")
        #expect(FileManager.default.fileExists(atPath: installedFile.path))
    }

    @Test func replacesAllOccurrencesOfTheSameURL() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let imageURL = "https://example.com/photo.png"
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/photo.png")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![a](\(imageURL)) and again ![b](\(imageURL))",
            imageURLs: [imageURL], itemSlug: "twice",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![a](/images/link-twice-1.png) and again ![b](/images/link-twice-1.png)")
        #expect(result.problems.isEmpty)
    }

    @Test func missingAssetYieldsOneProblemAndLeavesURLUnchanged() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let missingURL = "https://example.com/missing.png"
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [], assets: [],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "See ![alt](\(missingURL))",
            imageURLs: [missingURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "See ![alt](\(missingURL))")
        #expect(result.installedPaths.isEmpty)
        #expect(result.problems.count == 1)
        #expect(result.problems[0].sourceURL == missingURL)
        #expect(result.problems[0].message.hasPrefix("Image could not be imported:"))
    }

    @Test func unreadableFileYieldsOneProblemAndLeavesURLUnchanged() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        // Asset record exists, but no file was written at that relative path.
        let imageURL = "https://example.com/ghost.png"
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/ghost.png")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![alt](\(imageURL))",
            imageURLs: [imageURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![alt](\(imageURL))")
        #expect(result.problems.count == 1)
    }

    @Test func oversizedImageIsRefused() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        // Build an oversized but still PNG-signed payload so only the size check trips.
        var oversized = Self.pngBytes
        oversized.append(Data(repeating: 0, count: LinkImageAsset.maximumImageBytes + 1))
        let imageURL = "https://example.com/huge.png"
        try oversized.write(to: snapshotDirectory.appendingPathComponent("assets/huge.png"))
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/huge.png")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![alt](\(imageURL))",
            imageURLs: [imageURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![alt](\(imageURL))")
        #expect(result.installedPaths.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func svgIsRefusedAsUnsupportedFormat() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let svgBytes = Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)
        let imageURL = "https://example.com/icon.svg"
        try svgBytes.write(to: snapshotDirectory.appendingPathComponent("assets/icon.svg"))
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: imageURL, relativePath: "assets/icon.svg")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![alt](\(imageURL))",
            imageURLs: [imageURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![alt](\(imageURL))")
        #expect(result.installedPaths.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func multipleImagesAreIndexedInOrder() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let urlOne = "https://example.com/one.png"
        let urlTwo = "https://example.com/two.png"
        try Self.pngBytes.write(to: snapshotDirectory.appendingPathComponent("assets/two.png"))
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [],
            assets: [
                CapturedAsset(sourceURL: urlOne, relativePath: "assets/photo.png"),
                CapturedAsset(sourceURL: urlTwo, relativePath: "assets/two.png"),
            ],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![a](\(urlOne)) ![b](\(urlTwo))",
            imageURLs: [urlOne, urlTwo], itemSlug: "gallery",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![a](/images/link-gallery-1.png) ![b](/images/link-gallery-2.png)")
        #expect(result.installedPaths == ["public/images/link-gallery-1.png", "public/images/link-gallery-2.png"])
        #expect(result.problems.isEmpty)
    }

    /// A plain substring replace would corrupt a longer, distinct URL that merely starts with the
    /// exact URL being replaced (e.g. a `?v=2` query-string variant) — regression coverage for
    /// that boundary bug.
    @Test func doesNotCorruptALongerURLThatStartsWithTheExactMatch() throws {
        let (snapshotDirectory, siteDirectory) = try makeFixture()
        defer { cleanup(snapshotDirectory) }

        let exactURL = "https://e.com/photo.jpg"
        let variantURL = "https://e.com/photo.jpg?v=2"
        let snapshot = ImportSnapshot(
            siteURL: "https://e.com", probes: SiteProbes(), pages: [],
            assets: [CapturedAsset(sourceURL: exactURL, relativePath: "assets/photo.png")],
            conversions: [:])

        let result = AssetLocalizer.localize(
            markdown: "![a](\(exactURL)) ![b](\(variantURL)) ![c](\(exactURL))",
            imageURLs: [exactURL], itemSlug: "hello",
            snapshot: snapshot, snapshotDirectory: snapshotDirectory, siteDirectory: siteDirectory)

        #expect(result.markdown == "![a](/images/link-hello-1.png) ![b](\(variantURL)) ![c](/images/link-hello-1.png)")
        #expect(result.problems.isEmpty)
    }
}
