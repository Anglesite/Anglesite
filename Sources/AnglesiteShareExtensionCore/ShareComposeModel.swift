import Foundation
import Observation
import AnglesiteCore

/// State and orchestration for the share extension's compose sheet (#1450) — the extension's
/// counterpart to the app's `QuickCaptureModel`, thin per repo convention: logic stays in
/// `AnglesiteCore` (`ShareExtensionSiteAccess`, `LinkPostCreation`, `LinkMetadataFetcher`); this
/// type just holds UI state and wires them together.
///
/// Lives in `AnglesiteShareExtensionCore` rather than the extension target (#1968) so
/// `Tests/AnglesiteShareExtensionCoreTests` can drive it through its injected seams under
/// `swift test`; the extension's `ShareComposeView`/`ShareViewController` only render it.
@MainActor
@Observable
public final class ShareComposeModel {
    /// The page URL Safari shared — fixed for the sheet's lifetime.
    public let urlString: String
    /// The post title: Safari's page title if it supplied one, else filled from the metadata fetch.
    public var title: String
    /// The owner's commentary on the link.
    public var commentary = ""
    /// Whether the best-effort metadata fetch is in flight (drives the title field's spinner).
    public private(set) var isFetchingMetadata = false
    /// The page's `og:image`, if the metadata fetch found one — becomes the link card image.
    public private(set) var metadataImageURL: String?
    /// The sites the owner has opened at least once in the app (published via the App Group).
    public private(set) var sites: [SharedSite] = []
    /// The site the post goes to; defaults to the first shared site.
    public var selectedSiteID: String?
    /// Whether a save is in flight (disables the action buttons).
    public private(set) var isBusy = false
    /// The owner-facing failure to show under the form, or `nil`.
    public private(set) var errorMessage: String?

    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private let fetchMetadata: (URL) async throws -> LinkMetadata
    private let listSites: () -> [SharedSite]
    private let createLinkPost: (String, String, String, String, String?, Bool) async throws -> ContentCreateResult

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - urlString: The shared page URL.
    ///   - initialTitle: Safari's page title, or `""` to fill from metadata.
    ///   - onFinish: Called after a successful save; the controller completes the request.
    ///   - onCancel: Called from ``cancel()``; the controller cancels the request.
    ///   - fetchMetadata: Best-effort page metadata; defaults to `LinkMetadataFetcher`.
    ///   - listSites: The shared-site list; defaults to `ShareExtensionSiteAccess.listSites()`.
    ///   - createLinkPost: Creates the post for `(siteID, title, urlString, commentary,
    ///     imageURL, draft)`; defaults to `LinkPostCreation` under the site's scoped access.
    public init(
        urlString: String,
        initialTitle: String,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        fetchMetadata: @escaping (URL) async throws -> LinkMetadata = { try await LinkMetadataFetcher().fetch(url: $0) },
        listSites: @escaping () -> [SharedSite] = { ShareExtensionSiteAccess.listSites() },
        createLinkPost: @escaping (String, String, String, String, String?, Bool) async throws -> ContentCreateResult = {
            siteID, title, urlString, commentary, imageURL, draft in
            try await ShareExtensionSiteAccess.withScopedAccess(toSiteID: siteID) { sourceDirectory in
                await LinkPostCreation.create(
                    siteID: siteID, title: title, urlString: urlString, commentary: commentary,
                    imageURL: imageURL, draft: draft, sourceDirectory: sourceDirectory)
            }
        }
    ) {
        self.urlString = urlString
        self.title = initialTitle
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.fetchMetadata = fetchMetadata
        self.listSites = listSites
        self.createLinkPost = createLinkPost
    }

    /// Loads the site picker and fetches page metadata — same best-effort behavior as the app's
    /// Quick Capture sheet (`QuickCaptureSheet`'s `.task(id: urlString)`): the fetch always runs
    /// for a valid URL, since the card image (#1451) comes from it regardless of whether Safari
    /// already supplied a title; only the *title* field is guarded against being overwritten
    /// when one is already populated. A fetch failure just leaves the title/image blank, never
    /// blocks the sheet.
    public func onAppear() async {
        sites = listSites()
        selectedSiteID = sites.first?.id
        guard let url = URL(string: urlString) else { return }
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }
        if let metadata = try? await fetchMetadata(url) {
            if title.isEmpty { title = metadata.title ?? "" }
            metadataImageURL = metadata.imageURL
        }
    }

    /// Dismisses the sheet without posting.
    public func cancel() { onCancel() }

    /// Creates the link post on the selected site, then calls `onFinish`; every failure lands
    /// in ``errorMessage`` in the owner's vocabulary instead.
    ///
    /// - Parameter draft: `true` to save as a draft, `false` to publish.
    public func save(draft: Bool) async {
        guard let selectedSiteID else {
            errorMessage = "Choose a site for this link post."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await createLinkPost(
                selectedSiteID, title, urlString, commentary, metadataImageURL, draft)
            switch result {
            case .created:
                onFinish()
            case .siteNotFound:
                errorMessage = "That site isn't available right now."
            case .failed(let reason):
                errorMessage = reason
            }
        } catch ShareExtensionSiteAccess.AccessError.noGrant(let message) {
            errorMessage = message
        } catch {
            errorMessage = "Couldn't access that site's folder. Open it once in Anglesite, then try again."
        }
    }
}
