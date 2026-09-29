#if canImport(Darwin)
import Foundation
import ImageIO
import CoreGraphics

/// Drop-time image optimisation (#2019): converts formats browsers can't show (HEIC/HEIF, TIFF,
/// BMP) to JPEG or PNG, downscales anything past a longest-edge cap, and removes location
/// metadata — so a 12 MB HEIC dragged from Photos lands in `public/images/` as a web-ready JPEG.
///
/// Pure `Data`-in/`Data`-out, like ``LicenseMetadataEmbedder``: it never opens, reads, or writes
/// a file itself, so it can never be the thing that destroys an owner's original. It never
/// throws either — anything it can't handle is an ``Outcome`` the caller acts on.
///
/// **Location removal fails closed.** Every output is re-read and checked for GPS — both the
/// ImageIO GPS dictionary and XMP `exif:GPS…` tags — and an image whose location couldn't be
/// removed is ``Outcome/locationNotRemoved(_:)``, which tells the caller not to write the
/// original either. A web-ready image whose only problem is location data is first stripped
/// without re-encoding its pixels; only if that leaves a location behind (or the format has no
/// encoder, like WebP) is it re-encoded — as JPEG/PNG when the platform can't write its own
/// format, because keeping the owner's location private outranks keeping the file's format.
///
/// Other metadata: orientation is kept as metadata (pixels are never rotated); TIFF/IPTC
/// copyright and XMP — including a license ``LicenseMetadataEmbedder`` may have just written —
/// are carried across a re-encode. Encoder properties are an allow-list, so source-format
/// fields (a TIFF's compression, a HEIC container dictionary) never leak into the output.
///
/// There's no WebP output: the platform has no WebP encoder (`CGImageDestinationCopyTypeIdentifiers`
/// lists no `org.webmproject.webp` writer), so a location-free WebP or AVIF past the cap is left
/// as it is rather than re-encoded into a format the owner didn't choose.
public enum ImageOptimizer {
    /// Longest edge, in pixels, past which an image is downscaled.
    public static let defaultMaxPixelSize = 2000
    /// JPEG quality for every JPEG this writes.
    public static let jpegQuality = 0.82

    /// What happened to one image.
    public enum Outcome: Sendable, Equatable {
        /// Something changed; write ``Optimised/data`` with ``Optimised/fileExtension``.
        case optimised(Optimised)
        /// Already web-ready — no conversion, no downscale, no location data. Write the original.
        case unchanged
        /// Couldn't be decoded or re-encoded, and carries no location data we could see (the
        /// reason is owner-readable). The original may be written.
        case failed(String)
        /// The image carries location data that couldn't be removed. Don't write the original.
        case locationNotRemoved(String)
    }

    /// A changed image and what changed.
    public struct Optimised: Sendable, Equatable {
        /// The bytes to write.
        public let data: Data
        /// Extension for the written file, without the dot (`jpg`, `png`, …).
        public let fileExtension: String
        /// Each change applied, in the order ``summary`` lists them.
        public let changes: [Change]

        /// One-line description for the debug pane, e.g. `HEIC → JPEG, 4032×3024 → 2000×1500,
        /// location removed`.
        public var summary: String {
            changes.map { change in
                switch change {
                case .converted(let from, let to): "\(from) → \(to)"
                case .downscaled(let fromWidth, let fromHeight, let toWidth, let toHeight):
                    "\(fromWidth)×\(fromHeight) → \(toWidth)×\(toHeight)"
                case .removedLocation: "location removed"
                }
            }.joined(separator: ", ")
        }
    }

    /// One change ``optimise(_:maxPixelSize:)`` applied.
    public enum Change: Sendable, Equatable {
        /// Re-encoded from one format to another (display names, e.g. `HEIC`, `JPEG`).
        case converted(from: String, to: String)
        /// Resized so the longest edge is the cap, aspect ratio preserved.
        case downscaled(fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int)
        /// GPS metadata removed.
        case removedLocation
    }

