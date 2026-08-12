import AppIntents
import Foundation
import AnglesiteCore

/// Test-only escape hatch for the typed create path, mirroring `ContentOperationsOverride` —
/// which can't carry `fieldValues` (its protocol witness is title-only), so the link-post intent
/// gets its own seam typed as the workflow's `TypedSlugCreator`.
public enum TypedContentOverride {
    @TaskLocal public static var scoped: ContentCreationWorkflow.TypedSlugCreator?
}

/// Test-only escape hatch for the metadata fetch, so intent tests never touch the network.
public enum LinkMetadataOverride {
    @TaskLocal public static var scoped: (@Sendable (URL) async throws -> LinkMetadata)?
}

/// Creates a link post — an entry in the site's `bookmarks` collection — from a URL (#531).
/// "Post link to <site>" from Shortcuts/Siri; also the interim share-sheet story until the
/// real share extension lands (spec §5).
public struct AddLinkPostIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Link Post"
    public static let description = IntentDescription(
        "Create a link post (bookmark) for a web page on a site with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "URL", description: "The web page the link post points at.")
    public var url: URL
    /// Named `title2` because `title` collides with the `AppIntent.title` static — same
    /// workaround as `AddPostIntent`; presents as "Title".
    @Parameter(title: "Title", description: "Optional title. Fetched from the page when omitted.")
    public var title2: String?
    @Parameter(title: "Commentary", description: "Optional commentary shown as the post body.")
    public var commentary: String?
    @Parameter(title: "Publish", description: "Publish immediately instead of saving a draft.", default: false)
    public var publish: Bool

    @Dependency private var content: ContentCreationWorkflow

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add link post for \(\.$url) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<PostEntity?> {
        let urlString = url.absoluteString
        guard ContentFieldValidation.isAbsoluteURL(urlString) else {
            return .result(value: nil, dialog: IntentDialog(stringLiteral: LinkPostDialogs.invalidURL))
        }

        var resolvedTitle = (title2 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedTitle.isEmpty {
            // Best-effort: a page with no reachable metadata still captures (spec §6).
            let fetch = LinkMetadataOverride.scoped
                ?? { try await LinkMetadataFetcher().fetch(url: $0) }
            resolvedTitle = (try? await fetch(url))?.title ?? ""
        }

        // `body` is always supplied — commentary text, or "" meaning "no body" — so a published
        // link post never contains the scaffold's placeholder text (Task 3's supplied-but-empty
        // rule; same contract as the app path's `QuickCapture.fieldValues`).
        let fieldValues = [
            "bookmarkOf": urlString,
            "draft": publish ? "false" : "true",
            "body": (commentary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        ]

        // Native in-process write — fast, no server spawn — so no LongRunningIntent gating is
        // needed here, unlike AddPage/AddPost (whose comment predates the native path).
        let result: ContentCreateResult
        if let scoped = TypedContentOverride.scoped {
            result = await scoped(site.id, "bookmark", resolvedTitle, nil, fieldValues, nil)
        } else {
            result = await content.createTyped(
                siteID: site.id, typeID: "bookmark", title: resolvedTitle,
                slug: nil, fieldValues: fieldValues)
        }
        return .result(
            value: Self.createdLinkPost(result, siteID: site.id, title: resolvedTitle),
            dialog: IntentDialog(stringLiteral: LinkPostDialogs.created(
                result, siteName: site.displayName, published: publish))
        )
    }

    /// Reconstruct the created entry as a ``PostEntity`` in the bookmarks collection.
    static func createdLinkPost(_ result: ContentCreateResult, siteID: String, title: String) -> PostEntity? {
        guard case let .created(_, identifier) = result else { return nil }
        return PostEntity(
            id: "\(siteID):post:\(identifier)",
            displayName: title.isEmpty ? identifier : title,
            slug: identifier, collection: "bookmarks", siteID: siteID)
    }
}

/// Spoken/dialog strings for the link-post intent — pure static formatters, unit-testable
/// without the AppIntents runtime, matching `ContentDialogs`' pattern.
public enum LinkPostDialogs {
    public static let invalidURL =
        "That doesn't look like a web address. Try a full link like https://example.com/post."

    public static func created(_ result: ContentCreateResult, siteName: String, published: Bool) -> String {
        switch result {
        case .created:
            return published
                ? "Published a link post to \(siteName) — it goes live with the site's next deploy."
                : "Saved a link post draft on \(siteName)."
        case .siteNotFound:
            return "\(siteName) isn't available right now."
        case .failed(let reason):
            return "Couldn't add that link post to \(siteName): \(reason)"
        }
    }
}
