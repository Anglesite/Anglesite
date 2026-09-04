import Foundation

/// Writes a link post (bookmark) entry given an already-resolved site source directory — the
/// windowless write path shared by the app's Quick Capture launcher flow and the share extension
/// (#1450). Both callers resolve `sourceDirectory` their own way (`SiteStore` for the app,
/// `ShareExtensionSiteAccess` for the extension) and hand it in here, so the create-plus-card-
/// image logic lives in exactly one place.
public enum LinkPostCreation {
    /// The `fieldValues` a link post writes through `createTyped`. `body` is always supplied —
    /// commentary text, or `""` meaning "no body" — so a published link post never contains the
    /// scaffold's placeholder text (quick-capture spec §4.1's supplied-but-empty rule).
    public static func fieldValues(urlString: String, commentary: String, draft: Bool) -> [String: String] {
        [
            "bookmarkOf": urlString,
            "draft": draft ? "true" : "false",
            "body": commentary,
        ]
    }

    /// Creates the entry, then best-effort captures its card image (#1451) — a failure there
    /// leaves a perfectly good link post, so its result is ignored.
    public static func create(
        siteID: String, title: String, urlString: String, commentary: String,
        imageURL: String?, draft: Bool, sourceDirectory: URL?
    ) async -> ContentCreateResult {
        let workflow = ContentCreationWorkflow.native(
            contentGraph: nil,
            siteDirectory: { _ in sourceDirectory }
        )
        let result = await workflow.createTyped(
            siteID: siteID, typeID: "bookmark", title: title, slug: nil,
            fieldValues: fieldValues(urlString: urlString, commentary: commentary, draft: draft))
        _ = await LinkPostImageCapture().capture(
            imageURL: imageURL, createResult: result, siteDirectory: sourceDirectory)
        return result
    }
}