    /// Source types always converted to JPEG/PNG, with their display names.
    static let convertedTypes: [String: String] = [
        "public.heic": "HEIC",
        "public.heif": "HEIF",
        "public.tiff": "TIFF",
        "com.microsoft.bmp": "BMP",
    ]

    private static let jpegType = "public.jpeg"
    private static let pngType = "public.png"
    private static let gifType = "com.compuserve.gif"
    private static let displayNames: [String: String] = [
        jpegType: "JPEG", pngType: "PNG", gifType: "GIF",
        "org.webmproject.webp": "WebP", "public.avif": "AVIF",
    ]
    private static let fileExtensions: [String: String] = [jpegType: "jpg", pngType: "png", gifType: "gif"]

    /// TIFF-dictionary fields carried into a re-encode — descriptive fields only, never the
    /// source's own encoding (compression, photometric interpretation, strip layout, …).
    private static let keptTIFFKeys: Set<CFString> = [
        kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFImageDescription,
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFDateTime,
    ]

    /// Optimises `data`. See the type's doc for the rules.
    ///
    /// - Parameters:
    ///   - data: The image bytes, as dropped.
    ///   - maxPixelSize: Longest edge past which the image is downscaled; never upscales.
    public static func optimise(_ data: Data, maxPixelSize: Int = defaultMaxPixelSize) -> Outcome {
        optimise(data, maxPixelSize: maxPixelSize, writableTypes: nil)
    }

    /// `writableTypes` overrides the platform's encoder list, so tests can reach the "no encoder
    /// for this format" path (WebP/AVIF in production) with fixtures ImageIO can write.
    static func optimise(_ data: Data, maxPixelSize: Int, writableTypes: Set<String>?) -> Outcome {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return .failed("the image couldn’t be read")
        }

        let hasLocation = containsLocation(source)
        let writable = writableTypes ?? Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        // Animated GIFs would lose every frame but the first in a re-encode.
        let canReencodeInPlace = writable.contains(sourceType) && CGImageSourceGetCount(source) == 1
        let convertFrom = convertedTypes[sourceType]
        let needsDownscale = max(width, height) > maxPixelSize && (convertFrom != nil || canReencodeInPlace)

        if convertFrom == nil && !needsDownscale {
            guard hasLocation else { return .unchanged }
            // Strip without touching the pixels; re-encode below only if that didn't work.
            let orientation = properties[kCGImagePropertyOrientation] as? Int
            if canReencodeInPlace, let stripped = copyWithoutLocation(source, orientation: orientation),
               !containsLocation(stripped), self.orientation(of: stripped) == orientation {
                return .optimised(Optimised(
                    data: stripped, fileExtension: fileExtension(for: sourceType), changes: [.removedLocation]))
            }
        }

        let failure: (String) -> Outcome = { hasLocation ? .locationNotRemoved($0) : .failed($0) }

        // Decode, downscaling in the decoder where needed. The transform stays off: orientation
        // travels as metadata, so a portrait photo is still portrait without rotating pixels.
        let image: CGImage?
        if needsDownscale {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return failure("the image couldn’t be decoded") }

