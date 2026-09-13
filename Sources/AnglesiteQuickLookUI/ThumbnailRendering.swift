import AppKit
import AnglesiteSiteModel

/// The Quick Look thumbnail extension's decision and drawing logic (#621), split out of
/// `ThumbnailProvider` so it can run under `swift test` (#1968): ``source(for:fileManager:)``
/// decides *what* to show for a package, and ``drawMonogram(for:size:)`` draws the fallback
/// badge into whatever graphics context is current. The extension only maps the result onto
/// `QLThumbnailReply`.
public enum ThumbnailRendering {
    /// What the thumbnail should show for a readable package.
    public enum Source: Equatable, Sendable {
        /// A cached home-page render exists at `Config/quicklook-thumbnail.png` — hand Quick
        /// Look the file. (No writer for this cache exists yet; this is the read-if-present path.)
        case cachedImage(URL)
        /// No cache: draw the site's first-letter monogram badge.
        case monogram(displayName: String)
    }

    /// Decides the thumbnail source for the package at `packageURL`.
    ///
    /// - Parameters:
    ///   - packageURL: The `.anglesite` package Quick Look asked about.
    ///   - fileManager: The file manager used to read the package (injectable for tests).
    /// - Returns: The source to render, or `nil` when the marker is missing or corrupt — the
    ///   extension then falls back to Quick Look's default folder icon rather than drawing a
    ///   misleading placeholder for something that isn't a readable site.
    public static func source(for packageURL: URL, fileManager: FileManager = .default) -> Source? {
        let package = AnglesitePackage(url: packageURL)
        guard let marker = try? package.readMarker(fileManager: fileManager) else { return nil }
        if fileManager.fileExists(atPath: package.quickLookThumbnailURL.path) {
            return .cachedImage(package.quickLookThumbnailURL)
        }
        return .monogram(displayName: marker.displayName)
    }

    /// Draws a rounded-rect badge with the site's first-letter monogram into the current
    /// `NSGraphicsContext` — the fallback shown until a real cached home-page thumbnail exists.
    ///
    /// - Parameters:
    ///   - displayName: The site's name; its first character (uppercased) is the monogram. An
    ///     empty name draws the badge alone.
    ///   - size: The thumbnail's full size; the badge is inset 5% on each side.
    /// - Returns: Whether it actually drew, so a `QLThumbnailReply` closure never reports
    ///   success for a blank thumbnail. In practice `QLThumbnailReply` always supplies a valid
    ///   current context, so the `false` path is defensive rather than expected.
    @discardableResult
    public static func drawMonogram(for displayName: String, size: CGSize) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        let rect = CGRect(origin: .zero, size: size)
        let inset = min(size.width, size.height) * 0.05
        let cornerRadius = min(size.width, size.height) * 0.12

        let backgroundPath = CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.addPath(backgroundPath)
        context.fillPath()

        let monogram = String(displayName.prefix(1)).uppercased()
        guard !monogram.isEmpty else { return true }
        let fontSize = size.height * 0.4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedString = NSAttributedString(string: monogram, attributes: attributes)
        let textSize = attributedString.size()
        let textOrigin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        attributedString.draw(at: textOrigin)
        return true
    }

    /// Renders the monogram badge into a standalone image — what tests (and any future preview
    /// surface) inspect; the extension draws straight into Quick Look's reply context instead.
    ///
    /// - Parameters:
    ///   - displayName: See ``drawMonogram(for:size:)``.
    ///   - size: The image size in points.
    /// - Returns: The rendered badge.
    public static func monogramImage(for displayName: String, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            drawMonogram(for: displayName, size: size)
        }
    }
}
