# iOS UIKit Siri-Annotation Provider Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the iOS thin client (`AnglesiteMobile`) the same Siri onscreen-entity resolution the macOS app already has — "this heading", "that image" — by porting the AppKit-only `PreviewAnnotationProvider` → `[AppEntityUIElement]` shaping to UIKit and wiring it into the iOS preview `WKWebView`.

**Architecture:** The shared `PreviewAnnotationProvider` (mapping rules, `update()`, `annotations()`) already lives in `Sources/AnglesiteIntents/PreviewAnnotationProvider.swift`, platform-neutral. Only the final step — shaping stored `(rect, entity)` pairs into `[AppEntityUIElement]` via the `_AppIntents_{AppKit,UIKit}` cross-import overlay — is platform-specific, and only the AppKit half exists today (`PreviewAnnotationProviderUIElements.swift`, `#if os(macOS)`). This plan adds the UIKit twin and wires it through `RemoteSessionModel` → `RemoteSessionScreen`'s `WKWebView`, mirroring exactly how `SiteWindowModel`/`PreviewView` do it on macOS.

**Tech Stack:** Swift 6.4 / Xcode 27, AppIntents (`_AppIntents_UIKit` cross-import overlay), WebKit (`WKWebView.appEntityUIElementProvider`), XcodeGen (`project.yml`).

## Global Constraints

- iOS 27.0+ deployment target (per `Package.swift` / `project.yml`).
- `AnglesiteIntents` target has no per-platform restriction in `Package.swift` — it already builds for iOS as a library; only `AnglesiteMobile`'s `project.yml` dependency list is missing it.
- `AppEntityUIElement`/`AppEntityUIElementsContext` require the `#if compiler(>=6.4)` gate — CI's `macos-15` runner ships an older toolchain without these symbols (same gate the existing AppKit file uses).
- No new SwiftPM test target: `Sources/AnglesiteMobile` is Xcode-app-target-only (not in `Package.swift`), so `RemoteSessionModel`/`RemoteSessionScreen` changes are verified by `xcodebuild`, not `swift test`.
- Conventional commits, ≤72-char subject, reference `#1386` (this issue) and `#71`.

---

### Task 1: Link `AnglesiteIntents` into the `AnglesiteMobile` Xcode target

**Files:**
- Modify: `project.yml:208-214` (the `AnglesiteMobile.dependencies` list)

**Interfaces:**
- Produces: `AnglesiteMobile` sources can now `import AnglesiteIntents`. Nothing else in this task changes behavior.

- [ ] **Step 1: Add the dependency**

In `project.yml`, `AnglesiteMobile`'s `dependencies:` block currently reads:

```yaml
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
      - package: Anglesite
        product: AnglesiteIOS
```

