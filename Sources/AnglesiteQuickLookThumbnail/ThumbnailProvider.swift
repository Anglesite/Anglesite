import QuickLookThumbnailing
import AppKit
import AnglesiteQuickLookUI

/// The Quick Look thumbnail extension's entry point. Only the `QLThumbnailReply` mapping lives
/// here; the decision (cached render vs. monogram vs. not-a-site) and the drawing are
/// `ThumbnailRendering` in `AnglesiteQuickLookUI`, tested against a fixture package (#1968).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        switch ThumbnailRendering.source(for: request.fileURL) {
        case nil:
            // Missing/corrupt marker: fall back to Quick Look's default folder icon rather than
            // drawing a misleading placeholder for something that isn't a readable site.
            handler(nil, nil)
        case .cachedImage(let url):
            handler(QLThumbnailReply(imageFileURL: url), nil)
        case .monogram(let displayName):
            let size = request.maximumSize
            handler(QLThumbnailReply(contextSize: size) {
                ThumbnailRendering.drawMonogram(for: displayName, size: size)
            }, nil)
        }
    }
}
