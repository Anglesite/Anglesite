import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnglesiteCore

@Suite("LicenseMetadataEmbedder (#999)")
struct LicenseMetadataEmbedderTests {
    private let license = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

    @Test("a format with no metadata slot resolves to .unsupported, not an error")
    func unsupportedFormatDoesNotThrow() throws {
        let bytes = Data("not a real archive".utf8)
        let result = try LicenseMetadataEmbedder.embed(license, into: bytes, type: .zip)
        #expect(result == .unsupported)
    }

    @Test("supportedTypes lists exactly the image and PDF formats this plan implements")
    func supportedTypesScope() {
        #expect(LicenseMetadataEmbedder.supportedTypes == [.jpeg, .png, .tiff, .heic, .pdf])
    }

    @Test("audio and video types resolve to .unsupported (no AVFoundation backend yet)")
    func avTypesUnsupported() throws {
        for type: UTType in [.mpeg4Movie, .quickTimeMovie, .mp3, .wav] {
            let result = try LicenseMetadataEmbedder.embed(license, into: Data(), type: type)
            #expect(result == .unsupported, "\(type.identifier) should be unsupported")
        }
    }

    private func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func pngData(properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeTestImage(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("embedding into a PNG returns .embedded with readable license metadata")
    func embedsIntoPNG() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: pngData(), type: .png)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let source = CGImageSourceCreateWithData(outData as CFData, nil)!
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
        let webStatementTag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString)
        #expect(CGImageMetadataTagCopyValue(webStatementTag!) as? String == license.url)
        let markedTag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:Marked" as CFString)
        #expect(markedTag != nil)
    }

    @Test("embedding preserves existing image properties like orientation")
    func preservesExistingProperties() throws {
        // NOTE: PNG's pHYs chunk requires both DPI axes set together to preserve either one
        // (verified live) — a single axis alone is silently dropped by ImageIO's PNG encoder.
        // That's a fact about how this fixture must be constructed, not a limitation of PNG's
        // format capabilities or of the embedder's merge logic.
        let original = pngData(properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 240,
            kCGImagePropertyDPIHeight: 240,
        ])
        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: .png)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let source = CGImageSourceCreateWithData(outData as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] as? Int == 6)
        #expect(props?[kCGImagePropertyDPIWidth] as? Int == 240)
        #expect(props?[kCGImagePropertyDPIHeight] as? Int == 240)
    }

    @Test("unreadable image bytes throw .unreadable rather than returning .unsupported")
    func unreadableImageThrows() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(throws: LicenseMetadataEmbedder.EmbedError.unreadable) {
            _ = try LicenseMetadataEmbedder.embed(license, into: garbage, type: .png)
        }
    }
}
