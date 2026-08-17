import Foundation
import UniformTypeIdentifiers

/// What Safari's share sheet hands the extension for the current page: the page URL (required —
/// its presence is what the `NSExtensionActivationRule` in Info.plist already guaranteed) and a
/// best-effort title (Safari supplies the page title as the extension item's content text; a
/// missing/empty value just means `ShareComposeModel` falls back to a metadata fetch, exactly
/// like the app's own Quick Capture sheet does for a page with no reachable title).
struct ShareExtensionInput: Sendable, Equatable {
    let urlString: String
    let title: String
}

enum ShareExtensionInputExtractor {
    static func extract(from context: NSExtensionContext) async -> ShareExtensionInput? {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else { return nil }

        var urlString: String?
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                urlString = value.absoluteString
                break
            }
        }
        guard let urlString else { return nil }

        let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShareExtensionInput(urlString: urlString, title: title)
    }
}
