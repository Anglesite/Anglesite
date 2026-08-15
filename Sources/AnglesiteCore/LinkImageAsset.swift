import Foundation

/// Where a captured link-post card image lands inside a site, and what counts as one (#1451).
///
/// The same `public/`-as-site-root convention `HeroImage`/`LogoAsset`/`WebsiteIconAsset` already
/// use — Astro serves `public/` verbatim, so a file written to `public/images/x.jpg` is served at
/// `/images/x.jpg` with no bundler import and no `<Image>` rewrite. `public/images/` specifically
/// because that is the directory `DeadAssetScanner` already treats as the site's image asset tree,
/// so a captured card image that later loses its entry shows up as a dead asset like any other.
///
/// Pure and filesystem-only: the network side lives in ``LinkPostImageCapture``.
public enum LinkImageAsset {
    /// Relative to the site `Source/` directory.
    public static let assetDirectoryRelativePath = "public/images"

    /// 5 MB. Open Graph card images are meant to be a few hundred KB; this is generous for a
    /// legitimate one and small enough that a hostile page can't make capture cost real memory.
    public static let maximumImageBytes = 5 * 1024 * 1024

    /// The image formats a captured card image may be in — determined by sniffing the bytes, never
    /// by the URL's extension or the response's `Content-Type`, both of which the remote page
    /// controls and neither of which has to match the payload.
    ///
    /// SVG is deliberately absent: an SVG is a script-execution vector, and this file is about to
    /// be served from the *owner's* origin, where a `<script>` inside it would run with the site's
    /// privileges. There is no safe way to serve an arbitrary remote SVG as first-party content,
    /// so an `og:image` that is one simply isn't captured.
    public enum Format: String, Sendable, Equatable {
        case jpeg, png, gif, webp, avif

        /// The filename extension used on disk (`.jpg` for JPEG, matching web convention).
        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .gif: return "gif"
            case .webp: return "webp"
            case .avif: return "avif"
            }
        }
    }

    /// The format `data` actually is, or nil when it isn't one of ``Format``'s.
    ///
    /// Magic-byte sniffing, so an HTML error page served with `Content-Type: image/jpeg` (or an
    /// SVG, or a renamed archive) is refused rather than written into the site.
    public static func format(sniffing data: Data) -> Format? {
        func matches(_ signature: [UInt8], at offset: Int) -> Bool {
            guard data.count >= offset + signature.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: signature.count)]) == signature
        }
        // FF D8 FF — the SOI marker plus the first byte of the following marker.
        if matches([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        // "GIF8" covers both 87a and 89a.
        if matches(Array("GIF8".utf8), at: 0) { return .gif }
        // RIFF container with a WEBP form type: "RIFF" <4-byte size> "WEBP".
        if matches(Array("RIFF".utf8), at: 0), matches(Array("WEBP".utf8), at: 8) { return .webp }
        // ISO-BMFF `ftyp` box whose major brand is AVIF (`avif` still images; `avis` sequences
        // are animated AVIF, which browsers render as an image too).
        if matches(Array("ftyp".utf8), at: 4),
           matches(Array("avif".utf8), at: 8) || matches(Array("avis".utf8), at: 8) {
            return .avif
        }
        return nil
    }

    /// The on-disk filename for the card image of the entry with `slug`.
    ///
    /// `link-` prefixed and slug-derived, so the file is recognizable next to its entry when the
    /// owner browses `public/images/` — and so re-capturing the same entry overwrites its image
    /// instead of accumulating one file per attempt.
    public static func fileName(slug: String, format: Format) -> String {
        "link-\(slug).\(format.fileExtension)"
    }

    /// Path of the installed image relative to the site `Source/` directory — what gets staged and
    /// committed.
    public static func assetRelativePath(slug: String, format: Format) -> String {
        "\(assetDirectoryRelativePath)/\(fileName(slug: slug, format: format))"
    }

    /// The root-relative URL the installed image is served at, and the value written to the
    /// entry's `image:` frontmatter field.
    public static func publicURLPath(slug: String, format: Format) -> String {
        "/images/\(fileName(slug: slug, format: format))"
    }

    /// Writes `bytes` into the site's `public/images/`, returning the path relative to
    /// `siteDirectory`. Overwrites a previous capture for the same slug (see
    /// ``fileName(slug:format:)``).
    /// - Throws: whatever `FileManager`/`Data.write` throws; the caller treats any failure as
    ///   "no card image" rather than a failed capture.
    @discardableResult
    public static func install(
        bytes: Data, format: Format, slug: String,
        siteDirectory: URL, fileManager: FileManager = .default
    ) throws -> String {
        let directory = siteDirectory.appendingPathComponent(assetDirectoryRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName(slug: slug, format: format))
        try bytes.write(to: destination, options: .atomic)
        return assetRelativePath(slug: slug, format: format)
    }
}

/// Why a card-image capture was refused. Every case is a guard firing on page-controlled input,
/// not a bug — callers log and continue without an image (#1451).
public enum LinkImageError: Error, Equatable, Sendable {
    /// The `og:image` resolved to something other than http(s) — or a redirect landed there.
    case unsupportedScheme
    /// A non-2xx response.
    case requestFailed(status: Int)
    /// The transfer exceeded ``LinkImageAsset/maximumImageBytes``.
    case responseTooLarge(Int)
    /// The bytes aren't a ``LinkImageAsset/Format`` — an HTML error page, an SVG, anything else.
    case unsupportedFormat
    /// The written entry has no frontmatter block, so there is nowhere to put `image:`. Only
    /// reachable if something outside the app rewrote the file between create and capture.
    case entryNotPatchable
}
