# Embedded License Metadata Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `LicenseMetadataEmbedder`, an `AnglesiteCore` utility that writes a chosen license into a media file's own bytes (image XMP via ImageIO, PDF Info dictionary via PDFKit), so the license survives the file leaving the page that stated it — issue #999, scope item 2 ("Embedded per-file license metadata").

**Architecture:** One pure `Data`-in/`Data`-out utility, no file-system side effects and no in-place mutation of a caller-owned file. Callers (a future attach-time flow, a future drop-and-inspect flow — neither built in this plan) own reading the source bytes and deciding what to do with the embedded result. Two backends behind one entry point: ImageIO (JPEG/PNG/TIFF/HEIC, via `CGImageMetadata`) and PDFKit (`PDFDocument.documentAttributes`). Every other format resolves to `.unsupported`, never a silent no-op and never a thrown error.

**Tech Stack:** Swift 6.4, ImageIO, CoreGraphics, PDFKit, UniformTypeIdentifiers, Swift Testing.

## Global Constraints

- **Apple frameworks only** — ImageIO, CoreGraphics, PDFKit, UniformTypeIdentifiers, Foundation. No third-party dependencies (CONTRIBUTING.md ▸ Code guidelines).
- **Never mutate a caller-supplied file in place.** The whole utility is `Data` in, `Data` out — see the Architecture note above. This is a deliberate response to the issue's own risk callout: "Embedding is a destructive edit to a binary the user may not have a backup of." Pushing the decision of *where the result goes* to the caller means this utility can never destroy a user's original file by construction.
- **Formats with no metadata slot are `.unsupported`, not silently skipped or thrown.** Per issue #999 scope item 2.
- **Video and audio are explicitly out of scope for this plan.** The app has no video/audio import flow at all today — `Insert ▸ Video` and `Insert ▸ Audio` are still `PlannedItem` stubs in `Sources/AnglesiteApp/InsertCommands.swift:123-124` — so there is no caller and no way to build fixture-based tests for an AVFoundation write path. Shipping unverified destructive-metadata-write code for a media type nothing in the app can even import yet is not a trade worth making. `LicenseMetadataEmbedder.supportedTypes` resolves every audio/video UTType to `.unsupported` for now; a follow-up issue should add AVFoundation support once a video/audio import flow exists to test it against.
- This file must stay buildable on the Linux portable target — `AnglesiteCore` is shared with `AnglesiteCorePortableTests` (Package.swift), and ImageIO/PDFKit don't exist off Darwin. Gate the whole new file behind `#if canImport(Darwin)`, following the existing pattern in `Sources/AnglesiteCore/GitInitRunner.swift:1-4`.
- Conventional commits, subject ≤72 chars, reference `#999`.

---

### Task 1: `LicenseMetadataEmbedder` type shape + `.unsupported` path

**Files:**
- Create: `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`
- Test: `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`

**Interfaces:**
- Consumes: `LicenseRef` (existing, `Sources/AnglesiteCore/LicensingStore.swift`) — has `.url: String`, `.name: String`.
- Produces:
  ```swift
  public enum LicenseMetadataEmbedder {
      public enum Result: Sendable, Equatable {
          case embedded(Data)
          case unsupported
      }
      public enum EmbedError: Error, Equatable {
          case unreadable
          case writeFailed
      }
      public static func embed(_ license: LicenseRef, into data: Data, type: UTType) throws -> Result
      public static let supportedTypes: Set<UTType>
  }
  ```

- [ ] **Step 1: Write the failing test for the unsupported path**

Create `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: FAIL to build — `LicenseMetadataEmbedder` doesn't exist yet.

- [ ] **Step 3: Create the type with the `.unsupported` dispatch**

Create `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`:

```swift
#if canImport(Darwin)
import Foundation
import UniformTypeIdentifiers

/// Embeds a chosen license into a media file's own metadata (#999), so the license survives the
/// file being downloaded or shared away from the page that originally stated it.
///
/// Pure `Data`-in/`Data`-out by design: this type never opens, reads, or writes a file on disk
/// itself, and never mutates a caller-supplied file in place. Embedding a license is a
/// destructive edit to a binary the caller may have no backup of — pushing "what happens to the
/// result" onto the caller (write to a copy, use in a data URL, discard) means this utility can
/// never be the thing that destroys a user's original file.
///
/// Only formats with a real metadata slot are written to; everything else is `.unsupported`
/// rather than silently skipped or thrown, per the issue's explicit requirement. Video and audio
/// are `.unsupported` in this version — see the plan doc's Global Constraints for why.
public enum LicenseMetadataEmbedder {
    /// One embed attempt's outcome.
    public enum Result: Sendable, Equatable {
        /// `type` has a metadata slot Anglesite can write to, and it now holds `license`.
        case embedded(Data)
        /// `type` has no metadata slot this embedder writes to (or isn't attempted yet, like
        /// audio/video) — `data` is returned untouched by the caller, not by this type.
        case unsupported
    }

