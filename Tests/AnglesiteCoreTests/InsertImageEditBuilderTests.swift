import Foundation
import Testing
@testable import AnglesiteCore

struct InsertImageEditBuilderTests {
    @Test("dataURL base64-encodes bytes with the given mime type") func dataURLEncodesBytes() {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let url = InsertImageEditBuilder.dataURL(bytes: bytes, mimeType: "image/jpeg")
        #expect(url == "data:image/jpeg;base64,\(bytes.base64EncodedString())")
    }

    @Test("message builds an insert-image EditMessage with no selector") func messageBuildsInsertImageEdit() {
        let msg = InsertImageEditBuilder.message(
            id: "fixed-id",
            path: "/about/",
            filename: "team.jpg",
            mimeType: "image/jpeg",
            dataURL: "data:image/jpeg;base64,AA=="
        )
        #expect(msg.id == "fixed-id")
        #expect(msg.path == "/about/")
        #expect(msg.op == EditMessage.Op.insertImage)
        #expect(msg.selector == nil)
        guard case .object(let value) = msg.value else {
            Issue.record("expected .object value, got \(String(describing: msg.value))")
            return
        }
        guard case .string(let filename) = value["filename"] else {
            Issue.record("expected filename string")
            return
        }
        #expect(filename == "team.jpg")
    }
}
