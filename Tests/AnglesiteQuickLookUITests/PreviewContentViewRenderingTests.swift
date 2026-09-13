// Smoke tests for the Quick Look *preview* extension's rendering (#1968): the exact view
// `PreviewViewController` hosts, built from a committed fixture package and rasterized through
// SwiftUI's `ImageRenderer` — so a regression in the summary → view path fails here instead of
// only inside a Quick Look host nobody runs on CI.
import AppKit
import Foundation
import SwiftUI
import Testing
import AnglesiteQuickLookSupport
@testable import AnglesiteQuickLookUI

@Suite("Quick Look preview rendering")
struct PreviewContentViewRenderingTests {
    /// The committed fixture: a marker plus two pages and one `notes` entry under `Source/`.
    static var fixturePackageURL: URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Fixture.anglesite", isDirectory: true)
    }

    @Test("the fixture package summarizes to its marker identity and layout facts")
    func fixtureSummarizes() throws {
        let view = PreviewContentView(packageURL: Self.fixturePackageURL)
        let summary = try #require(view.summary)
        #expect(summary.displayName == "Fixture Site")
        #expect(summary.pageCount == 2)
        #expect(summary.collectionCounts == [PackagePreviewSummary.CollectionCount(name: "notes", count: 1)])
        #expect(summary.cachedThumbnailURL == nil)
        #expect(summary.sourceLastModified != nil)
    }

    @Test("the preview renders the fixture package to a non-empty image")
    @MainActor
    func rendersFixtureToImage() throws {
        let image = try Self.render(PreviewContentView(packageURL: Self.fixturePackageURL))
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(Self.hasVisibleContent(image))
    }

    @Test("a directory that isn't a package renders the not-a-site fallback instead of failing")
    @MainActor
    func rendersFallbackForNonPackage() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-preview-fallback-\(UUID().uuidString).anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let view = PreviewContentView(packageURL: scratch)
        #expect(view.summary == nil)
        let image = try Self.render(view)
        #expect(Self.hasVisibleContent(image))
    }

    @Test("a cached thumbnail is picked up for the preview header when present")
    func summaryPicksUpCachedThumbnail() throws {
        let copy = try Self.copyFixture()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let thumbnailURL = copy.appendingPathComponent("Config/quicklook-thumbnail.png")
        try FileManager.default.createDirectory(at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pngData(ThumbnailRendering.monogramImage(for: "F", size: CGSize(width: 32, height: 32))).write(to: thumbnailURL)

        let view = PreviewContentView(packageURL: copy)
        #expect(view.summary?.cachedThumbnailURL == thumbnailURL)
    }

    // MARK: - Helpers

    /// Rasterizes `view` at a fixed preview-ish size. `ImageRenderer` needs the main actor.
    @MainActor
    private static func render(_ view: PreviewContentView) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: 480, height: 320))
        renderer.scale = 1
        return try #require(renderer.nsImage)
    }

    /// `true` when at least one rendered pixel is opaque — a blank image means the view drew
    /// nothing (the failure mode a smoke test exists to catch).
    private static func hasVisibleContent(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                    return true
                }
            }
        }
        return false
    }

    /// Copies the read-only bundle fixture somewhere writable, returning the package URL.
    static func copyFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-fixture-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("Fixture.anglesite", isDirectory: true)
        try FileManager.default.copyItem(at: fixturePackageURL, to: copy)
        return copy
    }

    static func pngData(_ image: NSImage) throws -> Data {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
    }
}