        // Keep the format when it's already web-ready and writable; otherwise JPEG, or PNG when
        // there's transparency to keep.
        let outputType = convertFrom == nil && canReencodeInPlace
            ? sourceType
            : (hasAlpha(image) ? pngType : jpegType)

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType as CFString, 1, nil) else {
            return failure("the image couldn’t be re-encoded")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap(metadataForReencode)
        CGImageDestinationAddImageAndMetadata(
            destination, image, metadata, encodingProperties(from: properties, outputType: outputType) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return failure("the image couldn’t be re-encoded") }
        let encoded = output as Data
        if hasLocation && containsLocation(encoded) {
            return .locationNotRemoved("location data survived re-encoding")
        }

        var changes: [Change] = []
        if outputType != sourceType {
            let from = convertFrom ?? displayName(for: sourceType)
            changes.append(.converted(from: from, to: displayName(for: outputType)))
        }
        if needsDownscale {
            changes.append(.downscaled(fromWidth: width, fromHeight: height, toWidth: image.width, toHeight: image.height))
        }
        if hasLocation { changes.append(.removedLocation) }
        return .optimised(Optimised(data: encoded, fileExtension: fileExtension(for: outputType), changes: changes))
    }

    /// Whether `data` carries location data (a GPS dictionary or XMP `exif:GPS…` tags).
    static func containsLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return containsLocation(source)
    }

    /// Whether the first image in `source` has a GPS dictionary or any XMP `exif:GPS…` tag.
    private static func containsLocation(_ source: CGImageSource) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if properties?[kCGImagePropertyGPSDictionary] != nil { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
        return !gpsTagPaths(in: metadata).isEmpty
    }

    /// A lossless copy of `source` with GPS excluded, or `nil` when ImageIO refuses. Excluding
    /// GPS can also drop the orientation, so it's passed back in explicitly; the caller still
    /// checks it survived and re-encodes otherwise.
    private static func copyWithoutLocation(_ source: CGImageSource, orientation: Int?) -> Data? {
        guard let type = CGImageSourceGetType(source) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let orientation { options[kCGImageDestinationOrientation] = orientation }
        var error: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
        return copied ? output as Data : nil
    }

    /// The EXIF orientation of the first image in `data`, if it declares one.
    private static func orientation(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? Int
    }

    /// Top-level XMP tag paths naming a GPS field (`exif:GPSLatitude`, …).
    private static func gpsTagPaths(in metadata: CGImageMetadata) -> [String] {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            let name = (path as String).split(separator: ":").last.map(String.init) ?? ""
            if name.hasPrefix("GPS") { paths.append(path as String) }
            return true
        }
        return paths
    }

    /// XMP mirrors of the source's own encoding and dimensions — stale or wrong once re-encoded.
    private static let encodingTagPaths = [
        "tiff:Compression", "tiff:PhotometricInterpretation", "tiff:BitsPerSample", "tiff:SamplesPerPixel",
        "tiff:PlanarConfiguration", "tiff:ImageWidth", "tiff:ImageLength",
        "exif:PixelXDimension", "exif:PixelYDimension",
    ]

    /// A copy of `metadata` for a re-encode: every GPS tag removed (the XMP mirror of the GPS
    /// dictionary, which would otherwise carry the location across) and the source's encoding
    /// fields dropped — the metadata counterpart of ``encodingProperties(from:outputType:)``.
    private static func metadataForReencode(_ metadata: CGImageMetadata) -> CGImageMetadata? {
        guard let mutable = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        for path in gpsTagPaths(in: metadata) + encodingTagPaths {
            _ = CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString)
        }
        return mutable
    }

    /// The encoder properties for a re-encode: an allow-list of what's meant to survive —
    /// orientation, descriptive TIFF fields, IPTC, Exif minus its (now stale) pixel dimensions —
    /// plus JPEG quality. Never GPS; never the source format's own encoding fields.
    private static func encodingProperties(from properties: [CFString: Any], outputType: String) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] {
            kept[kCGImagePropertyOrientation] = orientation
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let descriptive = tiff.filter { keptTIFFKeys.contains($0.key) }
            if !descriptive.isEmpty { kept[kCGImagePropertyTIFFDictionary] = descriptive }
        }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] {
            kept[kCGImagePropertyIPTCDictionary] = iptc
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if outputType == jpegType {
            kept[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        return kept
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func displayName(for type: String) -> String {
        displayNames[type] ?? convertedTypes[type] ?? (type.split(separator: ".").last.map { $0.uppercased() } ?? type)
    }

    private static func fileExtension(for type: String) -> String {
        fileExtensions[type] ?? displayName(for: type).lowercased()
    }
}
#endif
