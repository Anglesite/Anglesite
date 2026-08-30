import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("WYSIWYGInspectorModel")
@MainActor
struct WYSIWYGInspectorModelTests {
    static func makeController(componentName: String, props: [String: PropValue] = [:]) -> (WYSIWYGCanvasController, BlockId) {
        let node = BlockNode(id: "b1", kind: .astro, componentName: componentName, props: props, slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        return (controller, "b1")
    }

    /// A throwaway `Source/` directory with `public/images/test.png` already written — the
    /// license-section tests below point a real `src` at it so `WYSIWYGAssetLocator` and
    /// `LicenseMetadataEmbedder` run against real bytes, not stubs.
    static func makeSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("public/images"), withIntermediateDirectories: true)
        writePNG(to: dir.appendingPathComponent("public/images/test.png"))
        return dir
    }

    static func writePNG(to url: URL) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("descriptors resolves from the palette entry matching the block's componentName")
    func descriptorsResolveFromPalette() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.map(\.name).sorted() == ["accentColor", "emphasis", "title"])
    }

    @Test("descriptors is empty for a component with no palette match")
    func descriptorsEmptyForUnknownComponent() {
        let (controller, blockId) = Self.makeController(componentName: "SomeUnknownWidget")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.isEmpty)
    }

    @Test("setString submits a setProp op and stringValue reflects the committed result")
    func setStringCommitsAndReflects() async {
        let (controller, blockId) = Self.makeController(componentName: "Callout", props: ["title": .string("old")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        model.setString("new", for: "title")

        var attempts = 0
        while model.stringValue(for: "title") != "new", attempts < 50 {
            try? await Task.sleep(nanoseconds: 5_000_000) // poll for the fire-and-forget Task's commit
            attempts += 1
        }

        #expect(model.stringValue(for: "title") == "new")
    }

    @Test("boolValue defaults to false for a prop not yet set on the block")
    func boolValueDefaultsFalse() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.boolValue(for: "emphasis") == false)
    }

    @Test("licenseSectionState is nil for a non-img block")
    func licenseSectionNilForNonImgBlock() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.licenseSectionState == nil)
    }

    @Test("licenseSectionState is nil for an img block with no src prop")
    func licenseSectionNilForMissingSrc() {
        let (controller, blockId) = Self.makeController(componentName: "img")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.licenseSectionState == nil)
    }

    @Test("licenseSectionState is disabled for a remote src")
    func licenseSectionDisabledForRemoteSrc() throws {
        let siteDirectory = try Self.makeSiteDirectory()
        let (controller, blockId) = Self.makeController(componentName: "img", props: ["src": .string("https://example.com/x.jpg")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId, sourceDirectory: siteDirectory, routePath: "/")

        guard case .disabled = model.licenseSectionState else {
            Issue.record("expected .disabled, got \(String(describing: model.licenseSectionState))")
            return
        }
    }

    @Test("licenseSectionState is unsupportedFormat for a real file with no metadata slot")
    func licenseSectionUnsupportedFormat() throws {
        let siteDirectory = try Self.makeSiteDirectory()
        try Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
            .write(to: siteDirectory.appendingPathComponent("public/images/test.webp"))
        let (controller, blockId) = Self.makeController(componentName: "img", props: ["src": .string("/images/test.webp")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId, sourceDirectory: siteDirectory, routePath: "/")

        #expect(model.licenseSectionState == .unsupportedFormat)
    }

    @Test("licenseSectionState is editable with no current license for an untouched file")
    func licenseSectionEditableNoCurrentLicense() throws {
        let siteDirectory = try Self.makeSiteDirectory()
        let (controller, blockId) = Self.makeController(componentName: "img", props: ["src": .string("/images/test.png")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId, sourceDirectory: siteDirectory, routePath: "/")

        guard case .editable(let current, let fileURL, let type) = model.licenseSectionState else {
            Issue.record("expected .editable, got \(String(describing: model.licenseSectionState))")
            return
        }
        #expect(current == nil)
        #expect(fileURL == siteDirectory.appendingPathComponent("public/images/test.png").standardizedFileURL)
        #expect(type == .png)
    }

    @Test("setEmbeddedLicense rewrites the file and licenseSectionState reflects the change")
    func setEmbeddedLicenseRewritesFile() throws {
        let siteDirectory = try Self.makeSiteDirectory()
        let (controller, blockId) = Self.makeController(componentName: "img", props: ["src": .string("/images/test.png")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId, sourceDirectory: siteDirectory, routePath: "/")
        let license = LicenseRef(url: "https://creativecommons.org/licenses/by/4.0/", name: "CC BY 4.0")

        model.setEmbeddedLicense(license)

        guard case .editable(let current, _, _) = model.licenseSectionState else {
            Issue.record("expected .editable, got \(String(describing: model.licenseSectionState))")
            return
        }
        #expect(current == license)
    }

    @Test("licenseSectionState is nil when the route's collection suppresses file embedding")
    func licenseSectionNilWhenCollectionSuppresses() throws {
        let siteDirectory = try Self.makeSiteDirectory()
        try FileManager.default.createDirectory(at: siteDirectory.appendingPathComponent("src/data"), withIntermediateDirectories: true)
        try LicensingStore(sourceDirectory: siteDirectory).save(LicensingPolicy())
        let (controller, blockId) = Self.makeController(componentName: "img", props: ["src": .string("/images/test.png")])
        // "bookmarks" is a non-asserting collection with no override — suppressesFileEmbedding is true.
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId, sourceDirectory: siteDirectory, routePath: "/bookmarks/some-slug/")

        #expect(model.licenseSectionState == nil)
    }
}
