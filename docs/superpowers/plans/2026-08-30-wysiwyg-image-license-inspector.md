# WYSIWYG Image License Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two gaps #1672 flags in #999's drop-and-inspect flow — a dropped image isn't selected, and there's no way to read an embedded license back — so the Info panel can show and change a selected image block's embedded license.

**Architecture:** Add a read counterpart to `LicenseMetadataEmbedder` (image + PDF XMP), a small pure path-resolver (`WYSIWYGAssetLocator`) that maps a block's `src` prop to the on-disk file under `public/`, a controller method that owns "select what I just inserted" the same way `deleteSelectedBlock()` owns clearing selection, and a license section in the native WYSIWYG inspector that reads/rewrites that file in place.

**Tech Stack:** Swift 6.4, SwiftUI, ImageIO/CoreGraphics (XMP read/write), Swift Testing.

## Global Constraints

- No new dependencies — Apple frameworks only (ImageIO, CoreGraphics, Foundation).
- `LicenseMetadataEmbedder.readLicense` never throws — unsupported type or absent license both return `nil`, matching `embed`'s existing "never fail on genuinely unsupported" contract.
- `WYSIWYGAssetLocator.resolve` never touches the filesystem — it only computes a path; existence/format checks are the caller's job.
- The license section is disabled with an explanatory label for a non-resolvable `src` (remote/`data:`) — never an error alert (issue's resolved default 2).
- Unsupported-but-real-file formats (e.g. WebP) show as visibly unsupported, not hidden (resolved default 3).
- A rewrite through the inspector writes atomically to the resolved `public/` file and never touches `AppSettings.shared.lastUsedFileLicenseSelection` (resolved defaults 4 and 7).
- Non-asserting collections (per `LicensingPolicy.suppressesFileEmbedding`) suppress the section entirely (resolved default 6).
- Run `swift test --package-path .` and `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` before opening the PR (`AnglesiteApp`/`AnglesiteIntents` suites only run for real on local Xcode 27 — CI cannot catch a regression there).

---

### Task 1: `WYSIWYGAssetLocator` — resolve a block's `src` to a file on disk

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGAssetLocator.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGAssetLocatorTests.swift`

**Interfaces:**
- Produces: `public enum WYSIWYGAssetLocator { public static func resolve(src: String, siteDirectory: URL) -> URL? }`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter WYSIWYGAssetLocatorTests`
Expected: FAIL — `WYSIWYGAssetLocator` doesn't exist yet (build error).

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Resolves a WYSIWYG image block's `src` prop back to the on-disk file
/// `WYSIWYGImageAssetIngestor` wrote it to, so the license inspector (#1672) can read and
/// rewrite the exact same bytes. Read-only: this type never touches the filesystem itself, only
/// computes a path — callers decide what to do with it (check existence, read, write).
public enum WYSIWYGAssetLocator {
    /// `src` → the file URL under `<siteDirectory>/public/` it names, or `nil` when `src` isn't a
    /// root-relative path into that directory: an absolute URL (`http(s)://…`), a protocol-
    /// relative URL (`//host/…`), a `data:` URL, a bare relative path, or anything that resolves
    /// (via `..`) outside `public/` are all `nil` rather than a guessed location. Does not check
    /// that the file actually exists — that's a separate, cheaper check callers make themselves.
    public static func resolve(src: String, siteDirectory: URL) -> URL? {
        guard src.hasPrefix("/"), !src.hasPrefix("//") else { return nil }
        let relativePath = String(src.dropFirst())
        guard !relativePath.isEmpty else { return nil }

        let publicDirectory = siteDirectory.appendingPathComponent("public", isDirectory: true).standardizedFileURL
        let candidate = publicDirectory.appendingPathComponent(relativePath).standardizedFileURL
        let publicPathWithSlash = publicDirectory.path.hasSuffix("/") ? publicDirectory.path : publicDirectory.path + "/"
        guard candidate.path.hasPrefix(publicPathWithSlash) else { return nil }
        return candidate
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WYSIWYGAssetLocatorTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGAssetLocator.swift Tests/AnglesiteCoreTests/WYSIWYGAssetLocatorTests.swift
git commit -m "feat(#1672): add WYSIWYGAssetLocator to resolve block src to a file"
```

---

### Task 2: `LicenseMetadataEmbedder.readLicense` — the read counterpart

**Files:**
- Modify: `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`
- Test: `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`

**Interfaces:**
- Consumes: `LicenseMetadataEmbedder.embed(_:into:type:)`, `LicenseMetadataEmbedder.supportedTypes`, `LicenseMetadataEmbedder.imageTypes` (existing private/internal state in the same file).
- Produces: `public static func readLicense(from data: Data, type: UTType) -> LicenseRef?`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift` (inside the existing `LicenseMetadataEmbedderTests` struct):

```swift
    @Test("readLicense returns nil for a type outside supportedTypes")
    func readLicenseUnsupportedTypeReturnsNil() {
        #expect(LicenseMetadataEmbedder.readLicense(from: Data(), type: .zip) == nil)
    }

    @Test("readLicense returns nil for a supported type with no embedded license")
    func readLicenseNoLicenseReturnsNil() {
        #expect(LicenseMetadataEmbedder.readLicense(from: pngData(), type: .png) == nil)
    }

    @Test("readLicense round-trips embed for every supported image type",
          arguments: [UTType.jpeg, .png, .tiff, .heic])
    func readLicenseRoundTripsImages(type: UTType) throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: imageData(type: type), type: type)
        guard case .embedded(let embedded) = result else {
            Issue.record("expected .embedded for \(type.identifier), got \(result)")
            return
        }
        let readBack = LicenseMetadataEmbedder.readLicense(from: embedded, type: type)
        #expect(readBack == license, "\(type.identifier) failed to round-trip")
    }

    @Test("readLicense round-trips embed for PDF")
    func readLicenseRoundTripsPDF() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: onePagePDFData(), type: .pdf)
        guard case .embedded(let embedded) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        #expect(LicenseMetadataEmbedder.readLicense(from: embedded, type: .pdf) == license)
    }

    @Test("readLicense returns nil for unreadable bytes rather than throwing")
    func readLicenseUnreadableBytesReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(LicenseMetadataEmbedder.readLicense(from: garbage, type: .png) == nil)
        #expect(LicenseMetadataEmbedder.readLicense(from: garbage, type: .pdf) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: FAIL — `readLicense` doesn't exist yet (build error).

- [ ] **Step 3: Write the implementation**

Add to `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`, inside the `LicenseMetadataEmbedder` enum, after `embed(_:into:type:)`:

```swift
    /// Reads the license `embed(_:into:type:)` (or an equivalent writer) embedded into `data`,
    /// read as `type` (#1672 — the drop-and-inspect flow this type's own doc comment
    /// anticipated). Both backends write the same `xmpRights:WebStatement`/`xmpRights:UsageTerms`
    /// fields, so this shares one read path for both.
    ///
    /// - Returns: `nil` for a `type` outside ``supportedTypes``, for data that fails to decode as
    ///   that type, or for a supported file with no embedded license — never throws.
    public static func readLicense(from data: Data, type: UTType) -> LicenseRef? {
        guard supportedTypes.contains(type) else { return nil }
        if imageTypes.contains(type) {
            return readFromImage(data)
        }
        if type == .pdf {
            return readFromPDF(data)
        }
        return nil
    }

    private static func readFromImage(_ data: Data) -> LicenseRef? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }
        return licenseRef(from: metadata)
    }

    /// Reads the XMP packet `embedIntoPDF` writes, via `CGPDFDocument`'s catalog `/Metadata`
    /// stream — the same location `CGContext.addDocumentMetadata(_:)` writes to. PDFKit has no
    /// XMP accessor, so this is the only way to read it back.
    private static func readFromPDF(_ data: Data) -> LicenseRef? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let catalog = document.catalog else {
            return nil
        }
        var metadataStream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &metadataStream), let stream = metadataStream else {
            return nil
        }
        var format: CGPDFDataFormat = .raw
        guard let xmpData = CGPDFStreamCopyData(stream, &format),
              let metadata = CGImageMetadataCreateFromXMPData(xmpData) else {
            return nil
        }
        return licenseRef(from: metadata)
    }

    /// Shared by both backends: `metadata` may come from an image's own metadata slot or from a
    /// raw XMP packet parsed via `CGImageMetadataCreateFromXMPData` — either way the rights
    /// fields live at the same path once the `xmpRights` prefix is registered against a mutable
    /// copy (the same registration `embedIntoImage` performs, and just as harmless to repeat if
    /// the prefix is already present).
    private static func licenseRef(from metadata: CGImageMetadata) -> LicenseRef? {
        guard let mutable = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        let xmpRightsNamespace = "http://ns.adobe.com/xap/1.0/rights/" as CFString
        _ = CGImageMetadataRegisterNamespaceForPrefix(mutable, xmpRightsNamespace, "xmpRights" as CFString, nil)
        guard let url = CGImageMetadataCopyStringValueWithPath(mutable, nil, "xmpRights:WebStatement" as CFString) as String?,
              !url.isEmpty else {
            return nil
        }
        let rawName = CGImageMetadataCopyStringValueWithPath(mutable, nil, "xmpRights:UsageTerms" as CFString) as String?
        let name = (rawName?.isEmpty == false) ? rawName! : url
        return LicenseRef(url: url, name: name)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: PASS (all tests, old and new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LicenseMetadataEmbedder.swift Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift
git commit -m "feat(#1672): add LicenseMetadataEmbedder.readLicense"
```

---

### Task 3: Select the block a drop just inserted

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:1634` (the drop handler's `canvas.submit(.insertBlock(...))` call)
- Test: `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGCanvasController.submit(_:) async -> OpResult`, `OpResult.applied(model:)`.
- Produces: `@discardableResult func insertBlockAndSelect(parentId: ParentRef, slot: String, index: Int, newId: BlockId, block: BlockNodeContent) async -> OpResult`

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift`:

```swift
    @Test("insertBlockAndSelect selects the new block on success")
    func insertBlockAndSelectSelectsOnSuccess() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        let content = BlockNodeContent(kind: .astro, componentName: "img", props: [:], slots: [:], sourceSpan: [0, 0])

        let result = await controller.insertBlockAndSelect(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: content)

        #expect(result.isApplied)
        #expect(controller.selectedBlockId == "b1")
        #expect(controller.model.rootIds == ["b1"])
    }

    @Test("insertBlockAndSelect leaves selection untouched on rejection")
    func insertBlockAndSelectLeavesSelectionOnRejection() async {
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])
        let transport = StubWYSIWYGHostTransport(model: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.forceTargetVersion = "stale-version"
        let content = BlockNodeContent(kind: .astro, componentName: "img", props: [:], slots: [:], sourceSpan: [0, 0])

        let result = await controller.insertBlockAndSelect(parentId: rootParentID, slot: "main", index: 0, newId: "b1", block: content)

        #expect(!result.isApplied)
        #expect(controller.selectedBlockId == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Expected: FAIL — `insertBlockAndSelect` doesn't exist yet (build error). (If `OpResult` has no `isApplied` helper, check `WYSIWYGCanvasControllerTests.swift`'s existing `#expect(result.isApplied)` usage at line 20 — it's already there, so no new helper is needed. If `forceTargetVersion` doesn't reliably cause a rejection against a `StubWYSIWYGHostTransport` with an empty model, use the same version-mismatch setup as the existing `submitAdoptsFreshModelOnRejection` test above it in the same file instead.)

- [ ] **Step 3: Write the implementation**

Add to `Sources/AnglesiteApp/WYSIWYGCanvasController.swift`, directly after `insertBlock(_:)`:

```swift
    /// Submits an `insertBlock` op and selects the newly-inserted block on success — the drop
    /// handler's own selection-on-drop entry point (#1672's resolved default 1: "a controller
    /// method rather than a direct field write, matching how `deleteSelectedBlock()` owns
    /// selection changes today"). Leaves `selectedBlockId` untouched on rejection: there's no new
    /// block to select if the op never landed.
    @discardableResult
    func insertBlockAndSelect(
        parentId: ParentRef, slot: String, index: Int, newId: BlockId, block: BlockNodeContent
    ) async -> OpResult {
        let result = await submit(.insertBlock(parentId: parentId, slot: slot, index: index, newId: newId, block: block))
        if case .applied = result {
            selectedBlockId = newId
        }
        return result
    }
```

Then in `Sources/AnglesiteApp/SiteWindow.swift`, replace the line:

```swift
                    await canvas.submit(.insertBlock(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content))
```

with:

```swift
                    await canvas.insertBlockAndSelect(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WYSIWYGCanvasControllerTests`
Expected: PASS (all tests, old and new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGCanvasController.swift Sources/AnglesiteApp/SiteWindow.swift Tests/AnglesiteAppTests/WYSIWYGCanvasControllerTests.swift
git commit -m "feat(#1672): select a dropped image after its insertBlock lands"
```

---

### Task 4: License section state + rewrite on `WYSIWYGInspectorModel`

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGInspectorModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:378` (thread `sourceDirectory`/`routePath` into the constructor)
- Test: `Tests/AnglesiteAppTests/WYSIWYGInspectorModelTests.swift`

**Interfaces:**
- Consumes: `WYSIWYGAssetLocator.resolve(src:siteDirectory:)` (Task 1), `LicenseMetadataEmbedder.readLicense`/`.embed`/`.supportedTypes` (Task 2), `LicensingStore(sourceDirectory:).load()`, `LicensingPolicy.suppressesFileEmbedding(for:)`, `LicensableCollection(routePath:)` (all existing, `AnglesiteCore/LicensingStore.swift`).
- Produces:
  - `enum WYSIWYGLicenseSectionState: Equatable { case disabled(reason: String); case unsupportedFormat; case editable(current: LicenseRef?, fileURL: URL, type: UTType) }`
  - `WYSIWYGInspectorModel.init(controller:blockId:sourceDirectory:routePath:)` — `sourceDirectory: URL? = nil`, `routePath: String = "/"` (defaulted so every existing 2-arg call site keeps compiling).
  - `WYSIWYGInspectorModel.licenseSectionState: WYSIWYGLicenseSectionState?` (stored, `@Observable`-tracked).
  - `WYSIWYGInspectorModel.setEmbeddedLicense(_ license: LicenseRef)`.

- [ ] **Step 1: Write the failing tests**

Replace the top of `Tests/AnglesiteAppTests/WYSIWYGInspectorModelTests.swift` (imports + `makeController`) and append new tests, so the full file reads:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter WYSIWYGInspectorModelTests`
Expected: FAIL — `licenseSectionState`/`setEmbeddedLicense`/the 4-arg `init` don't exist yet (build error).

- [ ] **Step 3: Write the implementation**

Replace the whole contents of `Sources/AnglesiteApp/WYSIWYGInspectorModel.swift` with:

```swift
import Foundation
import Observation
import UniformTypeIdentifiers
import AnglesiteCore

/// The native inspector's model for one selected WYSIWYG block (#1588 Task 6) — the WYSIWYG
/// analog of `TypedEntryEditorModel`'s per-field binding methods (`TypedEntryEditorModel.swift`),
/// but committing per-edit through `Op.setProp` rather than buffering until an explicit Save: the
/// canvas has no Save step, everything applies live (design doc §1).
@MainActor
@Observable
final class WYSIWYGInspectorModel {
    let controller: WYSIWYGCanvasController
    let blockId: BlockId
    private let sourceDirectory: URL?
    private let collection: LicensableCollection?
    private let licensingPolicy: LicensingPolicy

    /// What the license section (#1672) should render for the selected block right now. Stored
    /// (not computed) and refreshed explicitly by `refreshLicenseSection()` — both on `init` and
    /// after `setEmbeddedLicense(_:)` rewrites the file — because a license rewrite never touches
    /// `controller.model` (the block's `src` prop is untouched), so nothing would otherwise tell
    /// `@Observable` to re-render the section.
    private(set) var licenseSectionState: WYSIWYGLicenseSectionState?

    /// `sourceDirectory` is the open site's `Source/` directory (nil when no site is open, or in
    /// tests that don't need the license section); `routePath` is the active preview route,
    /// resolved to a `LicensableCollection` the same way `InsertCommands.insertImage` does.
    /// Both default so every existing 2-arg call site keeps compiling unchanged.
    init(controller: WYSIWYGCanvasController, blockId: BlockId, sourceDirectory: URL? = nil, routePath: String = "/") {
        self.controller = controller
        self.blockId = blockId
        self.sourceDirectory = sourceDirectory
        self.collection = LicensableCollection(routePath: routePath)
        self.licensingPolicy = sourceDirectory.flatMap { try? LicensingStore(sourceDirectory: $0).load() } ?? LicensingPolicy()
        refreshLicenseSection()
    }

    private var node: BlockNode? { controller.model.blocks[blockId] }

    /// The editable props for this block's kind, resolved from the interim palette (Task 5) by
    /// matching `componentName` — real prop schemas arrive with #1222's CEM manifest.
    var descriptors: [WYSIWYGPropDescriptor] {
        guard let node else { return [] }
        return WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == node.componentName }?.props ?? []
    }

    func stringValue(for name: String) -> String {
        guard case .string(let value)? = node?.props[name] else { return "" }
        return value
    }

    func setString(_ value: String, for name: String) {
        Task { await commit(name: name, value: .string(value)) }
    }

    func numberValue(for name: String) -> Double {
        guard case .number(let value)? = node?.props[name] else { return 0 }
        return value
    }

    func setNumber(_ value: Double, for name: String) {
        Task { await commit(name: name, value: .number(value)) }
    }

    func boolValue(for name: String) -> Bool {
        guard case .bool(let value)? = node?.props[name] else { return false }
        return value
    }

    func setBool(_ value: Bool, for name: String) {
        Task { await commit(name: name, value: .bool(value)) }
    }

    private func commit(name: String, value: PropValue) async {
        let previous = node?.props[name] ?? .null
        await controller.submit(.setProp(blockId: blockId, propName: name, value: value, previousValue: previous))
    }

    /// Rewrites the selected block's image file in place with `license` embedded (#1672 resolved
    /// default 4) — atomically, at the resolved `public/` path. Only the file's own metadata
    /// changes; the block's `src` prop, and therefore what the page renders, is untouched, and
    /// `AppSettings.shared.lastUsedFileLicenseSelection` is deliberately not updated (resolved
    /// default 7 — that value is the attach-time picker's memory, not this one-off correction's).
    /// A no-op if the section isn't currently `.editable` or the write fails (defensive; the view
    /// only calls this when it's already showing the editable state).
    func setEmbeddedLicense(_ license: LicenseRef) {
        guard case .editable(_, let fileURL, let type) = licenseSectionState,
              let data = try? Data(contentsOf: fileURL),
              let result = try? LicenseMetadataEmbedder.embed(license, into: data, type: type),
              case .embedded(let newData) = result
        else { return }
        try? newData.write(to: fileURL, options: .atomic)
        refreshLicenseSection()
    }

    private func refreshLicenseSection() {
        licenseSectionState = Self.resolveLicenseSectionState(
            node: node, sourceDirectory: sourceDirectory, collection: collection, licensingPolicy: licensingPolicy)
    }

    private static func resolveLicenseSectionState(
        node: BlockNode?, sourceDirectory: URL?, collection: LicensableCollection?, licensingPolicy: LicensingPolicy
    ) -> WYSIWYGLicenseSectionState? {
        guard let node, node.componentName == "img" else { return nil }
        guard case .string(let src)? = node.props["src"] else { return nil }
        guard !licensingPolicy.suppressesFileEmbedding(for: collection) else { return nil }

        guard let sourceDirectory, let fileURL = WYSIWYGAssetLocator.resolve(src: src, siteDirectory: sourceDirectory) else {
            return .disabled(reason: String(localized: "This image isn't stored in the site, so its license can't be read or changed here."))
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .disabled(reason: String(localized: "This image's file is missing from the site."))
        }
        guard let type = UTType(filenameExtension: fileURL.pathExtension), LicenseMetadataEmbedder.supportedTypes.contains(type) else {
            return .unsupportedFormat
        }
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        return .editable(current: LicenseMetadataEmbedder.readLicense(from: data, type: type), fileURL: fileURL, type: type)
    }
}

/// What the WYSIWYG inspector's license section should render for the selected block (#1672).
/// `nil` from `WYSIWYGInspectorModel.licenseSectionState` means "don't show the section at all"
/// — only an `img` block whose page/collection doesn't suppress file-level licensing gets a
/// non-nil state here; every other block kind, and every non-asserting-collection page, are nil.
enum WYSIWYGLicenseSectionState: Equatable {
    /// `src` isn't a resolvable, existing file under `public/` — a remote URL, a `data:` URL, or
    /// a file that's gone missing. Shown disabled with `reason` as the explanatory label; never
    /// an alert.
    case disabled(reason: String)
    /// The file exists but its format has no metadata slot (`LicenseMetadataEmbedder.supportedTypes`
    /// doesn't include it, e.g. WebP) — shown disabled, stating the format carries no license slot.
    case unsupportedFormat
    /// A real, supported file: `current` is what's embedded today (`nil` = no license embedded),
    /// and choosing a catalog entry rewrites `fileURL` in place via `setEmbeddedLicense(_:)`.
    case editable(current: LicenseRef?, fileURL: URL, type: UTType)
}
```

Then in `Sources/AnglesiteApp/SiteWindowModel.swift`, replace:

```swift
        if case .preview = mainPaneMode, let canvas = preview.wysiwygCanvas, let selectedBlockId = canvas.selectedBlockId {
            return .wysiwygBlock(WYSIWYGInspectorModel(controller: canvas, blockId: selectedBlockId))
        }
```

with:

```swift
        if case .preview = mainPaneMode, let canvas = preview.wysiwygCanvas, let selectedBlockId = canvas.selectedBlockId {
            return .wysiwygBlock(WYSIWYGInspectorModel(
                controller: canvas, blockId: selectedBlockId,
                sourceDirectory: preview.openSiteDirectory, routePath: preview.activeRoute ?? "/"))
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WYSIWYGInspectorModelTests`
Expected: PASS (all tests, old and new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGInspectorModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/WYSIWYGInspectorModelTests.swift
git commit -m "feat(#1672): read/rewrite a selected image block's embedded license"
```

---

### Task 5: License section UI in `WYSIWYGInspectorView`

**Files:**
- Modify: `Sources/AnglesiteApp/WYSIWYGInspectorView.swift`

**Interfaces:**
- Consumes: `WYSIWYGInspectorModel.licenseSectionState` / `.setEmbeddedLicense(_:)` (Task 4), `LicenseCatalog.entries` / `.entry(for:)` (existing, `AnglesiteCore/LicenseCatalog.swift`).

No new automated test — this is a pure SwiftUI rendering layer over state Task 4 already covers; it's verified by the manual pass in Task 6. (`WYSIWYGInspectorModelTests` already proves `licenseSectionState`'s logic; a view test would only re-assert that SwiftUI calls the closures it's given, which isn't a meaningful regression check here.)

- [ ] **Step 1: Add the license section to the `Form` body**

In `Sources/AnglesiteApp/WYSIWYGInspectorView.swift`, change the `body`'s `Form` to include the new section after the existing descriptor list:

```swift
    var body: some View {
        Form {
            if model.descriptors.isEmpty {
                ContentUnavailableView("No editable properties", systemImage: "slider.horizontal.3")
            } else {
                ForEach(model.descriptors, id: \.name) { descriptor in
                    control(for: descriptor)
                }
            }
            licenseSection()
        }
        .formStyle(.grouped)
```

(Leave the rest of `body` — the two `.onChange`/`.onKeyPress` modifiers below `.formStyle(.grouped)` — untouched.)

- [ ] **Step 2: Add the section view**

Add this method to `WYSIWYGInspectorView`, alongside `control(for:)`:

```swift
    /// The embedded-license section (#1672) — shown only when `model.licenseSectionState` is
    /// non-nil (an `img` block whose page doesn't suppress file-level licensing). The picker
    /// offers catalog licenses only, matching `InsertImageLicenseChoice` (resolved default 5:
    /// clearing to "none" is out of scope here).
    @ViewBuilder
    private func licenseSection() -> some View {
        if let state = model.licenseSectionState {
            Section("License") {
                switch state {
                case .disabled(let reason):
                    Text(reason)
                        .foregroundStyle(.secondary)
                case .unsupportedFormat:
                    Text("This file format doesn't support an embedded license.")
                        .foregroundStyle(.secondary)
                case .editable(let current, _, _):
                    if let current {
                        Text(current.name)
                    } else {
                        Text("No license embedded")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Change to", selection: Binding(
                        get: { LicenseCatalog.entry(for: current)?.id ?? LicenseCatalog.entries[0].id },
                        set: { id in
                            guard let entry = LicenseCatalog.entries.first(where: { $0.id == id }) else { return }
                            model.setEmbeddedLicense(entry.ref)
                        })
                    ) {
                        ForEach(LicenseCatalog.entries) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/WYSIWYGInspectorView.swift
git commit -m "feat(#1672): show a license section in the WYSIWYG inspector"
```

---

### Task 6: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: all suites PASS, including `AnglesiteCoreTests` (Tasks 1–2), `AnglesiteAppTests` (Tasks 3–4).

- [ ] **Step 2: Build the app**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (per `docs/testing-macos-app.md`)**

Launch the built app, open a site, enter edit mode on a page, and:
1. Drag an image from Finder onto the canvas → confirm it's placed **and** the inspector immediately shows its License section (proves Task 3's selection-on-drop and Task 4/5's section together).
2. With no license embedded, pick a catalog entry from "Change to" → confirm the section updates to show that license's name.
3. Deselect and reselect the same block → confirm the license still reads back correctly (proves the rewrite round-trips through `readLicense`, not just in-memory state).
4. Drop a WebP image (if available) → confirm the section shows the "doesn't support an embedded license" label rather than hiding.
5. If the site has a non-asserting collection page (e.g. under `/bookmarks/`) with an image block, confirm the license section doesn't appear there at all.

- [ ] **Step 4: No commit** — this task only verifies Tasks 1–5; nothing here changes tracked files.

---

## Self-Review Notes

- **Spec coverage:** `readLicense` (Task 2) — done. `WYSIWYGAssetLocator` (Task 1) — done. Selection on drop (Task 3, resolved default 1) — done. Section visibility rule (Task 4/5, resolved default 2) — done, including the "shown disabled" half for remote/`data:` src. Unsupported-format visibility (resolved default 3) — done (`.unsupportedFormat` case, WebP-covered test). Atomic in-place rewrite (resolved default 4) — done (`Data.write(options: .atomic)`). Clearing out of scope (resolved default 5) — respected: the picker only ever offers `LicenseCatalog.entries`, no "None" choice. Non-asserting-collection suppression (resolved default 6) — done via `LicensingPolicy.suppressesFileEmbedding`. No `AppSettings.lastUsedFileLicenseSelection` write (resolved default 7) — `setEmbeddedLicense` never touches `AppSettings`.
- **Type consistency:** `WYSIWYGAssetLocator.resolve(src:siteDirectory:)` used identically in Task 4's `resolveLicenseSectionState`. `LicenseMetadataEmbedder.readLicense(from:type:)` return type (`LicenseRef?`) matches `WYSIWYGLicenseSectionState.editable(current: LicenseRef?, ...)`. `insertBlockAndSelect`'s signature mirrors `Op.insertBlock`'s parameter list exactly, so the Task 3 call-site swap in `SiteWindow.swift` is a drop-in rename.
