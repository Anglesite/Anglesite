#if canImport(Darwin)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnglesiteCore

/// Drop-time image optimisation (#2019). Fixtures are generated in-test with ImageIO, so there's
/// nothing binary checked in and each case states exactly the metadata it starts from.
@Suite("ImageOptimizer (#2019)")
struct ImageOptimizerTests {

    // MARK: - Fixtures

    static let heicWritable = ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("public.heic")

    static func image(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// GPS, a non-default orientation, and TIFF + IPTC copyright — the metadata the issue names.
    static func taggedProperties() -> [CFString: Any] { [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.35, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 121.95, kCGImagePropertyGPSLongitudeRef: "W",
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCopyright: "© 2026 Owner"] as [CFString: Any],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "© 2026 Owner"] as [CFString: Any],
    ] }

    static func properties(of data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    static func optimised(_ outcome: ImageOptimizer.Outcome) throws -> ImageOptimizer.Optimised {
        guard case .optimised(let optimised) = outcome else {
            Issue.record("expected .optimised, got \(outcome)")
            throw CancellationError()
        }
        return optimised
    }

    // MARK: - Conversion

    @Test("a HEIC becomes a JPEG", .enabled(if: ImageOptimizerTests.heicWritable))
    func heicToJPEG() throws {
        let heic = Self.encode(Self.image(width: 400, height: 300), type: .heic)
        let result = try Self.optimised(ImageOptimizer.optimise(heic))
        #expect(Self.type(of: result.data) == UTType.jpeg.identifier)
        #expect(result.fileExtension == "jpg")
        #expect(result.changes == [.converted(from: "HEIC", to: "JPEG")])
    }

    @Test("a TIFF with transparency becomes a PNG, and an opaque one a JPEG")
    func tiffToPNGOrJPEG() throws {
        let withAlpha = Self.encode(Self.image(width: 64, height: 64, alpha: true), type: .tiff)
        let png = try Self.optimised(ImageOptimizer.optimise(withAlpha))
        #expect(Self.type(of: png.data) == UTType.png.identifier)
        #expect(png.fileExtension == "png")
        #expect(png.changes == [.converted(from: "TIFF", to: "PNG")])

        let opaque = Self.encode(Self.image(width: 64, height: 64), type: .tiff)
        let jpeg = try Self.optimised(ImageOptimizer.optimise(opaque))
        #expect(Self.type(of: jpeg.data) == UTType.jpeg.identifier)
    }

    @Test("a BMP is converted to a web format")
    func bmpConverted() throws {
        let bmp = Self.encode(Self.image(width: 32, height: 32), type: .bmp)
        let result = try Self.optimised(ImageOptimizer.optimise(bmp))
        // JPEG or PNG depending on whether the BMP writer kept an alpha channel — either renders.
        #expect([UTType.jpeg.identifier, UTType.png.identifier].contains(Self.type(of: result.data) ?? ""))
        guard case .converted(from: "BMP", to: _) = result.changes.first else {
            Issue.record("expected a BMP conversion, got \(result.changes)")
            return
        }
    }

    // MARK: - Downscaling

    @Test("an image past the cap is downscaled to exactly the cap on its longest edge, aspect preserved")
    func downscalesToCap() throws {
        let jpeg = Self.encode(Self.image(width: 3000, height: 1500), type: .jpeg)
        let result = try Self.optimised(ImageOptimizer.optimise(jpeg))
        let properties = Self.properties(of: result.data)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2000)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1000)
        #expect(Self.type(of: result.data) == UTType.jpeg.identifier)
        #expect(result.changes == [.downscaled(fromWidth: 3000, fromHeight: 1500, toWidth: 2000, toHeight: 1000)])
    }

    @Test("the cap is a parameter")
    func capIsAParameter() throws {
        let png = Self.encode(Self.image(width: 400, height: 800, alpha: true), type: .png)
        let result = try Self.optimised(ImageOptimizer.optimise(png, maxPixelSize: 200))
        let properties = Self.properties(of: result.data)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 100)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 200)
        #expect(Self.type(of: result.data) == UTType.png.identifier)
    }

    @Test("an image under the cap with nothing to fix is left unchanged — never upscaled")
    func underCapUnchanged() {
        let jpeg = Self.encode(Self.image(width: 800, height: 600), type: .jpeg)
        #expect(ImageOptimizer.optimise(jpeg) == .unchanged)
    }

    // MARK: - Metadata

    @Test("a re-encode drops GPS but keeps orientation and TIFF/IPTC copyright")
    func reencodeMetadata() throws {
        let jpeg = Self.encode(Self.image(width: 300, height: 200), type: .jpeg, properties: Self.taggedProperties())
        let result = try Self.optimised(ImageOptimizer.optimise(jpeg, maxPixelSize: 150))
        let properties = Self.properties(of: result.data)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        let tiffDictionary = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiffDictionary?[kCGImagePropertyTIFFCopyright] as? String == "© 2026 Owner")
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String == "© 2026 Owner")
        #expect(result.changes == [.downscaled(fromWidth: 300, fromHeight: 200, toWidth: 150, toHeight: 100), .removedLocation])
    }

    @Test("a web-ready image with a location only has the location removed")
    func locationOnly() throws {
        let jpeg = Self.encode(Self.image(width: 64, height: 48), type: .jpeg, properties: Self.taggedProperties())
        #expect(Self.properties(of: jpeg)[kCGImagePropertyGPSDictionary] != nil)
        let result = try Self.optimised(ImageOptimizer.optimise(jpeg))
        let properties = Self.properties(of: result.data)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(result.changes == [.removedLocation])
        #expect(result.fileExtension == "jpg")
    }

    @Test("a license embedded before the drop survives a conversion")
    func licenseSurvivesConversion() throws {
        let license = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")
        let tiff = Self.encode(Self.image(width: 64, height: 48), type: .tiff)
        guard case .embedded(let licensed) = try LicenseMetadataEmbedder.embed(license, into: tiff, type: .tiff) else {
            Issue.record("TIFF should accept a license")
            return
        }
        let result = try Self.optimised(ImageOptimizer.optimise(licensed))
        #expect(LicenseMetadataEmbedder.readLicense(from: result.data, type: .jpeg) == license)
    }

    // MARK: - Failure

    @Test("bytes that don't decode fail softly instead of throwing")
    func garbageFails() {
        guard case .failed = ImageOptimizer.optimise(Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])) else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test("the summary lists every change in order")
    func summary() {
        let optimised = ImageOptimizer.Optimised(
            data: Data(), fileExtension: "jpg",
            changes: [.converted(from: "HEIC", to: "JPEG"),
                      .downscaled(fromWidth: 4032, fromHeight: 3024, toWidth: 2000, toHeight: 1500),
                      .removedLocation])
        #expect(optimised.summary == "HEIC → JPEG, 4032×3024 → 2000×1500, location removed")
    }
}

