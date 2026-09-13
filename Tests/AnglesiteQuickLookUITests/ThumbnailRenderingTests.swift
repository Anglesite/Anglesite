// Smoke tests for the Quick Look *thumbnail* extension's logic (#1968): the source decision
// `ThumbnailProvider` maps onto `QLThumbnailReply`, and the monogram badge it draws when no
// cached render exists — rasterized into an `NSImage` and inspected pixel-wise.
import AppKit
import Foundation
import Testing
@testable import AnglesiteQuickLookUI

@Suite("Quick Look thumbnail rendering")
struct ThumbnailRenderingTests {
    @Test("a package with no cached render gets the monogram of its display name")
    func fixtureFallsBackToMonogram() {
        let source = ThumbnailRendering.source(for: PreviewContentViewRenderingTests.fixturePackageURL)
        #expect(source == .monogram(displayName: "Fixture Site"))
    }

    @Test("a cached Config/quicklook-thumbnail.png wins over the monogram")
    func cachedRenderWins() throws {
        let copy = try PreviewContentViewRenderingTests.copyFixture()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let thumbnailURL = copy.appendingPathComponent("Config/quicklook-thumbnail.png")
        try FileManager.default.createDirectory(at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: thumbnailURL.path, contents: Data([0x89]))

        #expect(ThumbnailRendering.source(for: copy) == .cachedImage(thumbnailURL))
    }

    @Test("a directory without a marker yields no source, so Quick Look keeps its default icon")
    func nonPackageYieldsNil() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-thumb-nonpackage-\(UUID().uuidString).anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(ThumbnailRendering.source(for: scratch) == nil)
    }

    @Test("the monogram badge draws a blue rounded rect with a white glyph inside the 5% inset")
    func monogramDrawsBadgeAndGlyph() throws {
        let size = CGSize(width: 128, height: 128)
        let image = ThumbnailRendering.monogramImage(for: "Fixture Site", size: size)
        #expect(image.size == size)
        let bitmap = try Self.bitmap(image)

        // The very corner lies inside the 5% inset: nothing drawn there.
        let corner = try #require(bitmap.colorAt(x: 1, y: 1))
        #expect(corner.alphaComponent < 0.1)

        // Just inside the inset (away from the rounded corner) the badge fill shows: blue-ish.
        // Sampled in *pixels* relative to the bitmap's own size — the rasterized image is 2x on
        // a Retina main screen, so a fixed 10-pixel offset would land inside the 5% inset.
        let edge = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.sRGB))
        #expect(edge.alphaComponent > 0.9)
        #expect(edge.blueComponent > edge.redComponent)

        // Somewhere in the middle third the glyph's white lands.
        #expect(Self.containsNearWhitePixel(bitmap), "expected the 'F' glyph to be drawn in white")
    }

    @Test("an empty display name still draws the badge, just without a glyph")
    func emptyNameDrawsBadgeOnly() throws {
        let image = ThumbnailRendering.monogramImage(for: "", size: CGSize(width: 64, height: 64))
        let bitmap = try Self.bitmap(image)
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.alphaComponent > 0.9)
        #expect(center.blueComponent > center.redComponent)
        #expect(!Self.containsNearWhitePixel(bitmap))
    }

    @Test("drawMonogram reports false with no current graphics context")
    func drawWithoutContextReportsFalse() {
        // Outside any drawing handler there is no current context — the reply closure must not
        // report success for a thumbnail it never drew.
        #expect(NSGraphicsContext.current == nil)
        #expect(ThumbnailRendering.drawMonogram(for: "X", size: CGSize(width: 8, height: 8)) == false)
    }

    // MARK: - Helpers

    private static func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private static func containsNearWhitePixel(_ bitmap: NSBitmapImageRep) -> Bool {
        let (w, h) = (bitmap.pixelsWide, bitmap.pixelsHigh)
        for y in (h / 3)..<(2 * h / 3) {
            for x in (w / 3)..<(2 * w / 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9, c.alphaComponent > 0.9 {
                    return true
                }
            }
        }
        return false
    }
}