    /// Why an attempt on a *supported* type still failed. Never thrown for a genuinely
    /// unsupported format — that's `Result.unsupported`, not an error.
    public enum EmbedError: Error, Equatable {
        /// `data` couldn't be decoded as the format `type` claims it is.
        case unreadable
        /// The underlying framework refused to produce output bytes.
        case writeFailed
    }

    /// Attempts to embed `license` into `data`, read as `type`.
    ///
    /// - Throws: ``EmbedError`` only when `type` is one of ``supportedTypes`` but the write
    ///   itself failed (malformed input, encoder refusal). A `type` outside ``supportedTypes``
    ///   always returns `.unsupported` and never throws.
    public static func embed(_ license: LicenseRef, into data: Data, type: UTType) throws -> Result {
        guard supportedTypes.contains(type) else { return .unsupported }
        if imageTypes.contains(type) {
            return .embedded(try embedIntoImage(license, data: data, type: type))
        }
        if type == .pdf {
            return .embedded(try embedIntoPDF(license, data: data))
        }
        return .unsupported
    }

    /// UTTypes this embedder can write a license into today.
    public static let supportedTypes: Set<UTType> = imageTypes.union([.pdf])

    private static let imageTypes: Set<UTType> = [.jpeg, .png, .tiff, .heic]

    private static func embedIntoImage(_ license: LicenseRef, data: Data, type: UTType) throws -> Data {
        throw EmbedError.unreadable // placeholder body — replaced in Task 2
    }

    private static func embedIntoPDF(_ license: LicenseRef, data: Data) throws -> Data {
        throw EmbedError.unreadable // placeholder body — replaced in Task 3
    }
}
#endif
```

Note: the two private helper bodies are deliberately stubs in this step — Step 3's only job is to make the `.unsupported` dispatch (Task 1's tests) correct. Tasks 2 and 3 replace those bodies with real implementations and their own tests; leaving them as throwing stubs here means Task 1's own tests (which never reach them) pass honestly without a forward reference to code that doesn't exist yet.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: PASS — all three `LicenseMetadataEmbedderTests` cases green (none of them exercise the stub bodies).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LicenseMetadataEmbedder.swift Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift
git commit -m "feat(#999): add LicenseMetadataEmbedder scaffold with unsupported-format path"
```

---

### Task 2: Image embedding via ImageIO (JPEG/PNG/TIFF/HEIC)

**Files:**
- Modify: `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`
- Test: `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`

**Interfaces:**
- Consumes: `Result`, `EmbedError` (Task 1).
- Produces: real `embedIntoImage(_:data:type:) throws -> Data`.

Verified facts this task relies on (confirmed live against Xcode 27 / Swift 6.4 before writing this plan, not assumed):
- `CGImageSourceCreateWithData`/`CGImageDestinationCreateWithData` round-trip an in-memory PNG.
- The XMP Rights Management Schema namespace `http://ns.adobe.com/xap/1.0/rights/` (prefix `xmpRights`), fields `WebStatement` (plain string — verified round-trips cleanly) and `Marked` (verified round-trips as the string `"True"`), is the right home for a license URL and a "this file's rights are marked" flag. `UsageTerms` in the same namespace is the conventional field for a human-readable rights statement (the license name).
- Passing the source image's own `CGImageSourceCopyPropertiesAtIndex` dictionary as the `options` argument to `CGImageDestinationAddImageAndMetadata`, with `kCGImageDestinationMergeMetadata: true` added to it, preserves existing image properties (verified: `kCGImagePropertyOrientation` and `kCGImagePropertyDPIWidth` both survived a round trip through this exact call shape) instead of the embed silently stripping them.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift` (inside the `@Suite` struct):

