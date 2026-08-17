#if canImport(Darwin)
import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import PDFKit

/// Embeds a chosen license into a media file's own metadata (#999), so the license survives the
/// file being downloaded or shared away from the page that originally stated it.
///
/// Pure `Data`-in/`Data`-out by design: this type never opens, reads, or writes a file on disk
/// itself, and never mutates a caller-supplied file in place. Embedding a license is a
/// destructive edit to a binary the caller may have no backup of — pushing "what happens to the
/// result" onto the caller (write to a copy, use in a data URL, discard) means this utility can
/// never be the thing that destroys a user's original file.
///
/// Only formats with a real metadata slot are written to; everything else is `.unsupported`
/// rather than silently skipped or thrown, per the issue's explicit requirement. Video and audio
/// are `.unsupported` in this version — see the plan doc's Global Constraints for why.
public enum LicenseMetadataEmbedder {
    /// One embed attempt's outcome.
    public enum Result: Sendable, Equatable {
        /// `type` has a metadata slot Anglesite can write to, and it now holds `license`.
        case embedded(Data)
        /// `type` has no metadata slot this embedder writes to (or isn't attempted yet, like
        /// audio/video) — `data` is returned untouched by the caller, not by this type.
        case unsupported
    }

    /// Why an attempt on a *supported* type still failed. Never thrown for a genuinely
    /// unsupported format — that's `Result.unsupported`, not an error.
    public enum EmbedError: Error, Equatable {
        /// `data` couldn't be decoded as the format `type` claims it is.
        case unreadable
        /// The underlying framework refused to produce output bytes.
        case writeFailed
    }

    /// Attempts to embed `license` into `data`, read as `type`.
    ///
    /// - Throws: ``EmbedError`` only when `type` is one of ``supportedTypes`` but the write
    ///   itself failed (malformed input, encoder refusal). A `type` outside ``supportedTypes``
    ///   always returns `.unsupported` and never throws.
    public static func embed(_ license: LicenseRef, into data: Data, type: UTType) throws -> Result {
        guard supportedTypes.contains(type) else { return .unsupported }
        if imageTypes.contains(type) {
            return .embedded(try embedIntoImage(license, data: data, type: type))
        }
        if type == .pdf {
            return .embedded(try embedIntoPDF(license, data: data))
        }
        return .unsupported
    }

    /// UTTypes this embedder can write a license into today.
    public static let supportedTypes: Set<UTType> = imageTypes.union([.pdf])

    private static let imageTypes: Set<UTType> = [.jpeg, .png, .tiff, .heic]

    private static func embedIntoImage(_ license: LicenseRef, data: Data, type: UTType) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EmbedError.unreadable
        }

        let existingProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let existingMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let metadata = existingMetadata.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()

        let xmpRightsNamespace = "http://ns.adobe.com/xap/1.0/rights/" as CFString
        // Registration can no-op (return false) when the namespace is already present in a
        // metadata copy carried over from `existingMetadata` — that's fine, not a failure.
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, xmpRightsNamespace, "xmpRights" as CFString, nil)

        guard
            let webStatementTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "WebStatement" as CFString, .string,
                license.url as CFTypeRef),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString, webStatementTag),
            let usageTermsTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "UsageTerms" as CFString, .string,
                license.name as CFTypeRef),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:UsageTerms" as CFString, usageTermsTag),
            let markedTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "Marked" as CFString, .string, kCFBooleanTrue),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:Marked" as CFString, markedTag)
        else {
            throw EmbedError.writeFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw EmbedError.writeFailed
        }
        var options = existingProperties
        options[kCGImageDestinationMergeMetadata] = true
        CGImageDestinationAddImageAndMetadata(destination, cgImage, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EmbedError.writeFailed }
        return output as Data
    }

    private static func embedIntoPDF(_ license: LicenseRef, data: Data) throws -> Data {
        guard let document = PDFDocument(data: data) else { throw EmbedError.unreadable }
        var attributes = document.documentAttributes ?? [:]
        attributes["Rights"] = "\(license.name) — \(license.url)"
        document.documentAttributes = attributes
        guard let output = document.dataRepresentation() else { throw EmbedError.writeFailed }
        return output
    }
}
#endif
