import Foundation
import UniformTypeIdentifiers

/// What Safari's share sheet hands the extension for the current page: the page URL (required —
/// its presence is what the `NSExtensionActivationRule` in Info.plist already guaranteed) and a
/// best-effort title (Safari supplies the page title as the extension item's content text; a
/// missing/empty value just means `ShareComposeModel` falls back to a metadata fetch, exactly
/// like the app's own Quick Capture sheet does for a page with no reachable title).
public struct ShareExtensionInput: Sendable, Equatable {
    /// The shared page's URL.
    public let urlString: String
    /// The page title, whitespace-trimmed; `""` when Safari supplied none.
    public let title: String

    /// Memberwise creation, public for tests and previews.
    public init(urlString: String, title: String) {
        self.urlString = urlString
        self.title = title
    }
}

/// Pulls the ``ShareExtensionInput`` out of the extension request. The `NSExtensionContext`
/// overload is what `ShareViewController` calls; the `[Any]` overload is the testable half —
/// `NSExtensionContext.inputItems` can't be populated outside a real extension request, but
/// `NSExtensionItem`s with `NSItemProvider` attachments can (#1968).
public enum ShareExtensionInputExtractor {
    /// Extracts the shared URL and title from `context`.
    ///
    /// - Parameter context: The extension request.
    /// - Returns: The input, or `nil` when no URL attachment could be loaded.
    public static func extract(from context: NSExtensionContext) async -> ShareExtensionInput? {
        await extract(fromItems: context.inputItems)
    }

    /// Extracts the shared URL and title from the request's `inputItems`. Only the first
    /// `NSExtensionItem` is consulted (Safari sends exactly one), and its first attachment
    /// that loads as a URL wins.
    ///
    /// - Parameter items: `NSExtensionContext.inputItems`, or an equivalent list of
    ///   `NSExtensionItem`s.
    /// - Returns: The input, or `nil` when there is no item, no attachments, or no attachment
    ///   loads as a URL.
    public static func extract(fromItems items: [Any]) async -> ShareExtensionInput? {
        guard let item = items.first as? NSExtensionItem,
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