```swift
    private func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func pngData(properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeTestImage(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("embedding into a PNG returns .embedded with readable license metadata")
    func embedsIntoPNG() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: pngData(), type: .png)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let source = CGImageSourceCreateWithData(outData as CFData, nil)!
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)!
        let webStatementTag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString)
        #expect(CGImageMetadataTagCopyValue(webStatementTag!) as? String == license.url)
        let markedTag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpRights:Marked" as CFString)
        #expect(markedTag != nil)
    }

    @Test("embedding preserves existing image properties like orientation")
    func preservesExistingProperties() throws {
        let original = pngData(properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 240,
        ])
        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: .png)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let source = CGImageSourceCreateWithData(outData as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] as? Int == 6)
        #expect(props?[kCGImagePropertyDPIWidth] as? Int == 240)
    }

    @Test("unreadable image bytes throw .unreadable rather than returning .unsupported")
    func unreadableImageThrows() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(throws: LicenseMetadataEmbedder.EmbedError.unreadable) {
            _ = try LicenseMetadataEmbedder.embed(license, into: garbage, type: .png)
        }
    }
```

Add the two missing imports at the top of the test file:

```swift
import CoreGraphics
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: FAIL — `embedsIntoPNG`/`preservesExistingProperties` fail because `embedIntoImage` still throws `.unreadable` unconditionally (the Task 1 stub); `unreadableImageThrows` already passes incidentally (also worth confirming it fails for the *right* reason once real code lands, not just because everything throws right now).

- [ ] **Step 3: Implement `embedIntoImage`**

Replace the stub body in `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`:

```swift
    private static func embedIntoImage(_ license: LicenseRef, data: Data, type: UTType) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EmbedError.unreadable
        }

        let existingProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let existingMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let metadata = existingMetadata.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()

        let xmpRightsNamespace = "http://ns.adobe.com/xap/1.0/rights/" as CFString
        // Registration can no-op (return false) when the namespace is already present in a
        // metadata copy carried over from `existingMetadata` — that's fine, not a failure.
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, xmpRightsNamespace, "xmpRights" as CFString, nil)

        guard
            let webStatementTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "WebStatement" as CFString, .string,
                license.url as CFTypeRef),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:WebStatement" as CFString, webStatementTag),
            let usageTermsTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "UsageTerms" as CFString, .string,
                license.name as CFTypeRef),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:UsageTerms" as CFString, usageTermsTag),
            let markedTag = CGImageMetadataTagCreate(
                xmpRightsNamespace, "xmpRights" as CFString, "Marked" as CFString, .string, kCFBooleanTrue),
            CGImageMetadataSetTagWithPath(metadata, nil, "xmpRights:Marked" as CFString, markedTag)
        else {
            throw EmbedError.writeFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw EmbedError.writeFailed
        }
        var options = existingProperties
        options[kCGImageDestinationMergeMetadata] = true
        CGImageDestinationAddImageAndMetadata(destination, cgImage, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EmbedError.writeFailed }
        return output as Data
    }
```

Add the two frameworks this needs to the top of `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift` (inside the existing `#if canImport(Darwin)` block, after `import Foundation` and `import UniformTypeIdentifiers`):

```swift
import ImageIO
import CoreGraphics
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: PASS — all cases, including the two new ones and the earlier `.unsupported`/scope tests from Task 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LicenseMetadataEmbedder.swift Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift
git commit -m "feat(#999): embed license XMP metadata into images via ImageIO"
```

---

### Task 3: PDF embedding via PDFKit

**Files:**
- Modify: `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`
- Test: `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`

**Interfaces:**
- Consumes: `Result`, `EmbedError` (Task 1).
- Produces: real `embedIntoPDF(_:data:) throws -> Data`.

