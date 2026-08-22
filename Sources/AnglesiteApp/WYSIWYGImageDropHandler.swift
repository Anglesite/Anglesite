import Foundation
import UniformTypeIdentifiers
import AnglesiteCore

/// Reads raw image bytes from a Finder/Photos drag's `NSItemProvider`s (#1588 Task 13, design
/// doc §4: "Finder/Photos drag-in → asset ingestion"). Tries `public.image` first (what Photos
/// hands over, and what Finder offers for files whose UTI conforms to image), then falls back to
/// `public.file-url` (a plain file drag) read straight off disk.
///
/// Every `nil` return is logged to `LogCenter` first (the plan's Global Constraints: "no silent
/// failure paths — every bridge rejection/drop logs"). A drop that can't produce bytes still
/// no-ops from the owner's point of view, but the reason is at least readable in the debug pane
/// instead of vanishing into a `try?`.
@MainActor
enum WYSIWYGImageDropHandler {
    /// `LogCenter` source string for the whole Finder/Photos drop pipeline — matches
    /// `WYSIWYGScriptHandler`'s `"wysiwyg-bridge"` naming so the debug pane groups them together.
    static let logSource = "wysiwyg-drop"

    static func loadImageBytes(from providers: [NSItemProvider], logCenter: LogCenter = .shared) async -> Data? {
        guard let provider = providers.first else {
            await logCenter.append(source: logSource, stream: .stderr, text: "drop carried no item providers")
            return nil
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            do {
                return try await loadDataRepresentation(provider, typeIdentifier: UTType.image.identifier)
            } catch {
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "failed to read \(UTType.image.identifier) representation: \(error.localizedDescription)")
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                let urlData = try await loadDataRepresentation(provider, typeIdentifier: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: urlData, relativeTo: nil) else {
                    await logCenter.append(
                        source: logSource, stream: .stderr, text: "dropped file-url item was not a decodable URL")
                    return nil
                }
                return try Data(contentsOf: url)
            } catch {
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "failed to read dropped file contents: \(error.localizedDescription)")
                return nil
            }
        }
        await logCenter.append(
            source: logSource, stream: .stderr,
            text: "drop offered no image or file-url representation (types: \(provider.registeredTypeIdentifiers.joined(separator: ", ")))")
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
