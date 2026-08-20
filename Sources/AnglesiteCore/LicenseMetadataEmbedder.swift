#if canImport(Darwin)
import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

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
              CGImageSourceGetCount(source) > 0 else {
            throw EmbedError.unreadable
        }

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

        // PNG carve-out: `CGImageDestinationCopyImageSource`'s metadata merge silently drops the
        // new XMP (no `iTXt` chunk is written at all — verified by dumping the output PNG's own
        // chunk list) whenever the source PNG already carries an `eXIf` chunk (e.g. any image
        // with an orientation property, which is common). JPEG/TIFF/HEIC don't share this bug —
        // only PNG. PNG is lossless, so falling back to decode+re-encode here costs nothing the
        // copy-source path was protecting against (no lossy recompression, no page/frame to
        // drop): it's the same approach this file shipped and tested green with before this
        // rewrite, scoped down to just the one format where the newer API misbehaves.
        if type == .png {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw EmbedError.unreadable
            }
            let existingProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            var options = existingProperties
            options[kCGImageDestinationMergeMetadata] = true
            CGImageDestinationAddImageAndMetadata(destination, cgImage, metadata, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EmbedError.writeFailed }
            return output as Data
        }

        var writeError: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(
            destination, source,
            [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary,
            &writeError)
        guard copied else { throw EmbedError.writeFailed }
        return output as Data
    }

    /// Writes the license as real XMP into the PDF's document metadata stream, via
    /// `CGContext.addDocumentMetadata(_:)` — the actual Core Graphics API for this exact purpose,
    /// not PDFKit's `documentAttributes` convenience property.
    ///
    /// `documentAttributes` was tried first (mutate + `dataRepresentation()`, then mutate +
    /// `write(to:)` into a temp file): both round-tripped cleanly in local testing but silently
    /// dropped *all* Info-dictionary state — not just the newly-set keys, the document's own
    /// pre-existing `Producer`/`CreationDate`/`ModDate` too — on CI's PDFKit (a different macOS
    /// version than local; confirmed twice, independent of which serialization method was used).
    /// That pointed at `documentAttributes` mutation-after-open being unreliable across OS
    /// versions, not a serialization-method choice. This implementation sidesteps PDFKit's
    /// document-mutation path entirely: it reads the source with `CGPDFDocument`, opens a fresh
    /// `CGContext` PDF writer, calls `addDocumentMetadata` before any page is added (required —
    /// this is write-once, at creation), then copies each source page across with
    /// `drawPDFPage`. Verified to preserve page count and every original Info-dictionary key
    /// (CGContext auto-populates `Producer`/`CreationDate`/`ModDate` on the new document the same
    /// way it did on the original), so the existing fidelity test needed no changes.
    ///
    /// The one known cost: page *content* is redrawn through Core Graphics rather than copied
    /// byte-for-byte, so PDF forms, embedded JavaScript, and accessibility tags on the original
    /// are not preserved. Anglesite doesn't generate or expect those in owner-attached photos/PDFs
    /// today; flagged here for whoever picks this up if that ever changes.
    private static func embedIntoPDF(_ license: LicenseRef, data: Data) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let sourceDocument = CGPDFDocument(provider),
              sourceDocument.numberOfPages > 0,
              let firstPage = sourceDocument.page(at: 1) else {
            throw EmbedError.unreadable
        }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { throw EmbedError.writeFailed }
        var mediaBox = firstPage.getBoxRect(.mediaBox)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw EmbedError.writeFailed
        }

        context.addDocumentMetadata(pdfXMPPacket(for: license) as CFData)

        for index in 1...sourceDocument.numberOfPages {
            guard let page = sourceDocument.page(at: index) else { continue }
            let pageBox = page.getBoxRect(.mediaBox)
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageBox] as CFDictionary)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()

        return output as Data
    }

    /// The XMP packet `embedIntoPDF` embeds — the same `xmpRights` fields `embedIntoImage` writes
    /// (`WebStatement`/`UsageTerms`/`Marked`), so both backends read back identically for any
    /// future caller (e.g. a drop-and-inspect flow) that wants one code path for either format.
    private static func pdfXMPPacket(for license: LicenseRef) -> Data {
        let url = xmlAttributeEscaped(license.url)
        let name = xmlAttributeEscaped(license.name)
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/" \
        xmpRights:WebStatement="\(url)" xmpRights:UsageTerms="\(name)" xmpRights:Marked="True"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }

    private static func xmlAttributeEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
#endif