/// The ingestor half of #2019: the optimiser runs on drop, and the per-site opt-out bypasses it.
@Suite("WYSIWYGImageAssetIngestor optimisation (#2019)")
struct WYSIWYGImageAssetIngestorOptimisationTests {

    /// A throwaway `Foo.anglesite` with `Source/` (what `ingest` is given) and `Config/`.
    private static func package(disabled: Bool?) throws -> (package: URL, source: URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opt-\(UUID().uuidString).anglesite")
        let layout = AnglesitePackage(url: url)
        try FileManager.default.createDirectory(at: layout.sourceURL, withIntermediateDirectories: true)
        if let disabled {
            try SiteConfigStore.write(SiteSettings(imageOptimisationDisabled: disabled), to: layout.configURL)
        }
        return (url, layout.sourceURL)
    }

    private static func written(_ path: String, in source: URL) throws -> Data {
        try Data(contentsOf: WYSIWYGImageAssetIngestor.fileURL(forAssetPath: path, siteDirectory: source))
    }

    @Test("by default a TIFF drop is written as a JPEG and the log says what changed")
    func optimisesByDefault() async throws {
        let (package, source) = try Self.package(disabled: nil)
        defer { try? FileManager.default.removeItem(at: package) }
        let tiff = ImageOptimizerTests.encode(ImageOptimizerTests.image(width: 64, height: 48), type: .tiff)
        let logCenter = LogCenter()
        let subscription = await logCenter.subscribe()

        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: tiff, siteDirectory: source, logCenter: logCenter))
        #expect(path.hasSuffix(".jpg"))
        #expect(ImageOptimizerTests.type(of: try Self.written(path, in: source)) == UTType.jpeg.identifier)

        var iterator = subscription.stream.makeAsyncIterator()
        let line = await iterator.next()
        subscription.cancel()
        #expect(line?.source == WYSIWYGImageAssetIngestor.logSource)
        #expect(line?.text.hasPrefix("optimised dropped image: ") == true)
        #expect(line?.text.hasSuffix("(TIFF → JPEG)") == true)
    }

    @Test("with imageOptimisationDisabled the original bytes are written byte-for-byte")
    func optOutWritesOriginal() throws {
        let (package, source) = try Self.package(disabled: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let tiff = ImageOptimizerTests.encode(ImageOptimizerTests.image(width: 64, height: 48), type: .tiff)

        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: tiff, siteDirectory: source, logCenter: LogCenter()))
        #expect(path.hasSuffix(".tif"))
        #expect(try Self.written(path, in: source) == tiff)
    }

    @Test("an explicit false is the same as unset: optimisation on")
    func explicitFalseIsOn() throws {
        let (package, source) = try Self.package(disabled: false)
        defer { try? FileManager.default.removeItem(at: package) }
        let bmp = ImageOptimizerTests.encode(ImageOptimizerTests.image(width: 16, height: 16), type: .bmp)
        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: bmp, siteDirectory: source, logCenter: LogCenter()))
        #expect(!path.hasSuffix(".bmp"))
    }

    @Test("a recognised image that won't decode is written unchanged, with the failure logged")
    func undecodableKeepsOriginal() async throws {
        let (package, source) = try Self.package(disabled: nil)
        defer { try? FileManager.default.removeItem(at: package) }
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0])
        let logCenter = LogCenter()
        let subscription = await logCenter.subscribe()

        let path = try #require(try WYSIWYGImageAssetIngestor.ingest(bytes: truncated, siteDirectory: source, logCenter: logCenter))
        #expect(try Self.written(path, in: source) == truncated)

        var iterator = subscription.stream.makeAsyncIterator()
        let line = await iterator.next()
        subscription.cancel()
        #expect(line?.stream == .stderr)
        #expect(line?.text.hasPrefix("couldn't optimise dropped image") == true)
    }

    @Test("HEIC, AVIF, TIFF and BMP drops are recognised by their signatures")
    func sniffsNewFormats() {
        func ftyp(_ brand: String) -> Data { Data([0, 0, 0, 0x18]) + Data("ftyp\(brand)".utf8) }
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(ftyp("heic")) == .heic)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(ftyp("mif1")) == .heic)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(ftyp("avif"))?.preferredFilenameExtension == "avif")
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data([0x49, 0x49, 0x2A, 0x00])) == .tiff)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data([0x4D, 0x4D, 0x00, 0x2A])) == .tiff)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(Data("BM".utf8)) == .bmp)
        #expect(WYSIWYGImageAssetIngestor.sniffedUTType(ftyp("isom")) == nil)
    }
}
#endif
