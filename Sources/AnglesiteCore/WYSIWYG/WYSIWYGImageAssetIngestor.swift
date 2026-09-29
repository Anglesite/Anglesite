import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Writes a Finder/Photos-dragged image's raw bytes into the site's `public/images/` (design doc
/// §4: "Finder/Photos drag-in → asset ingestion + image block in one gesture"), returning the
/// root-relative URL path an inserted image block's `src` prop should use. Sniffs the format from
/// magic bytes rather than trusting a claimed extension/UTI — same reasoning and byte-signature
/// table as `LinkImageAsset.format(sniffing:)`, which this type deliberately doesn't reuse (that
/// type's `install` is keyed to a link-post `slug` identity that doesn't fit an arbitrary canvas
/// drop).
///
/// On Darwin, the bytes go through ``ImageOptimizer`` before they're written (#2019) — HEIC/TIFF/
/// BMP become JPEG or PNG, anything past the size cap is downscaled, location data is removed —
/// unless the site opted out with `SiteSettings.imageOptimisationDisabled`. A failed optimisation
/// writes the original bytes when browsers can show them and they carry no location data;
/// otherwise the drop is refused and the reason logged, rather than publishing a broken image or
/// the owner's location.
public enum WYSIWYGImageAssetIngestor {
    enum Format: String {
        case jpeg, png, gif, webp, avif, heic, tiff, bmp

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .gif: "gif"
            case .webp: "webp"
            case .avif: "avif"
            case .heic: "heic"
            case .tiff: "tiff"
            case .bmp: "bmp"
            }
        }

        /// Whether browsers display this format. The others (HEIC, TIFF, BMP) are only written
        /// once converted, or as-is when the owner turned optimisation off.
        var isWebFormat: Bool {
            switch self {
            case .jpeg, .png, .gif, .webp, .avif: true
            case .heic, .tiff, .bmp: false
            }
        }

        #if canImport(UniformTypeIdentifiers)
        /// `nil` only if the system UTI database can't resolve `"webp"`/`"avif"`, which doesn't
        /// happen on any supported macOS version — the rest resolve via their standard `UTType`.
        var utType: UTType? {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .gif: .gif
            case .webp, .avif: UTType(filenameExtension: fileExtension)
            case .heic: .heic
            case .tiff: .tiff
            case .bmp: .bmp
            }
        }
        #endif
    }

    /// `LogCenter` source string for the WYSIWYG drop pipeline — shared with the app-side
    /// `WYSIWYGImageDropHandler` so one drop's whole story reads as a single run in the debug pane.
    public static let logSource = "wysiwyg-drop"

    #if canImport(UniformTypeIdentifiers)
    /// The dropped bytes' sniffed image format as a `UTType`, or `nil` for unrecognized bytes.
    ///
    /// A drop has no filename/extension to derive a `UTType` from the way `Insert ▸ Image…`'s
    /// `NSOpenPanel` selection does (a Photos drag in particular has no file URL at all), so a
    /// caller that needs a `UTType` — e.g. to pass to `LicenseMetadataEmbedder.embed(_:into:type:)`
    /// before calling ``ingest(bytes:siteDirectory:fileManager:logCenter:)`` — sniffs it here
    /// first, ahead of and independent from `ingest`'s own internal sniff. `UniformTypeIdentifiers`
    /// is Darwin-only, so this is unavailable on the portable (Linux) build of `AnglesiteCore`.
    /// - Parameter bytes: The dropped image bytes.
    /// - Returns: The sniffed format's `UTType`, or `nil` when the bytes match no known image
    ///   signature.
    public static func sniffedUTType(_ bytes: Data) -> UTType? {
        sniff(bytes)?.utType
    }
    #endif

    /// Returns `nil` for unrecognized bytes — callers treat that as "not a droppable image,
    /// ignore the drop" rather than a thrown error — and for an image it refuses to publish (a
    /// format browsers can't show that couldn't be converted, or location data that couldn't be
    /// removed). Every `nil` is logged to `logCenter` first (the plan's Global Constraints: "no
    /// silent failure paths"), via a detached `Task` because this stays a synchronous API — the
    /// same shape `LocalContainerSiteRuntime` uses to log from its non-async stream callbacks.
    ///
    /// - Important: Synchronous and potentially slow — it reads `Config/settings.plist` and can
    ///   decode and re-encode a multi-megabyte photo. Call it off the main actor (e.g. from
    ///   `Task.detached`), never from a view's `@MainActor` context.
    /// - Throws: whatever `FileManager`/`Data.write` throws for a recognized image that fails to
    ///   write.
    public static func ingest(
        bytes: Data, siteDirectory: URL, fileManager: FileManager = .default, logCenter: LogCenter = .shared
    ) throws -> String? {
        guard let format = sniff(bytes) else {
            Task {
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "dropped \(bytes.count) bytes matched no known image signature (jpeg/png/gif/webp/avif/heic/tiff/bmp) — ignoring drop")
            }
            return nil
        }
        #if canImport(Darwin)
        guard let prepared = prepare(
            bytes, format: format, siteDirectory: siteDirectory, fileManager: fileManager, logCenter: logCenter)
        else { return nil }
        let (output, fileExtension) = prepared
        #else
        guard format.isWebFormat else {
            log(
                "dropped \(format.rawValue.uppercased()) image can't be shown in browsers and can't be converted on this platform — ignoring drop",
                stream: .stderr, to: logCenter)
            return nil
        }
        let (output, fileExtension) = (bytes, format.fileExtension)
        #endif
        let directory = siteDirectory.appendingPathComponent("public/images", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "wysiwyg-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let destination = directory.appendingPathComponent(name)
        try output.write(to: destination, options: .atomic)
        return "/images/\(name)"
    }

    #if canImport(Darwin)
    /// Decides what to write for a recognised drop: the optimised bytes, the original, or nothing
    /// (`nil`, logged). Runs ``ImageOptimizer`` unless the site opted out.
    ///
    /// Reads the opt-out from the package's `Config/` — only when `siteDirectory` really is a
    /// package's `Source/` (`Foo.anglesite/Source`); any other directory reads as "on" rather than
    /// trusting an unrelated parent's `Config/`.
    private static func prepare(
        _ bytes: Data, format: Format, siteDirectory: URL, fileManager: FileManager, logCenter: LogCenter
    ) -> (Data, String)? {
        let original = (bytes, format.fileExtension)
        let kind = format.rawValue.uppercased()
        if optimisationDisabled(siteDirectory: siteDirectory, fileManager: fileManager) {
            log(
                "image optimisation is off for this site — keeping the dropped image as it is"
                    + (format.isWebFormat ? "" : " (\(kind) images don't show in most browsers)"),
                stream: format.isWebFormat ? .stdout : .stderr, to: logCenter)
            return original
        }
        switch ImageOptimizer.optimise(bytes) {
        case .optimised(let optimised):
            let before = ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)
            let after = ByteCountFormatter.string(fromByteCount: Int64(optimised.data.count), countStyle: .file)
            log("optimised dropped image: \(before) → \(after) (\(optimised.summary))", stream: .stdout, to: logCenter)
            return (optimised.data, optimised.fileExtension)
        case .unchanged:
            return original
        case .failed(let reason):
            guard format.isWebFormat else {
                log("couldn't convert dropped \(kind) image (\(reason)), and browsers can't show it as it is — ignoring drop",
                    stream: .stderr, to: logCenter)
                return nil
            }
            log("couldn't optimise dropped image (\(reason)) — keeping the original", stream: .stderr, to: logCenter)
            return original
        case .locationNotRemoved(let reason):
            log("dropped image carries location data that couldn't be removed (\(reason)) — ignoring drop so the location isn't published",
                stream: .stderr, to: logCenter)
            return nil
        }
    }

    /// `SiteSettings.imageOptimisationDisabled` for the package whose `Source/` is `siteDirectory`.
    private static func optimisationDisabled(siteDirectory: URL, fileManager: FileManager) -> Bool {
        let packageURL = siteDirectory.deletingLastPathComponent()
        guard siteDirectory.lastPathComponent == "Source", packageURL.pathExtension == "anglesite" else { return false }
        let configDirectory = AnglesitePackage(url: packageURL).configURL
        let settings = (try? SiteConfigStore.read(from: configDirectory, fileManager: fileManager)) ?? SiteSettings()
        return settings.imageOptimisationDisabled == true
    }
    #endif

    /// Fire-and-forget log line — `ingest` stays synchronous (see its doc comment).
    private static func log(_ text: String, stream: LogCenter.Stream, to logCenter: LogCenter) {
        Task { await logCenter.append(source: logSource, stream: stream, text: text) }
    }

    /// Resolves an `ingest(bytes:siteDirectory:)`-returned root-relative asset path (e.g.
    /// `/images/wysiwyg-abcd1234.jpg`) back to the on-disk file under `public/` — the inverse of
    /// the `public/images/<name>` convention `ingest` itself writes to. Used by callers (alt-text
    /// proposals, #1227) that need a real file URL for the just-ingested image rather than the
    /// root-relative path the canvas stores in the block's `src` prop.
    public static func fileURL(forAssetPath assetPath: String, siteDirectory: URL) -> URL {
        let relative = assetPath.hasPrefix("/") ? String(assetPath.dropFirst()) : assetPath
        return siteDirectory
            .appendingPathComponent("public", isDirectory: true)
            .appendingPathComponent(relative)
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
        // ISO-BMFF (HEIF family): an `ftyp` box whose major or compatible brands name the format.
        // The box is size(4) "ftyp" major(4) minor-version(4) compatible(4 each) up to its size.
        if matches(Array("ftyp".utf8), at: 4) {
            let declared = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            let boxEnd = min(max(declared, 16), data.count, 256)
            let brandOffsets = [8] + Array(stride(from: 16, to: boxEnd - 3, by: 4))
            func hasBrand(_ brands: [String]) -> Bool {
                brandOffsets.contains { offset in brands.contains { matches(Array($0.utf8), at: offset) } }
            }
            if hasBrand(["avif", "avis"]) { return .avif }
            if hasBrand(["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]) { return .heic }
        }
        if matches([0x49, 0x49, 0x2A, 0x00], at: 0) || matches([0x4D, 0x4D, 0x00, 0x2A], at: 0) { return .tiff }
        if matches(Array("BM".utf8), at: 0) { return .bmp }
        return nil
    }
}
