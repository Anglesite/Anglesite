#if canImport(Darwin)
import Foundation
import ImageIO
import CoreGraphics

/// Drop-time image optimisation (#2019): converts formats browsers can't show (HEIC/HEIF, TIFF,
/// BMP) to JPEG or PNG, downscales anything past a longest-edge cap, and removes location
/// metadata — so a 12 MB HEIC dragged from Photos lands in `public/images/` as a web-ready JPEG.
///
/// Pure `Data`-in/`Data`-out, like ``LicenseMetadataEmbedder``: it never opens, reads, or writes
/// a file itself, so it can never be the thing that destroys an owner's original. It never throws
/// either — anything it can't handle is ``Outcome/failed(_:)`` and the caller keeps the original
/// bytes, because a drop must never be lost to the optimiser.
///
/// Metadata: GPS is removed; orientation is kept as metadata (pixels are never rotated) and the
/// TIFF/IPTC/XMP fields — copyright, and the license ``LicenseMetadataEmbedder`` may have just
/// written — are carried across a re-encode.
///
/// There's no WebP output: the platform has no WebP encoder (`CGImageDestinationCopyTypeIdentifiers`
/// lists no `org.webmproject.webp` writer), so a WebP or AVIF past the cap is left as it is rather
/// than re-encoded into a different format the owner didn't choose.
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
        /// Couldn't be decoded or re-encoded (the reason is owner-readable). Write the original.
        case failed(String)
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

    /// Source types converted to JPEG/PNG, with their display names.
    static let convertedTypes: [String: String] = [
        "public.heic": "HEIC",
        "public.heif": "HEIF",
        "public.tiff": "TIFF",
        "com.microsoft.bmp": "BMP",
    ]

    private static let jpegType = "public.jpeg"
    private static let pngType = "public.png"
    private static let displayNames: [String: String] = [
        jpegType: "JPEG", pngType: "PNG", "com.compuserve.gif": "GIF",
    ]
    private static let fileExtensions: [String: String] = [
        jpegType: "jpg", pngType: "png", "com.compuserve.gif": "gif",
    ]

    /// Optimises `data`. See the type's doc for the rules.
    ///
    /// - Parameters:
    ///   - data: The image bytes, as dropped.
    ///   - maxPixelSize: Longest edge past which the image is downscaled; never upscales.
    public static func optimise(_ data: Data, maxPixelSize: Int = defaultMaxPixelSize) -> Outcome {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return .failed("the image couldn’t be read")
        }

        let hasLocation = properties[kCGImagePropertyGPSDictionary] != nil
        let convertFrom = convertedTypes[sourceType]
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        // Animated GIFs would lose every frame but the first in a re-encode; leave them be.
        let animated = CGImageSourceGetCount(source) > 1
        let needsDownscale = max(width, height) > maxPixelSize
            && (convertFrom != nil || (writable.contains(sourceType) && !animated))

        if convertFrom == nil && !needsDownscale {
            return hasLocation ? removeLocationLosslessly(source: source, type: sourceType) : .unchanged
        }

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
        guard let image else { return .failed("the image couldn’t be decoded") }

        let outputType: String
        if convertFrom != nil {
            outputType = hasAlpha(image) ? pngType : jpegType
        } else {
            outputType = sourceType
        }

        var options = properties
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] {
            options.removeValue(forKey: key)
        }
        // Stale once resized; the encoder writes the real dimensions.
        if var exif = options[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            options[kCGImagePropertyExifDictionary] = exif
        }
        if outputType == jpegType {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        options[kCGImageDestinationMergeMetadata] = true

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType as CFString, 1, nil) else {
            return .failed("the image couldn’t be re-encoded")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap(metadataWithoutLocation)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return .failed("the image couldn’t be re-encoded")
        }

        var changes: [Change] = []
        if let convertFrom {
            changes.append(.converted(from: convertFrom, to: displayNames[outputType] ?? outputType))
        }
        if needsDownscale {
            changes.append(.downscaled(fromWidth: width, fromHeight: height, toWidth: image.width, toHeight: image.height))
        }
        if hasLocation { changes.append(.removedLocation) }
        return .optimised(Optimised(
            data: output as Data, fileExtension: fileExtension(for: outputType), changes: changes))
    }

    /// Strips GPS from an image that needs nothing else, without re-encoding the pixels.
    private static func removeLocationLosslessly(source: CGImageSource, type: String) -> Outcome {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            return .failed("location data couldn’t be removed from this image type")
        }
        var error: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(
            destination, source, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, &error)
        guard copied else { return .failed("location data couldn’t be removed") }
        return .optimised(Optimised(
            data: output as Data, fileExtension: fileExtension(for: type), changes: [.removedLocation]))
    }

    /// A copy of `metadata` with every `exif:GPS…` tag removed — the XMP mirror of the GPS
    /// dictionary, which would otherwise carry the location across a re-encode.
    private static func metadataWithoutLocation(_ metadata: CGImageMetadata) -> CGImageMetadata? {
        guard let mutable = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        var gpsPaths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            let name = (path as String).split(separator: ":").last.map(String.init) ?? ""
            if name.hasPrefix("GPS") { gpsPaths.append(path as String) }
            return true
        }
        for path in gpsPaths {
            _ = CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString)
        }
        return mutable
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func fileExtension(for type: String) -> String {
        if let known = fileExtensions[type] { return known }
        return convertedTypes[type]?.lowercased() ?? "img"
    }
}
#endif
