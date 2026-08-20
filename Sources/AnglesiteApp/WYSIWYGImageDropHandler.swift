import Foundation
import UniformTypeIdentifiers

/// Reads raw image bytes from a Finder/Photos drag's `NSItemProvider`s (#1588 Task 13, design
/// doc §4: "Finder/Photos drag-in → asset ingestion"). Tries `public.image` first (what Photos
/// hands over, and what Finder offers for files whose UTI conforms to image), then falls back to
/// `public.file-url` (a plain file drag) read straight off disk.
@MainActor
enum WYSIWYGImageDropHandler {
    static func loadImageBytes(from providers: [NSItemProvider]) async -> Data? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await loadDataRepresentation(provider, typeIdentifier: UTType.image.identifier) {
            return data
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let urlData = try? await loadDataRepresentation(provider, typeIdentifier: UTType.fileURL.identifier),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let fileData = try? Data(contentsOf: url) {
            return fileData
        }
        return nil
    }

    private static func loadDataRepresentation(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
