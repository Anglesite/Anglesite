import Testing
import Foundation
import UniformTypeIdentifiers
@testable import AnglesiteAppCore

@Suite("WYSIWYGImageDropHandler")
struct WYSIWYGImageDropHandlerTests {
    @Test("loads bytes directly from a provider offering public.image data")
    func loadsFromImageData() async {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider(item: bytes as NSSecureCoding, typeIdentifier: UTType.png.identifier)

        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [provider])

        #expect(loaded == bytes)
    }

    @Test("returns nil when the provider offers neither image data nor a file URL")
    func returnsNilForUnsupportedProvider() async {
        let provider = NSItemProvider(item: "not an image" as NSSecureCoding, typeIdentifier: UTType.plainText.identifier)

        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [provider])

        #expect(loaded == nil)
    }

    @Test("returns nil for an empty provider list")
    func returnsNilForEmptyProviders() async {
        let loaded = await WYSIWYGImageDropHandler.loadImageBytes(from: [])
        #expect(loaded == nil)
    }
}
