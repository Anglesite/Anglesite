import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("AddLinkPostIntent")
struct LinkPostIntentTests {
    private static let aSite = "site-1"

    private func entity() -> SiteEntity {
        SiteEntity(TestStore.site(id: Self.aSite, name: "My Site"))
    }

    /// Records the createTyped call the intent makes.
    private final class Recorder: @unchecked Sendable {
        var calls: [(siteID: String, typeID: String, title: String, slug: String?, fieldValues: [String: String])] = []
    }

    @Test("forwards bookmarkOf, body, draft=true by default; fetches title when absent")
    func forwardsAndFetches() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/example.md", identifier: "example")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in LinkMetadata(title: "Fetched Title") }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                intent.commentary = "Neat."
                intent.publish = false
                _ = try await intent.perform()
            }
        }
        let call = try #require(recorder.calls.first)
        #expect(call.typeID == "bookmark")
        #expect(call.title == "Fetched Title")
        #expect(call.fieldValues["bookmarkOf"] == "https://example.com/post")
        #expect(call.fieldValues["body"] == "Neat.")
        #expect(call.fieldValues["draft"] == "true")
    }

    @Test("publish=true writes draft=false; explicit title skips the fetch")
    func publishAndExplicitTitle() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/x.md", identifier: "x")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in
                Issue.record("must not fetch when a title is supplied")
                return LinkMetadata()
            }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                intent.title2 = "My Title"
                intent.publish = true
                _ = try await intent.perform()
            }
        }
        let call = try #require(recorder.calls.first)
        #expect(call.title == "My Title")
        #expect(call.fieldValues["draft"] == "false")
        #expect(call.fieldValues["body"] == "")  // no commentary → explicit empty body, never the placeholder
    }

    @Test("fetch failure still creates, with an empty title")
    func fetchFailureProceeds() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/y.md", identifier: "y")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in
                throw LinkMetadataFetchError(reason: "offline")
            }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                _ = try await intent.perform()
            }
        }
        #expect(recorder.calls.first?.title == "")
    }

    @Test("dialog wording is honest about draft vs published-pending-deploy")
    func dialogs() {
        let ok = ContentCreateResult.created(filePath: "src/content/bookmarks/z.md", identifier: "z")
        #expect(LinkPostDialogs.created(ok, siteName: "My Site", published: false)
            == "Saved a link post draft on My Site.")
        #expect(LinkPostDialogs.created(ok, siteName: "My Site", published: true)
            == "Published a link post to My Site — it goes live with the site’s next deploy.")
        #expect(LinkPostDialogs.created(.failed(reason: "boom"), siteName: "My Site", published: false)
            == "Couldn’t add that link post to My Site: boom")
    }
}
