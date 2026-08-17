import Foundation
import Observation
import AnglesiteCore

/// State and orchestration for the share extension's compose sheet (#1450) — the extension's
/// counterpart to the app's `QuickCaptureModel`, thin per repo convention: logic stays in
/// `AnglesiteCore` (`ShareExtensionSiteAccess`, `LinkPostCreation`, `LinkMetadataFetcher`); this
/// type just holds UI state and wires them together.
@MainActor
@Observable
final class ShareComposeModel {
    let urlString: String
    var title: String
    var commentary = ""
    var isFetchingMetadata = false
    var metadataImageURL: String?
    var sites: [SharedSite] = []
    var selectedSiteID: String?
    var isBusy = false
    var errorMessage: String?

    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private let fetchMetadata: (URL) async throws -> LinkMetadata
    private let listSites: () -> [SharedSite]
    private let createLinkPost: (String, String, String, String, String?, Bool) async throws -> ContentCreateResult

    init(
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

    /// Loads the site picker and, when Safari didn't supply a usable title, fetches page
    /// metadata to fill it — same best-effort behavior as the app's Quick Capture sheet (a fetch
    /// failure just leaves the title blank and editable, never blocks the sheet).
    func onAppear() async {
        sites = listSites()
        selectedSiteID = sites.first?.id
        guard title.isEmpty, let url = URL(string: urlString) else { return }
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }
        if let metadata = try? await fetchMetadata(url) {
            if title.isEmpty { title = metadata.title ?? "" }
            metadataImageURL = metadata.imageURL
        }
    }

    func cancel() { onCancel() }

    func save(draft: Bool) async {
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
