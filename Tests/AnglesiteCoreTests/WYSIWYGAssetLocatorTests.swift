import Foundation
import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGAssetLocator (#1672)")
struct WYSIWYGAssetLocatorTests {
    private let siteDirectory = URL(fileURLWithPath: "/tmp/some-site")

    @Test("a root-relative src resolves under siteDirectory/public")
    func rootRelativeResolves() {
        let resolved = WYSIWYGAssetLocator.resolve(src: "/images/wysiwyg-abc123.png", siteDirectory: siteDirectory)
        #expect(resolved == siteDirectory.appendingPathComponent("public/images/wysiwyg-abc123.png").standardizedFileURL)
    }

    @Test("an absolute URL resolves to nil")
    func absoluteURLResolvesToNil() {
        #expect(WYSIWYGAssetLocator.resolve(src: "https://example.com/photo.jpg", siteDirectory: siteDirectory) == nil)
    }

    @Test("a data: URL resolves to nil")
    func dataURLResolvesToNil() {
        #expect(WYSIWYGAssetLocator.resolve(src: "data:image/png;base64,AAAA", siteDirectory: siteDirectory) == nil)
    }

    @Test("a protocol-relative src resolves to nil")
    func protocolRelativeResolvesToNil() {
        #expect(WYSIWYGAssetLocator.resolve(src: "//evil.example/x.png", siteDirectory: siteDirectory) == nil)
    }

    @Test("a src that traverses outside public/ resolves to nil")
    func traversalResolvesToNil() {
        #expect(WYSIWYGAssetLocator.resolve(src: "/../../etc/passwd", siteDirectory: siteDirectory) == nil)
    }

    @Test("a bare relative src (no leading slash) resolves to nil")
    func bareRelativeResolvesToNil() {
        #expect(WYSIWYGAssetLocator.resolve(src: "images/x.png", siteDirectory: siteDirectory) == nil)
    }
}
