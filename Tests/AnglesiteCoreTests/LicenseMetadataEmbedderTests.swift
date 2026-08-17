import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AnglesiteCore

@Suite("LicenseMetadataEmbedder (#999)")
struct LicenseMetadataEmbedderTests {
    private let license = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

    @Test("a format with no metadata slot resolves to .unsupported, not an error")
    func unsupportedFormatDoesNotThrow() throws {
        let bytes = Data("not a real archive".utf8)
        let result = try LicenseMetadataEmbedder.embed(license, into: bytes, type: .zip)
        #expect(result == .unsupported)
    }

    @Test("supportedTypes lists exactly the image and PDF formats this plan implements")
    func supportedTypesScope() {
        #expect(LicenseMetadataEmbedder.supportedTypes == [.jpeg, .png, .tiff, .heic, .pdf])
    }

    @Test("audio and video types resolve to .unsupported (no AVFoundation backend yet)")
    func avTypesUnsupported() throws {
        for type: UTType in [.mpeg4Movie, .quickTimeMovie, .mp3, .wav] {
            let result = try LicenseMetadataEmbedder.embed(license, into: Data(), type: type)
            #expect(result == .unsupported, "\(type.identifier) should be unsupported")
        }
    }
}
