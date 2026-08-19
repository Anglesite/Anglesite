import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteAppCore
import AnglesiteCore
import AnglesiteIOS

/// `RestrictedPostPublisher` (#1566): the Mac composer's only Micropub-write path — creates a
/// restricted post directly via `MicropubClient`, never touching `Source/` or git. Injectable
/// `makeMicropubClient`, same faked-seam style as `TypedEntryEditorModelCMSModeTests`.
@Suite(.serialized)
struct RestrictedPostPublisherTests {
    private nonisolated static let endpoint = URL(string: "https://owner.example/micropub")!

    private nonisolated static func response(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    @Test("isAvailable is true when the factory resolves a client")
    func isAvailableTrueWhenResolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(200)) })
        })
        let available = await publisher.isAvailable(siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(available)
    }

    @Test("isAvailable is false when the factory resolves no session")
    func isAvailableFalseWhenUnresolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in nil })
        let available = await publisher.isAvailable(siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(!available)
    }

    @Test("createPost sends a create with visibility: contacts and status: published")
    func createPostSendsContactsVisibility() async throws {
        nonisolated(unsafe) var capturedProperties: [String: [Any]]?
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { request in
                    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    capturedProperties = body?["properties"] as? [String: [Any]]
                    return (Data(), Self.response(201, headers: ["Location": "https://owner.example/2026/my-post"]))
                })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body text", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(outcome == .success)
        let properties = try #require(capturedProperties)
        #expect(properties["visibility"] as? [String] == ["contacts"])
        #expect(properties["post-status"] as? [String] == ["published"])
        #expect(properties["content"] as? [String] == ["Body text"])
    }

    @Test("createPost reports failed when no session resolves")
    func createPostFailedWhenUnresolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in nil })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test("createPost surfaces a distinct message on 401")
    func createPostReauthMessage() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(401)) })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("sign in"))
    }

    @Test("createPost surfaces the server's status on a plain request failure")
    func createPostRequestFailedMessage() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(400)) })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }
}