Add `AnglesiteIntents` (matching the `Anglesite` (macOS) target's own dependency list at `project.yml:133-141`):

```yaml
    dependencies:
      - package: Anglesite
        product: AnglesiteCore
      - package: Anglesite
        product: AnglesiteBridge
      - package: Anglesite
        product: AnglesiteIntents
      - package: Anglesite
        product: AnglesiteIOS
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate --quiet`

- [ ] **Step 3: Verify the app target still builds with the new (as yet unused) dependency**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add project.yml Anglesite.xcodeproj/project.pbxproj
git commit -m "feat(#1386): link AnglesiteIntents into AnglesiteMobile"
```

---

### Task 2: UIKit twin of `PreviewAnnotationProviderUIElements`

**Files:**
- Create: `Sources/AnglesiteIntents/PreviewAnnotationProviderUIElementsIOS.swift`
- Modify: `Sources/AnglesiteIntents/PreviewAnnotationProviderUIElements.swift:1-4` (header comment — remove the stale "future work tracked on #71" claim)

**Interfaces:**
- Consumes: `PreviewAnnotationProvider.annotations() -> [(rect: CGRect, entity: any AppEntity)]` (existing, `Sources/AnglesiteIntents/PreviewAnnotationProvider.swift:85-87`); the concrete entity types `PageEntity`, `PostEntity`, `ImageEntity`, `ElementEntity` (existing).
- Produces: `PreviewAnnotationProvider.uiElements(for context: AppEntityUIElementsContext) -> [AppEntityUIElement]` and `PreviewAnnotationProvider.uiElements(forRequests:) -> [AppEntityUIElement]`, available under `#if os(iOS)` — same method names as the macOS extension (they're on the same type, gated by mutually exclusive `#if os(macOS)`/`#if os(iOS)`, so call sites never need to know which platform they're on).

- [ ] **Step 1: Write the new file**

```swift
// UIKit-only half of `PreviewAnnotationProvider` (mirrors B.4 / #148 for iOS, tracked on #1386):
// the `AppEntityUIElement` surface comes from the `_AppIntents_UIKit` cross-import overlay, so
// this file is iOS-only. The macOS equivalent lives in `PreviewAnnotationProviderUIElements.swift`
// — same shape, `AppKit` swapped for `UIKit`. Keeping them as separate files (rather than one
// file with a platform-conditional import) matches that file's existing split and keeps each
// half greppable by the framework it depends on.
#if os(iOS)
import AppIntents
import UIKit
import CoreGraphics
import Foundation

// `AppEntityUIElement` and `AppEntityUIElementsContext` are defined by the `_AppIntents_UIKit`
// cross-import overlay, which auto-loads when both `AppIntents` and `UIKit` are imported
// explicitly in the consuming file. Swift's `MemberImportVisibility` upcoming-feature (enabled
// by the iOS 27 SDK module flags) requires both base modules here — transitive imports through
// other frameworks aren't enough, and the compile error blames the type rather than the missing
// import. See `PreviewAnnotationProviderUIElements.swift` for the macOS/AppKit precedent this
// mirrors line-for-line.
#if compiler(>=6.4)
extension PreviewAnnotationProvider {
    /// Shape annotations into `[AppEntityUIElement]` for `WKWebView.appEntityUIElementProvider`
    /// on iOS. The system asks for either `.visible(rect:)` — return everything whose stored
    /// rect intersects `rect` — or `.selected`. We don't track an in-page selection model (the
    /// overlay's hover/click states are transient), so `.selected` yields `[]`.
    public func uiElements(for context: AppEntityUIElementsContext) -> [AppEntityUIElement] {
        uiElements(forRequests: context.requests)
    }

    /// Inner helper taking the raw request set so tests can drive it directly —
    /// `AppEntityUIElementsContext` has no public initializer.
    public func uiElements(
        forRequests requests: Set<AppEntityUIElementsContext.ElementsRequest>
    ) -> [AppEntityUIElement] {
        var out: [AppEntityUIElement] = []
        for request in requests {
            switch request {
            case .visible(let rect):
                for (annoRect, entity) in annotations() where annoRect.intersects(rect) {
                    out.append(makeUIElement(entity: entity, bounds: annoRect))
                }
            case .selected:
                continue
            @unknown default:
                continue
            }
        }
        return out
    }

    /// Existential-opening helper. `AppEntityUIElement.init<E: AppEntity>(_ entity:, bounds:)` is
    /// generic over a concrete entity type; each of the four concrete types we map to gets a
    /// dedicated branch so the compiler can specialize. The trailing fallback exists only to
    /// satisfy the type checker — the four cases above are exhaustive given `resolve`'s rules.
    /// If a fifth entity type is ever returned by `resolve` without updating this switch, the
    /// `assertionFailure` makes the regression loud in debug builds; release builds fall through
    /// to the placeholder so production keeps working.
    private func makeUIElement(entity: any AppEntity, bounds: CGRect) -> AppEntityUIElement {
        if let e = entity as? PageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? PostEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ImageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ElementEntity { return AppEntityUIElement(e, bounds: bounds) }
        assertionFailure("makeUIElement: unhandled entity type \(type(of: entity)) — extend the switch in PreviewAnnotationProvider")
        let placeholder = ElementEntity(
            id: "unknown", displayName: "unknown", siteID: siteID,
            selector: "{}", pagePath: "/"
        )
        return AppEntityUIElement(placeholder, bounds: bounds)
    }
}
#endif
#endif
```

- [ ] **Step 2: Update the macOS file's stale header comment**

In `Sources/AnglesiteIntents/PreviewAnnotationProviderUIElements.swift`, replace lines 1-4:

```swift
// AppKit-only half of `PreviewAnnotationProvider` (B.4 / #148): the
// `NSView.appEntityUIElementProvider` surface comes from the `_AppIntents_AppKit`
// cross-import overlay, so this file is macOS-only. The iOS thin client (#71) compiles the
// provider without it; a UIKit equivalent (`_AppIntents_UIKit`) is future work tracked on #71.
```

with:

```swift
// AppKit-only half of `PreviewAnnotationProvider` (B.4 / #148): the
// `NSView.appEntityUIElementProvider` surface comes from the `_AppIntents_AppKit`
// cross-import overlay, so this file is macOS-only. The iOS/UIKit equivalent (#1386) lives in
// `PreviewAnnotationProviderUIElementsIOS.swift`.
```

- [ ] **Step 3: Confirm the existing macOS unit tests still pass (they exercise this type's shared surface, unaffected by the new iOS extension)**

Run: `swift test --package-path . --filter PreviewAnnotationProviderTests`
Expected: all tests in `Tests/AnglesiteIntentsTests/PreviewAnnotationProviderTests.swift` PASS, unchanged.

- [ ] **Step 4: Verify the new iOS-gated code actually compiles for iOS**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`. If the `_AppIntents_UIKit` overlay doesn't provide `AppEntityUIElement`/`AppEntityUIElementsContext` the way the AppKit overlay does (an open risk — no direct prior art for this project's SDK to confirm the UIKit overlay's exact surface), this step fails with a "cannot find type" error; if so, stop and search the Xcode 27 iOS SDK's `_AppIntents_UIKit.swiftinterface` (via `xcrun --sdk iphoneos --show-sdk-path` → `System/Library/Frameworks/AppIntents.framework` or the toolchain's overlay module) for the actual type/initializer names before proceeding — do not guess further.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/PreviewAnnotationProviderUIElementsIOS.swift Sources/AnglesiteIntents/PreviewAnnotationProviderUIElements.swift
git commit -m "feat(#1386): UIKit AppEntityUIElement shaping for iOS"
```

---

### Task 3: `RemoteSessionModel` owns and registers a `PreviewAnnotationProvider`

**Files:**
- Modify: `Sources/AnglesiteMobile/RemoteSessionModel.swift`

**Interfaces:**
- Consumes: `PreviewAnnotationProvider.init(siteID: String, graph: SiteContentGraph)` (existing); `SiteContentGraph.init()` (existing, parameterless); `PreviewAnnotationProviderRegistry.shared.register(_:for:)` / `.unregister(siteID:)` (existing, both `@MainActor`).
- Produces: `RemoteSessionModel.annotationProvider: PreviewAnnotationProvider?` (new, `public private(set)`) — Task 4 reads this to wire the script handler and `appEntityUIElementProvider`.

- [ ] **Step 1: Add the import and property**

In `Sources/AnglesiteMobile/RemoteSessionModel.swift`, add to the imports at the top:

```swift
import AnglesiteIntents
```

Add a new stored property near `mcpClient` (after line 112):

```swift
    /// Per-session Siri onscreen-entity provider (#1386 — UIKit twin of the macOS
    /// `SiteWindowModel` wiring). `nil` before the first `start()` call. Recreated only when
    /// `siteID` actually changes, mirroring `SiteWindowModel.loadAndStart`'s guard — a `nil`
    /// check alone isn't enough because `start()` can be called again for the same site (Try
    /// Again after a failure).
    public private(set) var annotationProvider: PreviewAnnotationProvider?
```

- [ ] **Step 2: Create/register the provider in `start()`**

In `start()` (`Sources/AnglesiteMobile/RemoteSessionModel.swift:172-212`), after the `mcpClient = client` line and before constructing `runtime`, add:

```swift
        if annotationProvider?.siteID != siteID {
            if let old = annotationProvider {
                PreviewAnnotationProviderRegistry.shared.unregister(siteID: old.siteID)
            }
            let provider = PreviewAnnotationProvider(siteID: siteID, graph: SiteContentGraph())
            annotationProvider = provider
            PreviewAnnotationProviderRegistry.shared.register(provider, for: siteID)
        }
```

- [ ] **Step 3: Unregister in `stop()`**

In `stop()` (`Sources/AnglesiteMobile/RemoteSessionModel.swift:216-225`), after `guard let runtime else { return }` and before `self.runtime = nil`, add:

```swift
        if let provider = annotationProvider {
            PreviewAnnotationProviderRegistry.shared.unregister(siteID: provider.siteID)
        }
        annotationProvider = nil
```

- [ ] **Step 4: Verify the app target builds**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteMobile/RemoteSessionModel.swift
git commit -m "feat(#1386): RemoteSessionModel owns a PreviewAnnotationProvider"
```

---

### Task 4: Wire the provider into the preview `WKWebView`

**Files:**
- Modify: `Sources/AnglesiteMobile/RemoteSessionScreen.swift:85-109` (the `RemoteSandboxPreview` view)

**Interfaces:**
- Consumes: `RemoteSessionModel.annotationProvider` (Task 3); `PreviewAnnotationProvider.update(_:) async` (existing); `PreviewAnnotationProvider.uiElements(for:)` (Task 2, iOS-gated); `AnglesiteScriptHandler.init(router:onVisibleElements:...)` (existing, already platform-neutral); `RemotePreviewWebView.init(url:makeConfiguration:prepareBeforeLoad:configureWebView:)` (existing, `Sources/AnglesiteIOS/RemotePreviewWebView.swift:47-59`).
- Produces: nothing new consumed elsewhere — this is the leaf wiring.

- [ ] **Step 1: Add the import**

In `Sources/AnglesiteMobile/RemoteSessionScreen.swift`, add to the imports:

```swift
import AnglesiteIntents
```

- [ ] **Step 2: Pass `onVisibleElements` and set `appEntityUIElementProvider`**

Replace the body of `RemoteSandboxPreview` (`Sources/AnglesiteMobile/RemoteSessionScreen.swift:89-108`):

```swift
    var body: some View {
        let token = model.sessionToken
        let annotationProvider = model.annotationProvider
        let onVisibleElements: AnglesiteScriptHandler.VisibleElementsHandler? = annotationProvider.map { provider in
            { @Sendable elements in await provider.update(elements) }
        }
        let handler = AnglesiteScriptHandler(
            router: MCPApplyEditRouter(mcpClient: { [weak model] in await MainActor.run { model?.mcpClient } }),
            onVisibleElements: onVisibleElements
        )
        RemotePreviewWebView(
            url: url,
            makeConfiguration: {
                WebViewBridge.localDevConfiguration(handler: handler)
            },
            prepareBeforeLoad: { webView in
                guard let token, let host = url.host() else { return }
                await WebViewBridge.injectSessionToken(
                    into: webView.configuration.websiteDataStore.httpCookieStore,
                    token: token,
                    for: host
                )
            },
            configureWebView: { webView in
                guard let annotationProvider else { return }
                webView.appEntityUIElementProvider = { [weak annotationProvider] _, hitContext in
                    guard let annotationProvider else { return [] }
                    return annotationProvider.uiElements(for: hitContext)
                }
            }
        )
    }
```

This mirrors `PreviewView.swift:41-58` on macOS exactly: same closure-capture reasoning (the handler is owned by the `WKWebView`'s lifecycle; `annotationProvider` is owned by `RemoteSessionModel`, which outlives the web view), same `[weak annotationProvider]` capture in the `appEntityUIElementProvider` closure.

- [ ] **Step 3: Verify the app target builds**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteMobile/RemoteSessionScreen.swift
git commit -m "feat(#1386): wire Siri annotations into the iOS preview WKWebView"
```

---

### Task 5: Full verification pass + PR

**Files:** none (verification only)

**Interfaces:** none

- [ ] **Step 1: Run the full SwiftPM test suite (regression check — no SwiftPM source changed by Tasks 3-4, but Task 2 touched a shared target)**

Run: `swift test --package-path .`
Expected: all suites PASS (or the known pre-existing flakes/skips documented in `CLAUDE.md`, e.g. container tests opt-in, MCP e2e skip without the sidecar checkout — nothing new).

- [ ] **Step 2: Full iOS app build**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMobile -configuration Debug -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: `project.yml` ↔ `.xcodeproj` sync check (CI runs this; verify locally first)**

Run: `scripts/check-xcodeproj-sync.sh`
Expected: exits 0, no diff.

- [ ] **Step 4: Localization catalog check (Task 1 added no new strings, but this is cheap insurance)**

Run: `scripts/check-localization-catalog.sh`
Expected: exits 0.

- [ ] **Step 5: Open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan). Body must include `Closes #1386`. Note in the PR body, explicitly (not silently): the live Siri hand-off (spatial reference → entity → Shortcuts/Spotlight resolution) is **not** covered by automated tests — same caveat the macOS #148 implementation and this plan's own issue text carry — and that content-graph population on iOS (rules 1-3 of `PreviewAnnotationProvider`'s mapping) is still unbuilt, so every element currently falls through to the generic `ElementEntity` fallback until that lands separately.
