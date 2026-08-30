import Foundation
import UniformTypeIdentifiers

/// Writes a Finder/Photos-dragged image's raw bytes into the site's `public/images/` (design doc
/// §4: "Finder/Photos drag-in → asset ingestion + image block in one gesture"), returning the
/// root-relative URL path an inserted image block's `src` prop should use. Sniffs the format from
/// magic bytes rather than trusting a claimed extension/UTI — same reasoning and byte-signature
/// table as `LinkImageAsset.format(sniffing:)`, which this type deliberately doesn't reuse (that
/// type's `install` is keyed to a link-post `slug` identity that doesn't fit an arbitrary canvas
/// drop).
public enum WYSIWYGImageAssetIngestor {
    enum Format: String {
        case jpeg, png, gif, webp

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .gif: "gif"
            case .webp: "webp"
            }
        }

        /// `nil` only if the system UTI database can't resolve `"webp"`, which doesn't happen on
        /// any supported macOS version — jpeg/png/gif always resolve via their standard `UTType`.
        var utType: UTType? {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .gif: .gif
            case .webp: UTType(filenameExtension: fileExtension)
            }
        }
    }

    /// `LogCenter` source string for the WYSIWYG drop pipeline — shared with the app-side
    /// `WYSIWYGImageDropHandler` so one drop's whole story reads as a single run in the debug pane.
    public static let logSource = "wysiwyg-drop"

    /// The dropped bytes' sniffed image format as a `UTType`, or `nil` for unrecognized bytes.
    ///
    /// A drop has no filename/extension to derive a `UTType` from the way `Insert ▸ Image…`'s
    /// `NSOpenPanel` selection does (a Photos drag in particular has no file URL at all), so a
    /// caller that needs a `UTType` — e.g. to pass to `LicenseMetadataEmbedder.embed(_:into:type:)`
    /// before calling ``ingest(bytes:siteDirectory:fileManager:logCenter:)`` — sniffs it here
    /// first, ahead of and independent from `ingest`'s own internal sniff.
    /// - Parameter bytes: The dropped image bytes.
    /// - Returns: The sniffed format's `UTType`, or `nil` when the bytes match no known image
    ///   signature.
    public static func sniffedUTType(_ bytes: Data) -> UTType? {
        sniff(bytes)?.utType
    }

    /// Returns `nil` for unrecognized bytes — callers treat that as "not a droppable image,
    /// ignore the drop" rather than a thrown error. That `nil` is logged to `logCenter` first (the
    /// plan's Global Constraints: "no silent failure paths"), via a detached `Task` because this
    /// stays a synchronous API — the same shape `LocalContainerSiteRuntime` uses to log from its
    /// non-async stream callbacks.
    /// - Throws: whatever `FileManager`/`Data.write` throws for a recognized image that fails to
    ///   write.
    public static func ingest(
        bytes: Data, siteDirectory: URL, fileManager: FileManager = .default, logCenter: LogCenter = .shared
    ) throws -> String? {
        guard let format = sniff(bytes) else {
            Task {
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "dropped \(bytes.count) bytes matched no known image signature (jpeg/png/gif/webp) — ignoring drop")
            }
            return nil
        }
        let directory = siteDirectory.appendingPathComponent("public/images", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "wysiwyg-\(UUID().uuidString.prefix(8)).\(format.fileExtension)"
        let destination = directory.appendingPathComponent(name)
        try bytes.write(to: destination, options: .atomic)
        return "/images/\(name)"
    }

    private static func sniff(_ data: Data) -> Format? {
        func matches(_ signature: [UInt8], at offset: Int) -> Bool {
            guard data.count >= offset + signature.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: signature.count)]) == signature
        }
        if matches([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        if matches(Array("GIF8".utf8), at: 0) { return .gif }
        if matches(Array("RIFF".utf8), at: 0), matches(Array("WEBP".utf8), at: 8) { return .webp }
        return nil
    }
}
