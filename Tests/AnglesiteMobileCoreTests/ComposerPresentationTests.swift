// Tests for the composer's presentation helpers (#1968): the phase predicates `ComposeScreen`
// branches on, the field layout the form renders, and the upload-failure classification.
import Foundation
import Testing
import AnglesiteCore
import AnglesiteIOS
@testable import AnglesiteMobileCore

@Suite("Composer presentation helpers")
struct ComposerPresentationTests {
    private static let noteURL = URL(string: "https://owner.example/notes/1")!

    @Test("phase predicates pick out exactly the sending, waiting, conflict, and sent phases")
    func phasePredicates() {
        let post = MicropubPost(type: ["h-entry"], properties: [:])
        let phases: [PostComposerModel.Phase] = [
            .editing, .sending, .waitingForNetwork, .conflict(post), .authRequired,
            .failed("x"), .savedDraft(Self.noteURL), .publishedRebuilding(Self.noteURL),
        ]
        #expect(phases.map(\.isSending) == [false, true, false, false, false, false, false, false])
        #expect(phases.map(\.isWaitingForNetwork) == [false, false, true, false, false, false, false, false])
        #expect(phases.map(\.isConflict) == [false, false, false, true, false, false, false, false])
        #expect(phases.map(\.didSend) == [false, false, false, false, false, false, true, true])
    }

    @Test("the form renders every scalar field except the Markdown body and `draft`, in order")
    func fieldLayout() throws {
        let article = try #require(ContentTypeRegistry.default.descriptor(id: "article"))
        let scalars = ComposerFieldLayout.scalarFields(of: article)
        #expect(!scalars.contains { $0.kind == .markdown })
        #expect(!scalars.contains { $0.name == "draft" })
        #expect(scalars.map(\.name) == article.fields.filter { $0.kind != .markdown && $0.name != "draft" }.map(\.name))
        let body = try #require(ComposerFieldLayout.bodyField(of: article))
        #expect(body.kind == .markdown)
    }

    @Test("upload failures classify by rejection, and transport failures split on re-auth")
    func uploadFailureClassification() {
        #expect(MediaUploadPresentation.classify(.rejected(.empty)) == .empty)
        #expect(MediaUploadPresentation.classify(.rejected(.unsupportedFormat(mimeType: "image/heic")))
                == .unsupportedFormat(mimeType: "image/heic"))
        if case .tooLarge(let size) = MediaUploadPresentation.classify(.rejected(.tooLarge(bytes: 30_000_000))) {
            #expect(size.contains("30") || size.contains("28.6"), "expected a formatted byte count, got \(size)")
        } else {
            Issue.record("expected .tooLarge")
        }
        #expect(MediaUploadPresentation.classify(.transport(.unauthorized)) == .reauthorizationRequired)
        #expect(MediaUploadPresentation.classify(.transport(.unreachable("offline"))) == .transportFailed)
    }

    @Test("Files-picked uploads get a MIME type from the extension, with a binary fallback")
    func mimeTypes() {
        #expect(MediaUploadPresentation.mimeType(forFileExtension: "png") == "image/png")
        #expect(MediaUploadPresentation.mimeType(forFileExtension: "jpeg") == "image/jpeg")
        #expect(MediaUploadPresentation.mimeType(forFileExtension: "zzznotatype") == "application/octet-stream")
    }
}
