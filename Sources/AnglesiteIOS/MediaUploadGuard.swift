// Sources/AnglesiteIOS/MediaUploadGuard.swift
import Foundation

/// The pre-upload size/format check the iOS design's error-handling section calls for (§7):
/// error handling before the media-endpoint request, not capture/compression UX (explicitly out
/// of scope per the parent spec). `MicropubClient.uploadMedia` transports whatever it's handed,
/// so this gate is the caller's — checked here once so the composer and any future capture
/// surface reject the same things the same way.
public enum MediaUploadGuard {
    /// Why an upload was rejected before any network request.
    public enum Rejection: Equatable, Sendable {
        /// The payload exceeds ``maximumBytes``; carries the actual size for the message.
        case tooLarge(bytes: Int)
        /// The MIME type isn't one of ``allowedMIMETypes``; carries the offending type.
        case unsupportedFormat(mimeType: String)
        /// A zero-byte payload — a failed Photos export, not a real file.
        case empty
    }

    /// The upload ceiling: 25 MB. Cloudflare's free-plan request-body limit is 100 MB, but a
    /// phone uploading over cellular needs a bound long before that; 25 MB clears any
    /// full-resolution HEIC/JPEG photo while stopping multi-minute video-sized mistakes.
    public static let maximumBytes = 25 * 1024 * 1024

    /// The web-servable image formats the posting flow accepts — what the template's `<img>`
    /// pipeline and every browser render. HEIC is deliberately absent: browsers don't render it,
    /// and the picker layer transcodes Photos exports to JPEG before this gate sees them.
    public static let allowedMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/svg+xml",
    ]

    /// Checks one candidate upload.
    ///
    /// - Parameters:
    ///   - data: The file bytes as they would be uploaded.
    ///   - mimeType: The candidate's MIME type.
    /// - Returns: The rejection, or `nil` when the upload may proceed.
    public static func rejection(for data: Data, mimeType: String) -> Rejection? {
        if data.isEmpty { return .empty }
        if !allowedMIMETypes.contains(mimeType.lowercased()) {
            return .unsupportedFormat(mimeType: mimeType)
        }
        if data.count > maximumBytes { return .tooLarge(bytes: data.count) }
        return nil
    }
}
