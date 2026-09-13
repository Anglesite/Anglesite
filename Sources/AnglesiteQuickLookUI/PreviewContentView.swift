import SwiftUI
import AnglesiteSiteModel
import AnglesiteQuickLookSupport

/// The Quick Look preview's content: a `.anglesite` package's identity and layout facts from
/// `PackagePreviewSummary`, rendered by `PreviewViewController`'s hosting controller. A
/// `nil` summary covers every "not a readable Anglesite site" case (missing/corrupt marker) —
/// Quick Look has no good error-surfacing UI of its own, so this in-view fallback is preferable
/// to throwing.
///
/// Lives in `AnglesiteQuickLookUI` rather than the extension target (#1968) so the same view the
/// extension hosts can be rendered headlessly under `swift test` (via `ImageRenderer`) against a
/// fixture package — the extension itself only wraps it in `QLPreviewingController`.
public struct PreviewContentView: View {
    /// The package facts to show, or `nil` for the "not a readable site" fallback.
    public let summary: PackagePreviewSummary?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Creates the view for an already-computed summary.
    ///
    /// - Parameter summary: The package facts, or `nil` for the fallback.
    public init(summary: PackagePreviewSummary?) {
        self.summary = summary
    }

    /// Creates the view for the package at `packageURL`, summarizing it synchronously — the
    /// extension's `preparePreviewOfFile(at:)` path. Any marker failure lands on the fallback.
    ///
    /// - Parameters:
    ///   - packageURL: The `.anglesite` package Quick Look was asked to preview.
    ///   - fileManager: The file manager used to read the package (injectable for tests).
    public init(packageURL: URL, fileManager: FileManager = .default) {
        self.init(summary: try? PackagePreviewSummary.summarize(AnglesitePackage(url: packageURL), fileManager: fileManager))
    }

    public var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 12) {
                header(for: summary)
                Divider()
                stats(for: summary)
                Spacer()
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Not a readable Anglesite site")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(for summary: PackagePreviewSummary) -> some View {
        HStack(spacing: 12) {
            if let thumbnailURL = summary.cachedThumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.title2)
                    .bold()
                Text("Created \(Self.dateFormatter.string(from: summary.createdDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stats(for summary: PackagePreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.pageCount) page\(summary.pageCount == 1 ? "" : "s")")
            ForEach(summary.collectionCounts, id: \.name) { collection in
                Text("\(collection.count) \(collection.name)")
            }
            if let lastModified = summary.sourceLastModified {
                Text("Last modified \(Self.dateFormatter.string(from: lastModified))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
    }
}
