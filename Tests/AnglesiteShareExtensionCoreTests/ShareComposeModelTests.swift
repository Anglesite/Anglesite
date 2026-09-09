// Tests for the share extension's compose model (#1450, #1968): site-picker seeding, the
// best-effort metadata fetch and its title-guard rule, and every save outcome's owner-facing
// message — all through the model's injected seams, no App Group or site on disk needed.
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteShareExtensionCore

@Suite("ShareComposeModel")
@MainActor
struct ShareComposeModelTests {
    private static func site(_ id: String, name: String) -> SharedSite {
        SharedSite(id: id, name: name, bookmarkData: Data(), lastSeen: Date())
    }

    /// Records the outcome callbacks so a test can assert which one fired.
    private final class Outcome {
        var finished = 0
        var cancelled = 0
    }

    private static func makeModel(
        urlString: String = "https://example.com/post",
        initialTitle: String = "",
        sites: [SharedSite] = [site("a", name: "Alpha"), site("b", name: "Beta")],
        metadata: @escaping (URL) async throws -> LinkMetadata = { _ in throw URLError(.notConnectedToInternet) },
        create: @escaping (String, String, String, String, String?, Bool) async throws -> ContentCreateResult = { _, _, _, _, _, _ in
            .created(filePath: "src/content/links/x.md", identifier: "x")
        }
    ) -> (ShareComposeModel, Outcome) {
        let outcome = Outcome()
        let model = ShareComposeModel(
            urlString: urlString,
            initialTitle: initialTitle,
            onFinish: { outcome.finished += 1 },
            onCancel: { outcome.cancelled += 1 },
            fetchMetadata: metadata,
            listSites: { sites },
            createLinkPost: create)
        return (model, outcome)
    }

    @Test("onAppear lists the shared sites and preselects the first")
    func onAppearSeedsSitePicker() async {
        let (model, _) = Self.makeModel()
        await model.onAppear()
        #expect(model.sites.map(\.id) == ["a", "b"])
        #expect(model.selectedSiteID == "a")
        #expect(model.isFetchingMetadata == false)
    }

    @Test("metadata fills an empty title and the card image")
    func metadataFillsEmptyTitle() async {
        let (model, _) = Self.makeModel(metadata: { _ in
            LinkMetadata(title: "Fetched Title", description: nil, siteName: nil, imageURL: "https://example.com/card.png")
        })
        await model.onAppear()
        #expect(model.title == "Fetched Title")
        #expect(model.metadataImageURL == "https://example.com/card.png")
    }

    @Test("metadata never overwrites a title Safari already supplied, but still sets the image")
    func metadataKeepsSuppliedTitle() async {
        let (model, _) = Self.makeModel(initialTitle: "Safari Title", metadata: { _ in
            LinkMetadata(title: "Fetched Title", description: nil, siteName: nil, imageURL: "https://example.com/card.png")
        })
        await model.onAppear()
        #expect(model.title == "Safari Title")
        #expect(model.metadataImageURL == "https://example.com/card.png")
    }

    @Test("a failed metadata fetch leaves the title and image blank without blocking the sheet")
    func metadataFailureIsSilent() async {
        let (model, _) = Self.makeModel()
        await model.onAppear()
        #expect(model.title == "")
        #expect(model.metadataImageURL == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("an unparseable URL skips the fetch entirely")
    func invalidURLSkipsFetch() async {
        let (model, _) = Self.makeModel(urlString: "not a url", metadata: { _ in
            Issue.record("fetch must not run for an unparseable URL")
            throw URLError(.badURL)
        })
        await model.onAppear()
        #expect(model.sites.count == 2)
    }

    @Test("save with no site selected explains instead of posting")
    func saveWithoutSiteExplains() async {
        let (model, outcome) = Self.makeModel(sites: [], create: { _, _, _, _, _, _ in
            Issue.record("create must not run without a site")
            return .siteNotFound
        })
        await model.onAppear()
        await model.save(draft: true)
        #expect(model.errorMessage == "Choose a site for this link post.")
        #expect(outcome.finished == 0)
    }

    @Test("a created post finishes the request with the selected site and draft flag")
    func createdPostFinishes() async {
        final class Captured { var args: (String, String, String, String, String?, Bool)? }
        let captured = Captured()
        let (model, outcome) = Self.makeModel(
            initialTitle: "Title",
            metadata: { _ in LinkMetadata(title: nil, description: nil, siteName: nil, imageURL: "https://example.com/img.png") },
            create: { siteID, title, url, commentary, image, draft in
                captured.args = (siteID, title, url, commentary, image, draft)
                return .created(filePath: "p", identifier: "i")
            })
        await model.onAppear()
        model.selectedSiteID = "b"
        model.commentary = "Worth reading."
        await model.save(draft: false)

        #expect(outcome.finished == 1)
        #expect(model.errorMessage == nil)
        #expect(model.isBusy == false)
        let args = captured.args
        #expect(args?.0 == "b")
        #expect(args?.1 == "Title")
        #expect(args?.2 == "https://example.com/post")
        #expect(args?.3 == "Worth reading.")
        #expect(args?.4 == "https://example.com/img.png")
        #expect(args?.5 == false)
    }

    @Test("siteNotFound and failed results become owner-facing messages, not a finish")
    func failureResultsSurfaceMessages() async {
        let (notFound, notFoundOutcome) = Self.makeModel(create: { _, _, _, _, _, _ in .siteNotFound })
        await notFound.onAppear()
        await notFound.save(draft: true)
        #expect(notFound.errorMessage == "That site isn't available right now.")
        #expect(notFoundOutcome.finished == 0)

        let (failed, failedOutcome) = Self.makeModel(create: { _, _, _, _, _, _ in .failed(reason: "disk full") })
        await failed.onAppear()
        await failed.save(draft: true)
        #expect(failed.errorMessage == "disk full")
        #expect(failedOutcome.finished == 0)
    }

    @Test("a missing App Group grant shows the access layer's own message; other errors get the generic one")
    func thrownErrorsMapToMessages() async {
        let (noGrant, _) = Self.makeModel(create: { _, _, _, _, _, _ in
            throw ShareExtensionSiteAccess.AccessError.noGrant("Open Alpha in Anglesite first.")
        })
        await noGrant.onAppear()
        await noGrant.save(draft: true)
        #expect(noGrant.errorMessage == "Open Alpha in Anglesite first.")

        let (other, _) = Self.makeModel(create: { _, _, _, _, _, _ in throw URLError(.cannotOpenFile) })
        await other.onAppear()
        await other.save(draft: true)
        #expect(other.errorMessage == "Couldn't access that site's folder. Open it once in Anglesite, then try again.")
        #expect(other.isBusy == false)
    }

    @Test("cancel forwards to the request's cancel handler")
    func cancelForwards() {
        let (model, outcome) = Self.makeModel()
        model.cancel()
        #expect(outcome.cancelled == 1)
        #expect(outcome.finished == 0)
    }
}
