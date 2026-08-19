import Testing
import Foundation
@testable import AnglesiteCore

/// `MicropubPostVisibility` (#1566): the `public | contacts` audience tier, mirroring
/// `MicropubPostStatus`'s absent-defaults-to-a-known-value shape.
struct MicropubPostVisibilityTests {
    @Test("visibility reads back as an enum, defaulting to public when absent")
    func visibilityDefaultsToPublic() {
        let post = MicropubPost(properties: ["content": [.string("hi")]])
        #expect(post.visibility == .public)
    }

    @Test("visibility reads a stamped contacts value")
    func visibilityReadsContacts() {
        let post = MicropubPost(properties: ["visibility": [.string("contacts")]])
        #expect(post.visibility == .contacts)
    }

    @Test("an unrecognized visibility value reads as public, mirroring status's tolerance")
    func visibilityUnrecognizedReadsPublic() {
        let post = MicropubPost(properties: ["visibility": [.string("unlisted")]])
        #expect(post.visibility == .public)
    }

    @Test("entry stamps visibility alongside post-status, defaulting to public")
    func entryStampsVisibilityDefault() {
        let post = MicropubPost.entry(title: "Hello", content: "Body", status: .published)
        #expect(post.properties["visibility"] == [.string("public")])
    }

    @Test("entry stamps an explicit contacts visibility")
    func entryStampsVisibilityContacts() {
        let post = MicropubPost.entry(content: "Body", visibility: .contacts)
        #expect(post.properties["visibility"] == [.string("contacts")])
    }
}
