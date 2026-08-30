import CoreGraphics
import Foundation
import ImageIO
import PDFKit
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
        #expect(CGImageMetadataTagCopyValue(markedTag!) as? String == "True")
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

    private func makeDetailedTestImage(width: Int = 32, height: Int = 32) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let r = CGFloat((x * 7 + y * 13) % 256) / 255
                let g = CGFloat((x * 31 + y * 3) % 256) / 255
                let b = CGFloat((x * 5 + y * 17) % 256) / 255
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    private func imageData(type: UTType) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeDetailedTestImage(), nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func exactPixelBytes(of data: Data) -> [UInt8] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: width * 4, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    @Test("every supported image type embeds a readable license",
          arguments: [UTType.jpeg, .png, .tiff, .heic])
    func everySupportedImageTypeRoundTrips(type: UTType) throws {
        let original = imageData(type: type)
        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: type)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded for \(type.identifier), got \(result)")
            return
        }
        let source = CGImageSourceCreateWithData(outData as CFData, nil)!
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
        let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString)
        #expect(tag != nil, "\(type.identifier) is missing its license tag")
        #expect(CGImageMetadataTagCopyValue(tag!) as? String == license.url)
    }

    @Test("embedding into a lossy format (JPEG) does not alter pixel content")
    func jpegEmbedIsPixelLossless() throws {
        let original = imageData(type: .jpeg)
        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: .jpeg)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        #expect(exactPixelBytes(of: original) == exactPixelBytes(of: outData))
    }

    @Test("a type argument that doesn't match the actual source format fails instead of silently transcoding")
    func mismatchedTypeFails() {
        let pngBytes = imageData(type: .png)
        #expect(throws: LicenseMetadataEmbedder.EmbedError.writeFailed) {
            _ = try LicenseMetadataEmbedder.embed(license, into: pngBytes, type: .jpeg)
        }
    }

    private func onePagePDFData() -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: 50, height: 50)
        let out = NSMutableData()
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    /// Reads the XMP packet `embedIntoPDF` writes back out — via `CGPDFDocument`'s catalog
    /// `/Metadata` stream, the actual location `CGContext.addDocumentMetadata(_:)` writes to.
    /// PDFKit has no XMP accessor, so this is the only way to verify the embed actually landed.
    private func extractXMP(from data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return nil }
        var metadataStream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &metadataStream), let stream = metadataStream else {
            return nil
        }
        var format: CGPDFDataFormat = .raw
        guard let streamData = CGPDFStreamCopyData(stream, &format) else { return nil }
        return String(data: streamData as Data, encoding: .utf8)
    }

    @Test("embedding into a PDF returns .embedded with the license in its XMP metadata")
    func embedsIntoPDF() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: onePagePDFData(), type: .pdf)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let xmp = try #require(extractXMP(from: outData))
        #expect(xmp.contains(license.url))
        #expect(xmp.contains(license.name))
    }

    @Test("embedding into a PDF preserves page count and existing attributes")
    func preservesPDFFidelity() throws {
        let original = onePagePDFData()
        let originalDoc = PDFDocument(data: original)!
        let originalAttrs = originalDoc.documentAttributes ?? [:]

        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: .pdf)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let outDoc = PDFDocument(data: outData)!
        #expect(outDoc.pageCount == originalDoc.pageCount)
        for (key, _) in originalAttrs {
            #expect(outDoc.documentAttributes?[key] != nil, "lost existing attribute \(key)")
        }
    }

    @Test("unreadable PDF bytes throw .unreadable")
    func unreadablePDFThrows() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(throws: LicenseMetadataEmbedder.EmbedError.unreadable) {
            _ = try LicenseMetadataEmbedder.embed(license, into: garbage, type: .pdf)
        }
    }

    @Test("readLicense returns nil for a type outside supportedTypes")
    func readLicenseUnsupportedTypeReturnsNil() {
        #expect(LicenseMetadataEmbedder.readLicense(from: Data(), type: .zip) == nil)
    }

    @Test("readLicense returns nil for a supported type with no embedded license")
    func readLicenseNoLicenseReturnsNil() {
        #expect(LicenseMetadataEmbedder.readLicense(from: pngData(), type: .png) == nil)
    }

    @Test("readLicense round-trips embed for every supported image type",
          arguments: [UTType.jpeg, .png, .tiff, .heic])
    func readLicenseRoundTripsImages(type: UTType) throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: imageData(type: type), type: type)
        guard case .embedded(let embedded) = result else {
            Issue.record("expected .embedded for \(type.identifier), got \(result)")
            return
        }
        let readBack = LicenseMetadataEmbedder.readLicense(from: embedded, type: type)
        #expect(readBack == license, "\(type.identifier) failed to round-trip")
    }

    @Test("readLicense round-trips embed for PDF")
    func readLicenseRoundTripsPDF() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: onePagePDFData(), type: .pdf)
        guard case .embedded(let embedded) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        #expect(LicenseMetadataEmbedder.readLicense(from: embedded, type: .pdf) == license)
    }

    @Test("readLicense returns nil for unreadable bytes rather than throwing")
    func readLicenseUnreadableBytesReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(LicenseMetadataEmbedder.readLicense(from: garbage, type: .png) == nil)
        #expect(LicenseMetadataEmbedder.readLicense(from: garbage, type: .pdf) == nil)
    }
}