Verified fact this task relies on: `PDFDocument(data:)` → mutate `.documentAttributes` (adding a custom `"Rights"` key alongside whatever keys already exist) → `.dataRepresentation()` round-trips both the new key and the document's page count correctly (verified live: a 1-page PDF stayed 1 page, and a custom `"Rights"` string survived the round trip). This is an Info-dictionary key, not a true XMP metadata stream — PDFKit's public API doesn't expose XMP packet writing, and retrofitting XMP into an existing PDF would require re-serializing every page through a fresh `CGContext`, which risks losing forms/links/tags. The Info-dictionary route is lower-fidelity but zero-risk to page content; call this out explicitly in the PR description as a known trade-off for owner review, per the issue's "goes through owner review" expectation.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift`:

```swift
    private func onePagePDFData() -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: 50, height: 50)
        let out = NSMutableData()
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    @Test("embedding into a PDF returns .embedded with the license in documentAttributes")
    func embedsIntoPDF() throws {
        let result = try LicenseMetadataEmbedder.embed(license, into: onePagePDFData(), type: .pdf)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let doc = PDFDocument(data: outData)!
        let rights = doc.documentAttributes?["Rights"] as? String
        #expect(rights?.contains(license.name) == true)
        #expect(rights?.contains(license.url) == true)
    }

    @Test("embedding into a PDF preserves page count and existing attributes")
    func preservesPDFFidelity() throws {
        let original = onePagePDFData()
        let originalDoc = PDFDocument(data: original)!
        let originalAttrs = originalDoc.documentAttributes ?? [:]

        let result = try LicenseMetadataEmbedder.embed(license, into: original, type: .pdf)
        guard case .embedded(let outData) = result else {
            Issue.record("expected .embedded, got \(result)")
            return
        }
        let outDoc = PDFDocument(data: outData)!
        #expect(outDoc.pageCount == originalDoc.pageCount)
        for (key, _) in originalAttrs {
            #expect(outDoc.documentAttributes?[key] != nil, "lost existing attribute \(key)")
        }
    }

    @Test("unreadable PDF bytes throw .unreadable")
    func unreadablePDFThrows() {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(throws: LicenseMetadataEmbedder.EmbedError.unreadable) {
            _ = try LicenseMetadataEmbedder.embed(license, into: garbage, type: .pdf)
        }
    }
```

Add the missing import at the top of the test file:

```swift
import PDFKit
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: FAIL — the three new PDF tests fail because `embedIntoPDF` still throws `.unreadable` unconditionally.

- [ ] **Step 3: Implement `embedIntoPDF`**

Replace the stub body in `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift`:

```swift
    private static func embedIntoPDF(_ license: LicenseRef, data: Data) throws -> Data {
        guard let document = PDFDocument(data: data) else { throw EmbedError.unreadable }
        var attributes = document.documentAttributes ?? [:]
        attributes["Rights"] = "\(license.name) — \(license.url)"
        document.documentAttributes = attributes
        guard let output = document.dataRepresentation() else { throw EmbedError.writeFailed }
        return output
    }
```

Add the framework import to the top of `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift` (inside the `#if canImport(Darwin)` block):

```swift
import PDFKit
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicenseMetadataEmbedderTests`
Expected: PASS — every case in `LicenseMetadataEmbedderTests` green.

- [ ] **Step 5: Run the full AnglesiteCoreTests suite**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS — confirms the new file doesn't break anything else in the target, and that `#if canImport(Darwin)` gating didn't accidentally leave a reference reachable from portable code.

- [ ] **Step 6: Confirm the Linux portable target still builds** (only if a Linux toolchain is available in this environment; otherwise note in the PR description that this step needs CI confirmation)

Run: `swift build --package-path . --destination <linux-destination-file>` or rely on CI's Linux leg — the key check is that `Sources/AnglesiteCore/LicenseMetadataEmbedder.swift` compiles to nothing (via `#if canImport(Darwin)`) rather than failing to find `ImageIO`/`PDFKit` on Linux.
Expected: no `ImageIO`/`PDFKit`/`CoreGraphics` import errors from this file on the Linux leg.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/LicenseMetadataEmbedder.swift Tests/AnglesiteCoreTests/LicenseMetadataEmbedderTests.swift
git commit -m "feat(#999): embed license metadata into PDFs via PDFKit"
```

---

## Self-Review Notes

- **Spec coverage:** Issue #999 scope item 2 ("write the license into the file itself for formats that support it — images, video, audio, and PDF... formats with no license slot are surfaced as unsupported rather than silently skipped") is covered for images and PDF (real support) and for video/audio (explicit `.unsupported`, with the reasoning and a follow-up recommendation recorded in Global Constraints rather than silently dropped).
- **Not covered by this plan, deliberately:** wiring this utility into any UI (attach-time checkbox, drop-and-inspect) — that's downstream work with its own plan(s), since this utility has no caller yet on its own. AVFoundation audio/video support — explicitly deferred, see Global Constraints.
- **Type consistency check:** `Result`/`EmbedError` names and cases are identical across all three tasks' code blocks (`.embedded(Data)`/`.unsupported`, `.unreadable`/`.writeFailed`) — verified by re-reading Tasks 1-3 together before finalizing this plan.
