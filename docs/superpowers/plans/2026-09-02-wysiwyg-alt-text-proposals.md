# WYSIWYG AI Services — Alt-Text Proposals (PR 1 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Finder/Photos image drop onto the WYSIWYG canvas, propose alt text with the
on-device vision model and seed it directly into the `insertBlock` op before submission — one
op, one undo entry, reviewable live in the inspector.

**Architecture:** A new `WYSIWYGAltTextProposer` in `AnglesiteCore` wraps
`FoundationModelAssistant.generateStructured(prompt:imageURL:context:resultType:)` behind an
injectable closure (mirroring the existing `AltTextGenerator`'s testable shape), returning `nil`
on any failure. A small pure helper on `WYSIWYGImageAssetIngestor` resolves the ingested asset's
on-disk file URL. The app-side WYSIWYG image-drop handler in `SiteWindow.swift` calls the
proposer between asset ingestion and block insertion and writes the result into the new block's
`props` before calling `insertBlockAndSelect`.

**Tech Stack:** Swift 6.4 / Xcode 27, FoundationModels (`@Generable`/`@Guide` guided generation,
vision attachment), Swift Testing.

**Spec:** [`docs/superpowers/specs/2026-09-02-wysiwyg-ai-services-design.md`](../specs/2026-09-02-wysiwyg-ai-services-design.md)
§3 (alt-text proposals only — §4 writing help and §5 block-type suggestions are separate,
later PRs per the spec's §9 rollout). Tracking issue: [#1227](https://github.com/Anglesite/Anglesite/issues/1227),
part of epic [#1221](https://github.com/Anglesite/Anglesite/issues/1221).

## Global Constraints

- **This PR does NOT close #1227.** Commits reference it without a closing keyword
  (`feat(#1227): ...`, never `fix`/`close`/`resolve`) — PR 3 (block-type suggestions) is the one
  that closes the tracking issue, per `CONTRIBUTING.md`'s multi-PR tracking-issue guidance.
- **Toolchain gate:** `WYSIWYGAltTextProposer` and its test file wrap FoundationModels-touching
  code in `#if compiler(>=6.4) && canImport(FoundationModels)`, matching `AltTextGenerator.swift`
  / `AltTextGeneratorTests.swift` exactly — CI's Xcode 26.3 `swift test` run compiles and runs
  everything else in `AnglesiteCoreTests` unaffected. `WYSIWYGImageAssetIngestor`'s new helper
  (Task 1) needs no gate — the existing type isn't gated (plain `Foundation`/
  `UniformTypeIdentifiers`).
- **No `ContentAssistantFactory.make(tier:)` here.** The vision-attachment overload
  (`generateStructured(prompt:imageURL:context:resultType:)`) lives only on the concrete
  `FoundationModelAssistant`, not on the `ContentAssistant` protocol that factory returns.
  Production constructs `FoundationModelAssistant(tier: .onDevice)` directly — exactly what the
  existing `AltTextGenerator` wiring in `SiteAssistantSessionFactory.swift` already does for the
  legacy overlay editor. `WYSIWYGAltTextProposer` itself is a plain injectable-closure struct
  (`Producer` typealias), not a protocol+factory pair.
- **Silent degrade on failure (spec §3):** any error inside `WYSIWYGAltTextProposer.propose`
  (model unavailable, vision call failure, timeout) yields `nil`, never a thrown error out of
  `propose` itself. The image insert always proceeds with whatever alt text `propose` returned
  (`""` on failure) — never blocks, never surfaces an error to the owner.
- **No `isEnabled` toggle.** Unlike `AltTextGenerator` (which gates on
  `AppSettings.shared.autoGenerateAltText`), the proposer always attempts a proposal when called
  — the spec doesn't call for a separate settings toggle for the WYSIWYG path, and introducing
  one is out of scope for this PR.
- **Tests:** new Core tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in
  `Tests/AnglesiteCoreTests/`. Run with:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter <Suite>`
  (the wrapper serializes with other on-Mac `swift test` runs — see `CONTRIBUTING.md` ▸ Testing).
  If a run hangs with no output, check `pgrep -fl swift-test` for a stale process holding the
  `.build` lock.
- **App-target task (Task 3) has no CI coverage.** `Sources/AnglesiteApp` is only tested by local
  `swift test` on Xcode 27 (never CI, per `CONTRIBUTING.md`), and this task's change is in a
  `.onDrop` closure that isn't unit-testable in isolation without a live `WKWebView`/canvas. Its
  step is a build + a manual smoke test via `docs/testing-macos-app.md`, not a new automated
  test — the Core logic it wires together (Tasks 1-2) already carries full unit coverage.
- **Worktree:** this plan executes in `.claude/worktrees/issue-1241-960cf3` on branch
  `claude/issue-1227-888736`. Run `xcodegen generate` before any app-target build (the
  `.xcodeproj` is gitignored and this is a fresh worktree) — `scripts/build-app.sh` does this for
  you.
- **Commits:** conventional commits, one per task, ending with
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

---

## Task 1: `WYSIWYGImageAssetIngestor.fileURL(forAssetPath:siteDirectory:)`

**Files:**
- Modify: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGImageAssetIngestorTests.swift` (append)

**Interfaces:**
- Consumes: nothing new — pure string/URL manipulation over `ingest(bytes:siteDirectory:)`'s own
  `public/images/<name>` write convention.
- Produces: `WYSIWYGImageAssetIngestor.fileURL(forAssetPath: String, siteDirectory: URL) -> URL`
  — used by Task 3 to turn the root-relative path `ingest` returns (e.g.
  `/images/wysiwyg-abcd1234.jpg`) back into the on-disk file the vision model needs to read.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/WYSIWYGImageAssetIngestorTests.swift` (inside the existing
`WYSIWYGImageAssetIngestorTests` struct, after `logsUnrecognizedFormat`):

```swift
    @Test("resolves an ingested asset path back to its on-disk file under public/")
    func resolvesFileURLForAssetPath() {
        let siteDirectory = URL(fileURLWithPath: "/tmp/my-site", isDirectory: true)
        let url = WYSIWYGImageAssetIngestor.fileURL(
            forAssetPath: "/images/wysiwyg-abcd1234.jpg", siteDirectory: siteDirectory)
        #expect(url.path == "/tmp/my-site/public/images/wysiwyg-abcd1234.jpg")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGImageAssetIngestorTests`
Expected: FAIL — `WYSIWYGImageAssetIngestor` has no member `fileURL(forAssetPath:siteDirectory:)`.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift`, add this method to the
`WYSIWYGImageAssetIngestor` enum, right after `ingest(bytes:siteDirectory:fileManager:logCenter:)`
(before the closing brace of that method's block, i.e. after its `return "/images/\(name)"` line):

```swift
    /// Resolves an `ingest(bytes:siteDirectory:)`-returned root-relative asset path (e.g.
    /// `/images/wysiwyg-abcd1234.jpg`) back to the on-disk file under `public/` — the inverse of
    /// the `public/images/<name>` convention `ingest` itself writes to. Used by callers (alt-text
    /// proposals, #1227) that need a real file URL for the just-ingested image rather than the
    /// root-relative path the canvas stores in the block's `src` prop.
    public static func fileURL(forAssetPath assetPath: String, siteDirectory: URL) -> URL {
        let relative = assetPath.hasPrefix("/") ? String(assetPath.dropFirst()) : assetPath
        return siteDirectory
            .appendingPathComponent("public", isDirectory: true)
            .appendingPathComponent(relative)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGImageAssetIngestorTests`
Expected: PASS (4 tests — the 3 existing plus this one).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGImageAssetIngestor.swift Tests/AnglesiteCoreTests/WYSIWYGImageAssetIngestorTests.swift
git commit -m "$(cat <<'EOF'
feat(#1227): add WYSIWYGImageAssetIngestor asset-path resolver

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `WYSIWYGAltTextProposer`

**Files:**
- Create: `Sources/AnglesiteCore/WYSIWYG/WYSIWYGAltTextProposer.swift`
- Test: `Tests/AnglesiteCoreTests/WYSIWYGAltTextProposerTests.swift`

**Interfaces:**
- Consumes: `GeneratedAltText` (existing, `GenerableTypes.swift`), `AssistantContext` (existing,
  `ContentAssistant.swift`).
- Produces: `WYSIWYGAltTextProposer.Producer` typealias
  (`@Sendable (_ imageURL: URL, _ context: AssistantContext) async throws -> GeneratedAltText`);
  `WYSIWYGAltTextProposer.init(produce: @escaping Producer, log: @escaping @Sendable (String) async -> Void = { _ in })`;
  `WYSIWYGAltTextProposer.propose(imageURL: URL, context: AssistantContext) async -> GeneratedAltText?`
  — Task 3's only consumption point.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/WYSIWYGAltTextProposerTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test — `WYSIWYGAltTextProposer` references `GeneratedAltText`
// (`@Generable`, Xcode-27 only). The logic here is model-free: the vision call is injected as a
// closure.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("WYSIWYGAltTextProposer")
struct WYSIWYGAltTextProposerTests {
    private let context = AssistantContext(
        siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/my-site", isDirectory: true))
    private let imageURL = URL(fileURLWithPath: "/tmp/my-site/public/images/hero.jpg")

    private actor LogRecorder {
        private(set) var messages: [String] = []
        func record(_ message: String) { messages.append(message) }
    }

    @Test("returns the produced alt text on success")
    func returnsProducedAltText() async {
        let proposer = WYSIWYGAltTextProposer(produce: { _, _ in
            GeneratedAltText(altText: "A white circle on a blue square", isDecorative: false)
        })
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result?.altText == "A white circle on a blue square")
        #expect(result?.isDecorative == false)
    }

    @Test("passes the image URL and context straight through to produce")
    func passesArgumentsThrough() async {
        var seenURL: URL?
        var seenSiteID: String?
        let proposer = WYSIWYGAltTextProposer(produce: { url, ctx in
            seenURL = url
            seenSiteID = ctx.siteID
            return GeneratedAltText(altText: "x", isDecorative: false)
        })
        _ = await proposer.propose(imageURL: imageURL, context: context)
        #expect(seenURL == imageURL)
        #expect(seenSiteID == "site-1")
    }

    @Test("returns nil and logs when the vision call throws")
    func returnsNilAndLogsOnFailure() async {
        struct Boom: Error {}
        let logs = LogRecorder()
        let proposer = WYSIWYGAltTextProposer(
            produce: { _, _ in throw Boom() },
            log: { text in await logs.record(text) }
        )
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result == nil)
        let recorded = await logs.messages
        #expect(recorded.count == 1)
        #expect(recorded.first?.contains("alt-text proposal failed") == true)
    }

    @Test("defaults to a no-op logger when none is given")
    func defaultLoggerIsNoOp() async {
        struct Boom: Error {}
        let proposer = WYSIWYGAltTextProposer(produce: { _, _ in throw Boom() })
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result == nil)
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGAltTextProposerTests`
Expected: FAIL — cannot find `WYSIWYGAltTextProposer` in scope.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WYSIWYG/WYSIWYGAltTextProposer.swift
import Foundation

// Gated to the Xcode-27 toolchain — `GeneratedAltText` is `@Generable` (FoundationModels), absent
// at runtime on CI (#128) — and to canImport for genuine off-Darwin portability (cross-platform
// port design §5). Same pattern as `AltTextGenerator.swift` / `FoundationModelAssistant.swift`.
#if compiler(>=6.4) && canImport(FoundationModels)

/// Proposes alt text for a just-ingested WYSIWYG image-drop (design doc §3, #1227): the on-device
/// vision model looks at the dropped image and returns a ``GeneratedAltText`` to seed the new
/// `insertBlock` op's `alt` prop *before* it is submitted — one op, one undo entry, reviewable
/// live in the inspector like any other prop. Unlike the legacy overlay's `AltTextGenerator`,
/// there is no follow-up edit to apply: the caller writes the result straight into the op it's
/// about to submit.
///
/// Best-effort by design: any failure (model unavailable, vision call error, timeout) yields
/// `nil` rather than throwing, so a drop never blocks or errors on a failed proposal — the image
/// still inserts with empty alt text exactly as it did before this feature existed.
public struct WYSIWYGAltTextProposer: Sendable {
    /// Production wraps `FoundationModelAssistant.generateStructured(prompt:imageURL:context:resultType:)`.
    public typealias Producer = @Sendable (_ imageURL: URL, _ context: AssistantContext) async throws -> GeneratedAltText

    private let produce: Producer
    private let log: @Sendable (String) async -> Void

    /// `log` defaults to a no-op because failures here are best-effort by design; production
    /// passes the debug-pane logger so a swallowed failure still leaves a trace ("logs are
    /// sacred").
    public init(produce: @escaping Producer, log: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.produce = produce
        self.log = log
    }

    /// Proposes alt text for the image at `imageURL`, or `nil` on any failure.
    public func propose(imageURL: URL, context: AssistantContext) async -> GeneratedAltText? {
        do {
            return try await produce(imageURL, context)
        } catch {
            await log("alt-text proposal failed for \(imageURL.path): \(error)")
            return nil
        }
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh --filter WYSIWYGAltTextProposerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WYSIWYG/WYSIWYGAltTextProposer.swift Tests/AnglesiteCoreTests/WYSIWYGAltTextProposerTests.swift
git commit -m "$(cat <<'EOF'
feat(#1227): add WYSIWYGAltTextProposer for alt-text proposals

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire the proposal into the WYSIWYG image-drop flow

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:82` (add an accessor right after the
  `conventionsEngine` property)
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:1752-1799` (the `.onDrop` closure)

**Interfaces:**
- Consumes: `WYSIWYGAltTextProposer` + `Producer` (Task 2),
  `WYSIWYGImageAssetIngestor.fileURL(forAssetPath:siteDirectory:)` (Task 1), existing
  `AltTextPromptBuilder.build(basePrompt:conventions:)`, existing
  `FoundationModelAssistant.generateStructured(prompt:imageURL:context:resultType:)`, existing
  `ProjectConventionsEngine.conventions(siteID:) -> ProjectConventions?`.
- Produces: `SiteWindowModel.currentProjectConventions() -> ProjectConventions?` — internal,
  consumed only by this task's `SiteWindow.swift` change.

- [ ] **Step 1: Add the conventions accessor to `SiteWindowModel`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, immediately after the existing property
declaration

```swift
    private let conventionsEngine: ProjectConventionsEngine
```

(currently line 82), add:

```swift

    /// The current site's learned voice/style conventions, if any — reused by WYSIWYG AI
    /// services (starting with alt-text proposals, #1227) that need `AltTextPromptBuilder`-style
    /// guidance but sit outside `SiteAssistantSessionFactory`'s chat/postProcessor wiring. `nil`
    /// before a site has finished opening.
    func currentProjectConventions() -> ProjectConventions? {
        guard let siteID = site?.id else { return nil }
        return conventionsEngine.conventions(siteID: siteID)
    }
```

- [ ] **Step 2: Wire the proposer into the drop handler**

In `Sources/AnglesiteApp/SiteWindow.swift`, this is the current `.onDrop` closure (lines
1752-1799):

```swift
            .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers, location in
                guard let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView,
                      let siteDirectory = model.preview.openSiteDirectory
                else { return false }
                let route = model.preview.activeRoute ?? "/"
                Task {
                    let logCenter = LogCenter.shared
                    guard var bytes = await WYSIWYGImageDropHandler.loadImageBytes(from: providers) else { return }

                    // #1671: embed the last-used file license (mirroring `Insert ▸ Image…`) before
                    // `ingest` writes the copy — never a picker at drop time, and never anything
                    // when no selection was persisted, per #999 §4's resolved defaults.
                    let policy = (try? LicensingStore(sourceDirectory: siteDirectory).load()) ?? LicensingPolicy()
                    let license = WYSIWYGDropLicenseResolver.resolve(
                        policy: policy, route: route, lastUsed: AppSettings.shared.lastUsedFileLicenseSelection)
                    if let license, let type = WYSIWYGImageAssetIngestor.sniffedUTType(bytes) {
                        do {
                            if case .embedded(let embedded) = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type) {
                                bytes = embedded
                            }
                        } catch {
                            await logCenter.append(
                                source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                                text: "failed to embed license metadata into dropped image: \(error.localizedDescription)")
                        }
                    }

                    let assetPath: String?
                    do {
                        assetPath = try WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: siteDirectory)
                    } catch {
                        await logCenter.append(
                            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                            text: "failed to write dropped image into public/images: \(error.localizedDescription)")
                        return
                    }
                    guard let assetPath else { return }
                    guard let target = await resolveWYSIWYGDropTarget(at: location, webView: webView) else { return }
                    let newId = UUID().uuidString
                    // Alt-text proposal is stubbed empty — the real proposal is on-device AI
                    // (#1227, out of scope here per the design doc).
                    let content = BlockNodeContent(
                        kind: .astro, componentName: "img", props: ["src": .string(assetPath), "alt": .string("")],
                        slots: [:], sourceSpan: [0, 0])
                    await canvas.insertBlockAndSelect(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content)
                }
                return true
            }
```

Replace it with:

```swift
            .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers, location in
                guard let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView,
                      let siteDirectory = model.preview.openSiteDirectory, let siteID = model.preview.openSiteID
                else { return false }
                let route = model.preview.activeRoute ?? "/"
                let conventions = model.currentProjectConventions()
                Task {
                    let logCenter = LogCenter.shared
                    guard var bytes = await WYSIWYGImageDropHandler.loadImageBytes(from: providers) else { return }

                    // #1671: embed the last-used file license (mirroring `Insert ▸ Image…`) before
                    // `ingest` writes the copy — never a picker at drop time, and never anything
                    // when no selection was persisted, per #999 §4's resolved defaults.
                    let policy = (try? LicensingStore(sourceDirectory: siteDirectory).load()) ?? LicensingPolicy()
                    let license = WYSIWYGDropLicenseResolver.resolve(
                        policy: policy, route: route, lastUsed: AppSettings.shared.lastUsedFileLicenseSelection)
                    if let license, let type = WYSIWYGImageAssetIngestor.sniffedUTType(bytes) {
                        do {
                            if case .embedded(let embedded) = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type) {
                                bytes = embedded
                            }
                        } catch {
                            await logCenter.append(
                                source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                                text: "failed to embed license metadata into dropped image: \(error.localizedDescription)")
                        }
                    }

                    let assetPath: String?
                    do {
                        assetPath = try WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: siteDirectory)
                    } catch {
                        await logCenter.append(
                            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                            text: "failed to write dropped image into public/images: \(error.localizedDescription)")
                        return
                    }
                    guard let assetPath else { return }
                    guard let target = await resolveWYSIWYGDropTarget(at: location, webView: webView) else { return }
                    let newId = UUID().uuidString

                    // #1227: propose alt text with the on-device vision model, seeding it straight
                    // into the insertBlock op below rather than a follow-up edit — one op, one
                    // undo entry, reviewable live in the inspector. Silent degrade to empty alt
                    // text on any failure (model unavailable, vision call error, timeout).
                    let proposer = WYSIWYGAltTextProposer(
                        produce: { imageURL, context in
                            try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                                prompt: AltTextPromptBuilder.build(
                                    basePrompt: "Generate concise, descriptive alt text for this image as it would appear on a website. If the image is purely decorative, mark it decorative and use empty alt text.",
                                    conventions: conventions
                                ),
                                imageURL: imageURL,
                                context: context,
                                resultType: GeneratedAltText.self
                            )
                        },
                        log: { text in
                            await logCenter.append(
                                source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr, text: text)
                        }
                    )
                    let proposedAlt = await proposer.propose(
                        imageURL: WYSIWYGImageAssetIngestor.fileURL(forAssetPath: assetPath, siteDirectory: siteDirectory),
                        context: AssistantContext(siteID: siteID, siteDirectory: siteDirectory, currentPageRoute: route)
                    )
                    var props: [String: PropValue] = [
                        "src": .string(assetPath),
                        "alt": .string(proposedAlt?.isDecorative == true ? "" : (proposedAlt?.altText ?? "")),
                    ]
                    if proposedAlt?.isDecorative == true {
                        props["role"] = .string("presentation")
                    }
                    let content = BlockNodeContent(
                        kind: .astro, componentName: "img", props: props, slots: [:], sourceSpan: [0, 0])
                    await canvas.insertBlockAndSelect(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content)
                }
                return true
            }
```

- [ ] **Step 3: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds with no new warnings from `SiteWindowModel.swift` or `SiteWindow.swift`.

- [ ] **Step 4: Run the full Core suite to confirm no regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer scripts/swift-test.sh`
Expected: PASS — Tasks 1-2's new suites plus the existing suite, unaffected by this app-only task.

- [ ] **Step 5: Manual smoke test**

Per `docs/testing-macos-app.md`, launch the built app, open (or create) a site, turn on Site ▸
Edit Page, and drag an image from Finder onto the canvas. Confirm:
- The image block inserts with the dropped image visible.
- The inspector's alt-text field is pre-filled with a plausible on-device-generated description
  (not empty) shortly after drop, without any extra click.
- Edit ▸ Undo removes the whole inserted block (image + alt text) in one step.
- On a Mac without Apple Intelligence available (or with it disabled in System Settings), the
  same drop still inserts the image with empty alt text — no crash, no error dialog, no hang.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(cat <<'EOF'
feat(#1227): propose alt text inline on WYSIWYG image drop

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-plan

- Open the PR referencing #1227 without a closing keyword (per Global Constraints), using
  `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings per `CONTRIBUTING.md`.
- This PR leaves brand-voice/`ProjectConventions` guidance wired only as far as
  `SiteWindowModel.currentProjectConventions()` reaching the new drop-site prompt — matching the
  spec's claim that `AltTextPromptBuilder` "already folds in `ProjectConventions` guidance."
- PR 2 (writing help) and PR 3 (block-type suggestions) are separate plans, written after this
  one lands.
