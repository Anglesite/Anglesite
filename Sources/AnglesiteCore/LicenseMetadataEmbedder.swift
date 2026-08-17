#if canImport(Darwin)
import Foundation
import UniformTypeIdentifiers

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
        throw EmbedError.unreadable // placeholder body — replaced in Task 2
    }

    private static func embedIntoPDF(_ license: LicenseRef, data: Data) throws -> Data {
        throw EmbedError.unreadable // placeholder body — replaced in Task 3
    }
}
#endif
