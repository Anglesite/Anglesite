import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnglesiteCore

/// End-to-end coverage of the drop pipeline's embed-then-ingest sequence (#1671): the actual
/// glue lives inline in `SiteWindow.swift`'s `.onDrop` handler (an app-target file with no CI
/// coverage — see `AGENTS.md`), so these tests exercise the same two `AnglesiteCore` calls in the
/// same order the handler makes them, against the testable public APIs.
@Suite("WYSIWYG drop license embedding (#1671)")
struct WYSIWYGDropLicenseEmbeddingTests {
    private let license = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

    private func pngData() -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("sniffedUTType recognizes every format ingest recognizes")
    func sniffedUTTypeCoversRecognizedFormats() {
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(pngData()) == .png)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data([0xFF, 0xD8, 0xFF])) == .jpeg)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data("GIF8".utf8)) == .gif)
        let webpBytes = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(webpBytes) != nil)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("the file written into public/images carries the license, and the on-disk source is untouched")
    func embeddedFileCarriesLicenseAndSourceIsUntouched() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A dragged file has a real file on disk as its source (e.g. Finder); write the fixture
        // there first so the test can assert it's byte-identical afterward, matching the design
        // constraint that the owner's original file is never opened for writing (#999 §4).
        let sourceURL = scratch.appendingPathComponent("source.png")
        let originalBytes = pngData()
        try originalBytes.write(to: sourceURL)

        var bytes = try Data(contentsOf: sourceURL)
        let type = try #require(WYSIWYGImageAssetIngestor.sniffedUTType(bytes))
        if case .embedded(let embedded) = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type) {
            bytes = embedded
        }

        let siteDirectory = scratch.appendingPathComponent("site")
        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: siteDirectory))
        let written = siteDirectory.appendingPathComponent("public/images")
            .appendingPathComponent(String(path.dropFirst("/images/".count)))
        let writtenData = try Data(contentsOf: written)

        let source = CGImageSourceCreateWithData(writtenData as CFData, nil)!
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
        let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString)
        #expect(CGImageMetadataTagCopyValue(tag!) as? String == license.url)

        #expect(try Data(contentsOf: sourceURL) == originalBytes)
    }

    @Test("an unsupported format (WebP) is ingested with its original bytes unchanged, without throwing")
    func unsupportedFormatIngestsUnchanged() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Minimal RIFF/WEBP header — enough for the magic-byte sniff; `LicenseMetadataEmbedder`
        // never actually reads it since `.webp` isn't in `supportedTypes`.
        let webpBytes = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)
        var bytes = webpBytes
        let type = try #require(WYSIWYGImageAssetIngestor.sniffedUTType(bytes))
        let result = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type)
        #expect(result == .unsupported)
        if case .embedded(let embedded) = result {
            bytes = embedded
        }

        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: scratch))
        let written = scratch.appendingPathComponent("public/images")
            .appendingPathComponent(String(path.dropFirst("/images/".count)))
        #expect(try Data(contentsOf: written) == webpBytes)
    }
}
