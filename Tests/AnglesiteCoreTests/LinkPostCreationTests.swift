import Testing
import Foundation
@testable import AnglesiteCore

struct LinkPostCreationTests {
    @Test("fieldValues carries bookmarkOf, draft, and body")
    func fieldValuesShape() {
        let values = LinkPostCreation.fieldValues(urlString: "https://example.com", commentary: "hi", draft: true)
        #expect(values["bookmarkOf"] == "https://example.com")
        #expect(values["draft"] == "true")
        #expect(values["body"] == "hi")
    }

    @Test("fieldValues always supplies body, even when commentary is empty")
    func fieldValuesEmptyBody() {
        let values = LinkPostCreation.fieldValues(urlString: "https://example.com", commentary: "", draft: false)
        #expect(values["body"] == "")
        #expect(values["draft"] == "false")
    }

    @Test("create with a nil sourceDirectory fails without crashing")
    func createNilSourceDirectory() async {
        // NativeContentOperations.createTyped reports an unresolvable site directory as
        // `.siteNotFound` (see every `guard let root = await siteDirectory(siteID) else { … }`
        // in NativeContentOperations.swift) — not `.failed`.
        let result = await LinkPostCreation.create(
            siteID: "missing-site", title: "Title", urlString: "https://example.com",
            commentary: "", imageURL: nil, draft: true, sourceDirectory: nil)
        guard case .siteNotFound = result else {
            Issue.record("expected .siteNotFound for a nil sourceDirectory, got \(result)")
            return
        }
    }
}
