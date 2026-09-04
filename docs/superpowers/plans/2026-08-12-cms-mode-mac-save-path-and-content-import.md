# CMS mode: Mac save path + provisioning content import — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out the remaining app-side scope of issue #800 — the Mac's typed content editors
save through `MicropubClient` instead of file+git when a site is CMS-mode provisioned, existing
content gets a one-time lossless import into D1 once that mode turns on, and one opt-in live e2e
proves the whole loop end-to-end.

**Architecture:** Reuse, don't rebuild. `MicropubClient`, `MicropubComposerProjection`,
`MicropubContentSync`/`MicropubContentCommitter`, `MicropubOnboardingModel`, `MicropubSession`,
and `ComposerDraftStore` already exist and are platform-neutral (no `#if os(iOS)` guards) —
built for #867/#868/#869. This plan wires them into the Mac app rather than duplicating them:
a small macOS `SiteWebAuthenticating` conformer supplies the one missing platform adapter, the
Mac app depends on `AnglesiteIOS` to reuse `MicropubOnboardingModel` directly, and
`TypedEntryEditorModel`'s save path grows a CMS-mode branch that calls the same `MicropubClient`
the phone already uses.

**Tech Stack:** Swift 6.4, SwiftUI/AppKit, SwiftPM (Package.swift) + XcodeGen (project.yml),
Swift Testing (`@Test`/`@Suite`), `ASWebAuthenticationSession`, Cloudflare D1/Micropub over HTTPS.

## Global Constraints

- No new third-party dependencies — everything here is Apple frameworks + existing in-repo types.
- `TypedEntryEditorModel`'s file-based save path must stay byte-identical for un-provisioned
  sites — this plan only adds a *branch*, never changes default behavior.
- CMS mode only ever applies to **typed content editors** (post-family collections). Pages,
  components, and other file kinds (`FileEditorModel`, `PlistEditorModel`, `GenericPageInspectorModel`)
  stay file-based and git-committed unconditionally, per spec §C.6 ("Code/theme/pages stay
  file-based... exactly as today").
- One write path for Mac and phone: the Mac's CMS-mode save must call the *same*
  `MicropubClient` API the iOS composer calls — never a bespoke direct-D1 write for interactive
  saves (spec §C.6's explicit reason: "so Mac and phone edits can't diverge").
- Content import is the one exception that needs its own call: see Task B1's design-rationale
  note on why it also goes through `MicropubClient.create` rather than a raw D1 insert.
- Run `swift test --package-path .` and `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` before each commit that touches `Sources/AnglesiteApp/` or `Sources/AnglesiteCore/`, per `CONTRIBUTING.md` ▸ "Testing".
- Every public type/function added needs a doc comment per `docs/comment-style-guide.md` (CI fails on broken DocC links).
- Conventional commit subjects ≤72 chars, referencing `#800`.

---

## Context recap (do not re-derive — verified against the current worktree 2026-08-12)

| Fact | Where |
|---|---|
| `MicropubClient` (create/update/setStatus/delete/configuration/source/listPosts/uploadMedia) is complete and tested | `Sources/AnglesiteCore/MicropubClient.swift`, `Tests/AnglesiteCoreTests/MicropubClientTests.swift` |
| `MicropubComposerProjection.properties(for:values:status:)` already converts `TypedContentEditor.Values` → mf2 properties — the exact shape `MicropubClient.create`/`.update` need | `Sources/AnglesiteCore/MicropubComposerProjection.swift:32` |
| `MicropubContentSync.values(for:properties:updatedAt:slug:)` is the reverse mapping (mf2 → `Values`), used by the existing D1→git export sync | `Sources/AnglesiteCore/MicropubContentSync.swift:173` |
| `MicropubContentCommitter` persists a **post URL ↔ Source/-relative path** map at `Config/micropubSync.json` | `Sources/AnglesiteCore/MicropubContentCommitter.swift:12-19` |
| `MicropubOnboardingModel`, `MicropubSession`, `ComposerDraftStore`, `PostComposerModel`, `PostListModel` (all in `Sources/AnglesiteIOS/`) have **no** `#if os(iOS)` guards — plain Swift, buildable from any target that depends on `AnglesiteIOS` | verified directly, 2026-08-12 |
| `SiteWebAuthenticating` protocol (`func authenticate(authorizeURL:callbackScheme:) async throws -> URL`) has no macOS conformer today | `Sources/AnglesiteIOS/MicropubOnboardingModel.swift:15-19` |
| `MicropubOnboardingModel.configure(site: SitePickerModel.DiscoveredSite)` takes `DiscoveredSite{id: UUID, displayName: String, packageURL: URL}` — trivially constructible from a Mac `SiteStore.Site` | `Sources/AnglesiteIOS/SitePickerModel.swift:15-21` |
| `WorkerComposition.micropubWorkerID = "micropub"`; `hasMicropub = workers.contains(where: { $0.id == micropubWorkerID })` is the existing "is this site's Worker composed with Micropub" check | `Sources/AnglesiteCore/WorkerComposition.swift:44,244` |
| `TypedEntryEditorModel(file:descriptor:route:sourceDirectory:)` is constructed at one call site with no `configDirectory`; `PlistEditorModel` right next to it already receives `configDirectory: site?.configDirectory` — the pattern to mirror | `Sources/AnglesiteApp/SiteWindowModel.swift:~1355 (PlistEditorModel), ~1500 (TypedEntryEditorModel)` |
| `FileEditorModel.save()` / `TypedEntryEditorModel.save()` today always write via `TypedContentEditor.write` + `fileSession.save` + `gitCommit` | `Sources/AnglesiteApp/TypedEntryEditorModel.swift:88-117,257` |
| `conformance/status.json` in `davidwkeith/workers` currently reports `@dwk/micropub`/`@dwk/webmention`/`@dwk/websub` integration as `pending` — the V-3 gate is not green as of 2026-08-12, so this feature ships **inert** behind per-site discovery (see Milestone A note) until the site's own Worker actually answers Micropub/IndieAuth requests | live-checked 2026-08-12 |

**Important scoping note:** `WorkersConformanceStatus.gateStatus(for: .v3)` (the *package-level*
conformance-suite gate) is **not** what gates this feature. The iOS app already gates on
*per-site* endpoint discovery instead (`MicropubOnboardingModel.FailureReason.micropubNotSupported`/
`.indieAuthNotSupported`, surfaced in `Sources/AnglesiteMobile/SiteSignInScreen.swift:142-157`) —
if a specific site's deployed Worker doesn't answer Micropub/IndieAuth discovery, the UI says so
honestly, regardless of the global conformance-suite status. This plan's Mac-side onboarding
(Task A2) reuses that exact mechanism, so it inherits the same honest-labeling behavior for free
— no separate gating work is needed.

---

## Milestone A — Mac CMS-mode save path

Ships as one PR. Lets a Mac user connect a provisioned site's Micropub endpoint and have typed
content editors save through it instead of file+git.

### Task 1 (A1): macOS `SiteWebAuthenticating` conformer

**Files:**
- Create: `Sources/AnglesiteApp/SiteMicropubSignIn.swift`
- Test: `Tests/AnglesiteAppTests/SiteMicropubSignInTests.swift` (create dir if absent — confirm via `find Tests -maxdepth 1 -type d` first; if no `AnglesiteAppTests` target exists in `Package.swift`/`project.yml`, this type is instead verified only by the `xcodebuild` app build per the existing convention for `#if os(macOS)` AppKit-facing types — check `Package.swift` for an `AnglesiteAppTests` target before writing this file; if absent, skip the Testing-framework test and note verification is via app build + manual QA, matching how `CloudflareOAuthSignIn.swift`'s macOS half is verified today)

**Interfaces:**
- Consumes: `SiteWebAuthenticating` protocol (`Sources/AnglesiteIOS/MicropubOnboardingModel.swift:15-19`), `SiteWebAuthenticationCancelled` (`:24-26`)
- Produces: `struct SiteMicropubSignIn: SiteWebAuthenticating` — the value `MicropubOnboardingModel.init` receives as its authenticator on macOS.

- [ ] **Step 1: Confirm whether a Swift-Testing-capable test target already exists for `Sources/AnglesiteApp/`**

  Run: `grep -n "AnglesiteAppTests\|testTarget" Package.swift`
  If a test target depending on `AnglesiteApp` exists, use it for Step 2. If not (AppKit-only
  app-target code is typically verified only by `xcodebuild`, per `CloudflareOAuthSignIn.swift`'s
  precedent), skip Steps 2–4 and go straight to Step 5, noting the gap explicitly in the PR body's
  Test plan (never silently skipped, per this codebase's own convention against silent caps).

- [ ] **Step 2 (if a test target exists): Write the failing test**

  ```swift
  import Testing
  @testable import AnglesiteApp

  @Suite
  struct SiteMicropubSignInTests {
      @Test("wraps ASWebAuthenticationSession cancellation as SiteWebAuthenticationCancelled")
      func mapsCancellation() async {
          // ASWebAuthenticationSession can't be driven headlessly in a unit test; this test only
          // confirms the type exists and conforms to the protocol. Real behavior is exercised by
          // manual QA (documented in the PR).
          let signIn = SiteMicropubSignIn()
          #expect(signIn is any SiteWebAuthenticating)
      }
  }
  ```

- [ ] **Step 3 (if applicable): Run test to verify it fails**

  Run: `swift test --package-path . --filter SiteMicropubSignInTests`
  Expected: FAIL — `SiteMicropubSignIn` doesn't exist yet.

- [ ] **Step 4: Write `SiteMicropubSignIn`**

  ```swift
  // Sources/AnglesiteApp/SiteMicropubSignIn.swift
  import AppKit
  import AnglesiteIOS

  /// macOS conformer of `SiteWebAuthenticating` — the per-site IndieAuth sign-in adapter
  /// `MicropubOnboardingModel` needs, mirroring `CloudflareOAuthSignIn`'s AppKit
  /// `ASWebAuthenticationSession` wrapper but matching a custom-scheme callback (IndieAuth's
  /// redirect URI) rather than an Associated-Domains HTTPS callback.
  struct SiteMicropubSignIn: SiteWebAuthenticating {
      func authenticate(authorizeURL: URL, callbackScheme: String) async throws -> URL {
          try await withCheckedThrowingContinuation { continuation in
              let session = ASWebAuthenticationSession(
                  url: authorizeURL, callbackURLScheme: callbackScheme
              ) { callbackURL, error in
                  if let callbackURL {
                      continuation.resume(returning: callbackURL)
                  } else if let error = error as? ASWebAuthenticationSessionError,
                            error.code == .canceledLogin {
                      continuation.resume(throwing: SiteWebAuthenticationCancelled())
                  } else {
                      continuation.resume(throwing: error ?? SiteWebAuthenticationCancelled())
                  }
              }
              let context = SiteMicropubSignInPresentationContext()
              session.presentationContextProvider = context
              session.prefersEphemeralWebBrowserSession = false
              objc_setAssociatedObject(session, &presentationContextKey, context, .OBJC_ASSOCIATION_RETAIN)
              session.start()
          }
      }
  }

  private var presentationContextKey: UInt8 = 0

  private final class SiteMicropubSignInPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
      func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
          NSApp.keyWindow ?? NSWindow()
      }
  }
  ```

  Read `Sources/AnglesiteApp/CloudflareOAuthSignIn.swift:14-35` first and match its exact
  presentation-context idiom (retained-object lifetime pattern) rather than the sketch above if
  it differs — that file is the authoritative in-repo precedent for this exact problem
  (`ASWebAuthenticationSession` outliving the function that started it).

- [ ] **Step 5 (if applicable): Run test to verify it passes**

  Run: `swift test --package-path . --filter SiteMicropubSignInTests`
  Expected: PASS

- [ ] **Step 6: Build the app target to catch AppKit-only compile errors**

  Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
  Expected: builds clean.

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/AnglesiteApp/SiteMicropubSignIn.swift Tests/AnglesiteAppTests/SiteMicropubSignInTests.swift
  git commit -m "feat(#800): add macOS SiteWebAuthenticating conformer"
  ```

### Task 2 (A2): Wire `AnglesiteApp` → `AnglesiteIOS` dependency and add the Mac connect sheet

**Files:**
- Modify: `project.yml` (Anglesite target's `dependencies` list)
- Create: `Sources/AnglesiteApp/MicropubSiteConnectSheet.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (new command/menu entry to present the sheet — see Step 4)

**Interfaces:**
- Consumes: `MicropubOnboardingModel` (`Sources/AnglesiteIOS/MicropubOnboardingModel.swift:37-` — `init`, `configure(site:)`, `signIn()`, `state`, `micropubClient`), `SitePickerModel.DiscoveredSite` (`Sources/AnglesiteIOS/SitePickerModel.swift:15-21`), `SiteMicropubSignIn` (Task A1), `SiteStore.Site` (existing macOS type — has `.id`, `.name`, `.packageURL`; confirm exact property names with `grep -n "struct Site" -A 10 Sources/AnglesiteApp/SiteStore.swift` before writing Step 3).
- Produces: `MicropubSiteConnectSheet: View` — presented from a new "Connect for CMS Mode…" command; on success, a `MicropubSession` is now resolvable from Keychain for this site (existing `SecretStore.readMicropubAccessToken(siteID:)` etc.), which Task A3's CMS-mode detector reads.

- [ ] **Step 1: Add the dependency edge**

  Open `project.yml`, find the `Anglesite` target's `dependencies:` list (alongside existing
  entries like `AnglesiteCore`, `AnglesiteBridge`). Add:
  ```yaml
  - target: AnglesiteIOS
  ```
  matching whatever exact YAML shape the neighboring entries use (`target:` vs. a bare string —
  copy the existing style precisely).

- [ ] **Step 2: Regenerate the Xcode project and confirm it builds**

  Run: `xcodegen generate && scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
  Expected: builds clean — this proves `AnglesiteIOS`'s platform-neutral types (Context recap
  table) are actually reachable from `AnglesiteApp` now. If it fails because some *other* file in
  `AnglesiteIOS` unexpectedly needs UIKit, that file is missing an `#if os(iOS)` guard — fix the
  guard in `AnglesiteIOS` rather than working around it here (don't let a leaky module boundary
  become this feature's problem).

- [ ] **Step 3: Write `MicropubSiteConnectSheet`**

  ```swift
  // Sources/AnglesiteApp/MicropubSiteConnectSheet.swift
  import SwiftUI
  import AnglesiteIOS

  /// Mac-side entry point for the same IndieAuth onboarding flow the iOS app already ships
  /// (#868) — reused as-is via `MicropubOnboardingModel`, with `SiteMicropubSignIn` (Task A1)
  /// as the AppKit `ASWebAuthenticationSession` adapter in place of iOS's SwiftUI environment
  /// value. A successful sign-in leaves a `MicropubSession` resolvable from Keychain for this
  /// site — `TypedEntryEditorModel`'s save path (Task A5) checks for exactly that.
  struct MicropubSiteConnectSheet: View {
      @State private var model: MicropubOnboardingModel
      @Environment(\.dismiss) private var dismiss

      init(site: SiteStore.Site) {
          let discovered = SitePickerModel.DiscoveredSite(
              id: site.id, displayName: site.name, packageURL: site.packageURL)
          _model = State(wrappedValue: MicropubOnboardingModel(webAuthenticator: SiteMicropubSignIn()))
          Task { @MainActor in await self.model.configure(site: discovered) }
      }

      var body: some View {
          VStack(spacing: 16) {
              switch model.state {
              case .idle, .discovering:
                  ProgressView("Looking for this site's Micropub endpoint…")
              case .readyToSignIn:
                  Button("Sign In") { Task { await model.signIn() } }
              case .signedIn:
                  Label("Connected", systemImage: "checkmark.seal.fill")
                  Button("Done") { dismiss() }
              case .failed(let reason):
                  Text(String(describing: reason)).foregroundStyle(.secondary)
                  Button("Try Again") { Task { await model.signIn() } }
              }
          }
          .padding()
          .frame(minWidth: 360, minHeight: 200)
      }
  }
  ```

  Read `MicropubOnboardingModel`'s actual `init` signature and `State` enum cases
  (`Sources/AnglesiteIOS/MicropubOnboardingModel.swift:53-90`) before finalizing this file — the
  sketch above is illustrative; match the real parameter names/case names exactly (the earlier
  research only confirmed the function/case *names*, not every associated value). Also check
  `Sources/AnglesiteMobile/SiteSignInScreen.swift` for the exact `State`/`FailureReason` switch
  shape already proven correct on iOS, and mirror it rather than re-deriving.

- [ ] **Step 4: Add a menu command to present the sheet**

  In `SiteWindowModel.swift`, add a `@Published`/`@State`-style `presentingMicropubConnect: Bool`
  flag and a method to set it, following the exact pattern `pendingWebsiteSettingsTab` already
  uses nearby (line ~1335) for presenting a similar site-scoped sheet. Wire a menu command in
  whichever file declares the Website/Site menu (search `grep -rn "CommandGroup" Sources/AnglesiteApp/ | grep -i site` to find it) titled "Connect for CMS Mode…", enabled only when
  `site?.name != nil` (mirrors existing site-scoped command guards).

- [ ] **Step 5: Manual QA**

  Build and run the app against a real provisioned site (or a stub Micropub server) and confirm
  the sheet discovers the endpoint, signs in, and reaches `.signedIn`. Record this in the PR body
  since `ASWebAuthenticationSession` can't be exercised by CI (same limitation `CloudflareOAuthSignIn`
  already carries).

- [ ] **Step 6: Commit**

  ```bash
  git add project.yml Sources/AnglesiteApp/MicropubSiteConnectSheet.swift Sources/AnglesiteApp/SiteWindowModel.swift Anglesite.xcodeproj
  git commit -m "feat(#800): Mac IndieAuth onboarding via reused MicropubOnboardingModel"
  ```

  (`Anglesite.xcodeproj` is gitignored per `CLAUDE.md` — omit it from `git add` if it doesn't
  show as trackable; confirm with `git status` first.)

### Task 3 (A3): CMS-mode detection helper

**Files:**
- Create: `Sources/AnglesiteCore/CMSModeStatus.swift`
- Test: `Tests/AnglesiteCoreTests/CMSModeStatusTests.swift`

**Interfaces:**
- Consumes: `SiteSettings.provisionedWorkerResources` (`Sources/AnglesiteCore/SiteConfigStore.swift`), `WorkerComposition.micropubWorkerID`/`activeWorkerIDs` (`Sources/AnglesiteCore/WorkerComposition.swift:44`)
- Produces: `CMSModeStatus.isProvisioned(settings: SiteSettings) -> Bool` — pure, no I/O. (Whether a *session* also exists, i.e. whether the save path can actually act on CMS mode right now, is Task A5's own Keychain check — kept separate so this type stays a pure, trivially-testable function per the file-structure guidance to split by responsibility.)

- [ ] **Step 1: Write the failing test**

  ```swift
  import Testing
  @testable import AnglesiteCore

  @Suite
  struct CMSModeStatusTests {
      @Test("provisioned when activeWorkerIDs includes micropub")
      func provisionedWithMicropub() {
          var settings = SiteSettings()
          settings.activeWorkerIDs = ["indieauth", "micropub", "webmention"]
          #expect(CMSModeStatus.isProvisioned(settings: settings) == true)
      }

      @Test("not provisioned when micropub isn't active")
      func notProvisionedWithoutMicropub() {
          var settings = SiteSettings()
          settings.activeWorkerIDs = ["webmention"]
          #expect(CMSModeStatus.isProvisioned(settings: settings) == false)
      }

      @Test("not provisioned with no active workers at all")
      func notProvisionedEmpty() {
          #expect(CMSModeStatus.isProvisioned(settings: SiteSettings()) == false)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  Run: `swift test --package-path . --filter CMSModeStatusTests`
  Expected: FAIL — `CMSModeStatus` doesn't exist.

- [ ] **Step 3: Write `CMSModeStatus`**

  ```swift
  // Sources/AnglesiteCore/CMSModeStatus.swift

  /// Whether a site's typed content editors should save through `MicropubClient` (CMS mode)
  /// instead of file+git — true once the site's composed Worker includes `@dwk/micropub`
  /// (spec §C.6). Pure and I/O-free by design: callers that also need to know whether a usable
  /// session exists right now (Keychain-backed) check that separately, so this type stays a
  /// trivial fact about the site's *provisioning* state, not its *auth* state.
  public enum CMSModeStatus {
      public static func isProvisioned(settings: SiteSettings) -> Bool {
          (settings.activeWorkerIDs ?? []).contains(WorkerComposition.micropubWorkerID)
      }
  }
  ```

  Confirm `SiteSettings.activeWorkerIDs` really is the field that reflects the *composed* set
  (not just *ever provisioned*) — re-read `Sources/AnglesiteCore/SiteConfigStore.swift:44-52`'s
  doc comment before finalizing; if `activeWorkerIDs` turns out to mean something subtly
  different (e.g. "was active as of last deploy" vs. "is active now"), use whichever field the
  comment says is authoritative for "is this Worker live right now" — adjust the implementation
  and this task's tests to match, not the other way around.

- [ ] **Step 4: Run test to verify it passes**

  Run: `swift test --package-path . --filter CMSModeStatusTests`
  Expected: PASS

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/AnglesiteCore/CMSModeStatus.swift Tests/AnglesiteCoreTests/CMSModeStatusTests.swift
  git commit -m "feat(#800): add CMSModeStatus.isProvisioned"
  ```

### Task 4 (A4): Expose `MicropubContentCommitter`'s sync-state read/write

**Files:**
- Modify: `Sources/AnglesiteCore/MicropubContentCommitter.swift:19,23-31`
- Test: `Tests/AnglesiteCoreTests/MicropubContentCommitterTests.swift` (extend existing file — read it first to match its fixture style)

**Interfaces:**
- Consumes: nothing new
- Produces: `public typealias SyncState = [String: String]` (widen access from `internal`), `public static func readSyncState(from configDirectory: URL) -> SyncState`, `public static func writeSyncState(_ state: SyncState, to configDirectory: URL, fileManager: FileManager = .default) throws` — the exact map (`Config/micropubSync.json`, post URL → `Source/`-relative path) both Task A5 (save path) and Task B1 (content import) read and append to, so there is exactly one persisted mapping, never two.

- [ ] **Step 1: Read the existing file in full**

  `Sources/AnglesiteCore/MicropubContentCommitter.swift` — confirm the exact current signatures
  of `loadState(from:)` (line 23) and `saveState(_:to:fileManager:)` (line 31) before renaming
  anything, since other call sites inside the same file (`commit`, line 83) already use them and
  must keep working unchanged.

- [ ] **Step 2: Write the failing test**

  ```swift
  @Test("readSyncState/writeSyncState round-trip through Config/micropubSync.json")
  func syncStateRoundTrips() throws {
      let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: configDir) }

      #expect(MicropubContentCommitter.readSyncState(from: configDir) == [:])

      let state: MicropubContentCommitter.SyncState = ["https://owner.example/blog/hello": "src/content/blog/hello.md"]
      try MicropubContentCommitter.writeSyncState(state, to: configDir)
      #expect(MicropubContentCommitter.readSyncState(from: configDir) == state)
  }
  ```

- [ ] **Step 3: Run test to verify it fails**

  Run: `swift test --package-path . --filter MicropubContentCommitterTests/syncStateRoundTrips`
  Expected: FAIL — compile error, `readSyncState`/`writeSyncState` don't exist yet.

- [ ] **Step 4: Rename and widen access**

  In `MicropubContentCommitter.swift`:
  - `typealias SyncState = [String: String]` → `public typealias SyncState = [String: String]`
  - `private static func loadState(from configDirectory: URL) -> SyncState` → `public static func readSyncState(from configDirectory: URL) -> SyncState` (keep the body identical)
  - `private static func saveState(_ state: SyncState, to configDirectory: URL, fileManager: FileManager) -> Void` → `public static func writeSyncState(_ state: SyncState, to configDirectory: URL, fileManager: FileManager = .default) throws` — if the existing body silently swallows write errors (check), change it to `throw` instead, since Task A5's save path must surface a failed sync-state write rather than losing the URL↔path mapping silently. Update its two internal call sites (in `resolvePath`/`commit`) to `try`/`try?` appropriately — keep their existing error-handling posture (the design doc's "never silently held" principle only requires *this new public entry point* to be honest; the internal export-sync caller can keep its current best-effort posture if that's what it has today).
  - Update the two existing internal call sites in the same file to the new names.

- [ ] **Step 5: Run test to verify it passes**

  Run: `swift test --package-path . --filter MicropubContentCommitterTests`
  Expected: PASS (including all pre-existing tests in the file — this step's rename must not
  break `commit`'s existing behavior).

- [ ] **Step 6: Run the full AnglesiteCore suite**

  Run: `swift test --package-path . --filter AnglesiteCoreTests`
  Expected: PASS — confirms nothing else in the module referenced the old private names.

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/AnglesiteCore/MicropubContentCommitter.swift Tests/AnglesiteCoreTests/MicropubContentCommitterTests.swift
  git commit -m "refactor(#800): expose MicropubContentCommitter's sync-state as public API"
  ```

### Task 5 (A5): Save-path branch — `TypedEntryEditorModel` writes through `MicropubClient` in CMS mode

**Files:**
- Modify: `Sources/AnglesiteApp/TypedEntryEditorModel.swift:88-117` (`save()`), its `init`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:~1500` (thread `configDirectory` into the constructor call)
- Test: `Tests/AnglesiteAppTests/TypedEntryEditorModelCMSModeTests.swift` (or extend the existing `TypedEntryEditorModel` test file if one exists — `find Tests -iname "*TypedEntryEditorModel*"` first)

**Interfaces:**
- Consumes: `CMSModeStatus.isProvisioned(settings:)` (Task A3), `MicropubContentCommitter.readSyncState(from:)`/`writeSyncState(_:to:)` (Task A4), `MicropubComposerProjection.properties(for:values:status:)` (`Sources/AnglesiteCore/MicropubComposerProjection.swift:32`), `MicropubClient.create(_:)`/`.update(url:replace:add:delete:)` (`Sources/AnglesiteCore/MicropubClient.swift:260,284`), `SecretStore` Micropub accessors (`Sources/AnglesiteCore/Platform/SecretStore.swift:232-259`)
- Produces: `TypedEntryEditorModel.init(file:descriptor:route:sourceDirectory:configDirectory:)` (new `configDirectory: URL?` parameter, default `nil` so any other call site keeps compiling), unchanged public `save() async -> Bool` signature.

- [ ] **Step 1: Read the current `save()`/`init` in full**

  `Sources/AnglesiteApp/TypedEntryEditorModel.swift:1-120,257` — confirm exact property names
  (`descriptor`, `values`/`savedValues`, `sourceDirectory`, `file`) before writing the branch, and
  confirm whether `values`/`savedValues` are already typed as `TypedContentEditor.Values` (per
  earlier research) or need a small adapter.

- [ ] **Step 2: Write the failing test — CMS mode routes through MicropubClient.create for a new post**

  ```swift
  import Testing
  @testable import AnglesiteApp
  @testable import AnglesiteCore

  @Suite(.serialized)
  struct TypedEntryEditorModelCMSModeTests {
      @Test("save() creates via MicropubClient when the site is CMS-mode provisioned and no prior URL is synced")
      func savesViaMicropubCreate() async throws {
          let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          let sourceDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
          try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
          defer {
              try? FileManager.default.removeItem(at: configDir)
              try? FileManager.default.removeItem(at: sourceDir)
          }
          var settings = SiteSettings()
          settings.activeWorkerIDs = ["micropub"]
          try SiteConfigStore.write(settings, to: configDir)

          var capturedRequest: URLRequest?
          // Inject the fake MicropubClient transport + credentials via whatever seam Step 3's
          // implementation exposes (e.g. a `MicropubClientFactory` closure on the model, or a
          // test-only `init` overload) — the exact injection point depends on how Step 3 wires
          // credential resolution, since `SecretStore` reads are themselves I/O this test must
          // not perform for real. Prefer adding an injectable `makeMicropubClient: (URL) -> MicropubClient?`
          // closure to `TypedEntryEditorModel.init` (default resolves from Keychain in
          // production) over reaching into Keychain in this test.

          // ... construct model, call save(), assert capturedRequest's method/body reflects a
          // Micropub create, and assert Config/micropubSync.json now maps the returned URL to
          // this file's Source/-relative path (via MicropubContentCommitter.readSyncState).
      }

      @Test("save() falls back to file+git when the site is not CMS-mode provisioned")
      func savesViaFileWhenUnprovisioned() async throws {
          // No activeWorkerIDs set (or missing "micropub") — assert the file on disk changed and
          // no Micropub request was attempted (capturedRequest stays nil).
      }
  }
  ```

  Fill in the constructor/assertion details once Step 3 settles the exact injection seam — this
  is the one step in this plan where the test body depends on an implementation choice made in
  the same task, so write Step 3 first if it's easier to keep both consistent, then backfill this
  test.

- [ ] **Step 3: Add `configDirectory` and a `makeMicropubClient` seam to `TypedEntryEditorModel`**

  ```swift
  // Sources/AnglesiteApp/TypedEntryEditorModel.swift — additive changes only

  /// Resolves a ready-to-use `MicropubClient` for `siteID` from Keychain, or `nil` if no
  /// session has been onboarded yet (Task A2's connect sheet never ran, or was signed out).
  /// Injectable so tests never touch the real Keychain.
  typealias MicropubClientFactory = (_ siteID: UUID) -> MicropubClient?

  static func defaultMicropubClientFactory(secretStore: any SecretStore = KeychainStore()) -> MicropubClientFactory {
      { siteID in
          guard let session = try? MicropubSession.resolve(siteID: siteID, secretStore: secretStore) else { return nil }
          return session.makeClient()
      }
  }
  ```

  Check whether `MicropubSession` already has a `resolve(siteID:secretStore:)`-shaped static
  constructor reading the Keychain accessors from `SecretStore.swift:232-259` — if not, this task
  needs to add one to `MicropubSession` itself (in `Sources/AnglesiteIOS/MicropubSession.swift`,
  since that's where the type lives) rather than duplicating Keychain-reading logic in
  `AnglesiteApp`. Confirm with `grep -n "func resolve\|static func" Sources/AnglesiteIOS/MicropubSession.swift` before deciding which file this constructor belongs in.

  Add stored properties `configDirectory: URL?`, `siteID: UUID?`, `makeMicropubClient: MicropubClientFactory`
  to `TypedEntryEditorModel`, threaded through `init` with defaults (`nil`, `nil`,
  `Self.defaultMicropubClientFactory()`) so existing call sites without CMS-mode context keep
  compiling unchanged.

- [ ] **Step 4: Branch `save()`**

  ```swift
  @discardableResult
  func save() async -> Bool {
      guard isDirty, !isSaving else { return true }
      isSaving = true
      defer { isSaving = false }

      if let configDirectory, let siteID,
         let settings = try? SiteConfigStore.read(from: configDirectory),
         CMSModeStatus.isProvisioned(settings: settings),
         let client = makeMicropubClient(siteID) {
          return await saveViaMicropub(client: client, configDirectory: configDirectory)
      }
      return await saveViaFile() // existing body, renamed
  }

  private func saveViaMicropub(client: MicropubClient, configDirectory: URL) async -> Bool {
      let relPath = /* existing relative-path computation, reused from saveViaFile */
      var syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
      let properties = MicropubComposerProjection.properties(
          for: descriptor, values: values,
          status: values["draft"] == .flag(true) ? .draft : .published)
      do {
          if let existingURLString = syncState.first(where: { $0.value == relPath })?.key,
             let existingURL = URL(string: existingURLString) {
              _ = try await client.update(url: existingURL, replace: properties)
          } else {
              let post = MicropubPost(properties: properties)
              let newURL = try await client.create(post)
              syncState[newURL.absoluteString] = relPath
              try MicropubContentCommitter.writeSyncState(syncState, to: configDirectory)
          }
          savedValues = values
          return true
      } catch {
          loadError = "CMS save failed: \(error.localizedDescription)"
          return false
      }
  }
  ```

  This is a sketch, not final code — re-derive `relPath` from whatever `saveViaFile` (the
  renamed existing body) already computes rather than recomputing it differently, and confirm
  `values["draft"]` really is how draft state is read on this model (cross-check against Part
  B's `draft` field handling elsewhere in the same file). Handle the 401 case per spec: catch
  `MicropubError.unauthorized` specifically and surface a distinct "sign in again" `loadError`
  rather than the generic message, since `MicropubError.requiresReauthorization` exists exactly
  for this branch.

- [ ] **Step 5: Thread `configDirectory`/`siteID` from the call site**

  At `Sources/AnglesiteApp/SiteWindowModel.swift:~1500`, change:
  ```swift
  return .typed(TypedEntryEditorModel(file: file, descriptor: descriptor, route: route, sourceDirectory: source))
  ```
  to:
  ```swift
  return .typed(TypedEntryEditorModel(
      file: file, descriptor: descriptor, route: route, sourceDirectory: source,
      configDirectory: site?.configDirectory, siteID: site?.id))
  ```
  matching `PlistEditorModel`'s existing `configDirectory: site?.configDirectory` argument right
  above it (line ~1355) exactly.

- [ ] **Step 6: Run the new tests, then the full suite**

  Run: `swift test --package-path . --filter TypedEntryEditorModelCMSModeTests`
  Expected: PASS
  Run: `swift test --package-path .`
  Expected: PASS (no regression in existing `TypedEntryEditorModel`/`SiteWindowModel` tests)

- [ ] **Step 7: Build the app**

  Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`

- [ ] **Step 8: Commit**

  ```bash
  git add Sources/AnglesiteApp/TypedEntryEditorModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/TypedEntryEditorModelCMSModeTests.swift
  git commit -m "feat(#800): route typed-entry saves through MicropubClient in CMS mode"
  ```

### Task 6 (A6): Export/read-side labeling in the editor UI

**Files:**
- Modify: `Sources/AnglesiteApp/TypedEntryEditorView.swift`

**Interfaces:**
- Consumes: `TypedEntryEditorModel`'s CMS-mode state (expose a small `var isCMSMode: Bool` computed from Task A5's branch condition, so the view doesn't reimplement the check)

- [ ] **Step 1: Add `isCMSMode` to `TypedEntryEditorModel`**

  ```swift
  var isCMSMode: Bool {
      guard let configDirectory, let settings = try? SiteConfigStore.read(from: configDirectory) else { return false }
      return CMSModeStatus.isProvisioned(settings: settings)
  }
  ```

- [ ] **Step 2: Add a banner in `TypedEntryEditorView`**

  Near the top of the form (find the existing `VStack`/`Form` root), add:
  ```swift
  if model.isCMSMode {
      Label("This post is stored in your site's CMS. The file on disk is a read-only export.", systemImage: "icloud.and.arrow.down")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.bottom, 4)
  }
  ```
  Match the file's existing spacing/padding conventions rather than the values above verbatim.

- [ ] **Step 3: Manual QA**

  Build and run; open a typed post on a CMS-mode-provisioned test site and confirm the banner
  appears; open one on an un-provisioned site and confirm it doesn't. Record in the PR body (no
  automated UI test exists for this view today, matching the rest of `TypedEntryEditorView`).

- [ ] **Step 4: Commit**

  ```bash
  git add Sources/AnglesiteApp/TypedEntryEditorModel.swift Sources/AnglesiteApp/TypedEntryEditorView.swift
  git commit -m "feat(#800): label CMS-mode posts as read-side exports in the editor"
  ```

**Milestone A PR:** title `feat(#800): Mac CMS-mode save path`. Body per `.github/PULL_REQUEST_TEMPLATE.md`'s
exact headings (Summary / Paired PR check / Test plan). Paired PR check: **no** — this is app-only,
no MCP message schema change. `Closes` line: do not close #800 yet (Milestone B/C remain) — reference
`Refs #800` instead, or use `Closes #800` only on the final Milestone C PR.

---

## Milestone B — Provisioning content import (§C.7)

Depends on Milestone A (reuses `MicropubComposerProjection`, `MicropubContentCommitter`'s public
sync-state API, and needs a resolvable `MicropubSession` — see design rationale below for why
this determines *when* import can run).

### Design rationale — why this isn't wired into `SocialWorkerProvisionCommand.provision()` directly

The spec (§C.7) describes content import as part of provisioning. But `SocialWorkerProvisionCommand.provision()`'s
natural completion point (`Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:571-572`, the
`.succeeded` branch) runs **before** any Mac-side IndieAuth onboarding exists for that site — the
Worker has just been deployed, but nobody has signed in to it yet (Milestone A's connect sheet is
a separate, later user action). Content import needs to call `MicropubClient.create` — the one
true write path (Global Constraints) — which needs a session that doesn't exist yet at that point.

Rather than inventing a second, bespoke direct-D1 write path just to dodge that ordering problem
(which would duplicate `@dwk/micropub`'s own Post-Type-Discovery/slug/validation logic
client-side and risk schema drift — a real, not hypothetical, risk given `MicropubPostD1Client`
already mirrors the Worker's `posts` table shape by hand), this plan triggers the one-time import
**lazily, the first time a CMS-mode session becomes available** for a provisioned site — i.e.,
right after Task A2's connect sheet reaches `.signedIn` for a site that has never completed
import. This keeps "one write path" intact and needs no new Worker-side capability.

If this sequencing doesn't match user expectations (e.g. import should happen automatically and
immediately at provision time even before anyone signs in), that's a product call worth raising
before merging Milestone B — flag it in the PR description rather than silently deciding it wasn't
worth mentioning.

### Task 7 (B1): `MicropubContentImport` orchestrator

**Files:**
- Create: `Sources/AnglesiteCore/MicropubContentImport.swift`
- Test: `Tests/AnglesiteCoreTests/MicropubContentImportTests.swift`

**Interfaces:**
- Consumes: `MicropubComposerProjection.properties(for:values:status:)`, `TypedContentEditor.read` (check its exact signature — `grep -n "static func read" Sources/AnglesiteCore/TypedContentEditor.swift`), `ContentTypeRegistry.default`/`.descriptor(forCollection:)` (`Sources/AnglesiteCore/ContentTypeRegistry.swift:259,264`), `MicropubClient.create(_:)`, `MicropubContentCommitter.readSyncState(from:)`/`writeSyncState(_:to:)` (Task A4), `MicropubClient.listPosts(limit:offset:)` (idempotency check)
- Produces: `public enum MicropubContentImport { public static func importIfNeeded(siteDirectory: URL, configDirectory: URL, client: MicropubClient, registry: ContentTypeRegistry = .default) async -> Int }` — returns the count of newly-imported posts (0 if nothing to do or already imported).

- [ ] **Step 1: Find how existing typed content files are enumerated today**

  Run: `grep -rn "func.*enumerat\|contentsOfDirectory" Sources/AnglesiteCore/NativeContentOperations.swift Sources/AnglesiteCore/ContentTypeRegistry.swift`
  There should be an existing directory-walk helper (used by e.g. the navigator or search) —
  reuse it rather than writing a new one. If genuinely nothing suitable exists, write a small
  private helper in this new file that walks `descriptor.storage`'s collection subdirectory for
  every `ContentTypeRegistry.default` descriptor with `.collection` storage, listing `.md`/`.mdx`
  files — mirror whatever glob pattern the Astro template's own `content.config.ts` uses (`.md`,
  `.mdx`) rather than inventing a different one.

- [ ] **Step 2: Write the failing test — imports an unsynced file, skips an already-synced one**

  ```swift
  import Testing
  import Foundation
  @testable import AnglesiteCore

  @Suite(.serialized)
  struct MicropubContentImportTests {
      @Test("imports a typed post file not yet in the sync map, and records its returned URL")
      func importsNewFile() async throws {
          let siteDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          let configDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          try FileManager.default.createDirectory(
              at: siteDir.appending(path: "src/content/blog"), withIntermediateDirectories: true)
          try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
          defer {
              try? FileManager.default.removeItem(at: siteDir)
              try? FileManager.default.removeItem(at: configDir)
          }
          let post = """
          ---
          title: Hello World
          pubDate: 2026-01-01
          draft: false
          ---
          Body text.
          """
          try post.write(
              to: siteDir.appending(path: "src/content/blog/hello-world.md"),
              atomically: true, encoding: .utf8)

          var createdCount = 0
          let client = MicropubClient(
              endpoint: URL(string: "https://owner.example/micropub")!,
              accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
              transport: { request in
                  createdCount += 1
                  let response = HTTPURLResponse(
                      url: request.url!, statusCode: 201, httpVersion: nil,
                      headerFields: ["Location": "https://owner.example/blog/hello-world"])!
                  return (Data(), response)
              })

          let imported = await MicropubContentImport.importIfNeeded(
              siteDirectory: siteDir, configDirectory: configDir, client: client)

          #expect(imported == 1)
          #expect(createdCount == 1)
          let state = MicropubContentCommitter.readSyncState(from: configDir)
          #expect(state["https://owner.example/blog/hello-world"] == "src/content/blog/hello-world.md")
      }

      @Test("re-running is a no-op once every file is already in the sync map")
      func skipsAlreadyImported() async throws {
          // Same setup, but pre-seed Config/micropubSync.json with the file's path already
          // mapped to some URL via MicropubContentCommitter.writeSyncState before calling
          // importIfNeeded; assert createdCount stays 0 and imported == 0.
      }
  }
  ```

- [ ] **Step 3: Run tests to verify they fail**

  Run: `swift test --package-path . --filter MicropubContentImportTests`
  Expected: FAIL — type doesn't exist.

- [ ] **Step 4: Write `MicropubContentImport`**

  ```swift
  // Sources/AnglesiteCore/MicropubContentImport.swift
  import Foundation

  /// One-time, idempotent import of a site's existing file-based typed content into D1, run the
  /// first time a CMS-mode session becomes available for a provisioned site (spec §C.7). Uses
  /// the same `MicropubClient.create` write path interactive saves use — never a direct D1
  /// write — so imported posts are validated by `@dwk/micropub` exactly like any other create.
  /// See docs/superpowers/plans/2026-08-12-cms-mode-mac-save-path-and-content-import.md for why
  /// this doesn't run inside `SocialWorkerProvisionCommand.provision()` directly.
  public enum MicropubContentImport {
      /// Imports every typed content file under `siteDirectory` not already present in
      /// `Config/micropubSync.json`, via `client.create`. Returns the number of files imported
      /// (0 if none are pending). Never throws: a single file's create failure is logged to
      /// `LogCenter` and the import continues with the rest, so one bad file can't block an
      /// otherwise-successful one-time migration.
      public static func importIfNeeded(
          siteDirectory: URL, configDirectory: URL, client: MicropubClient,
          registry: ContentTypeRegistry = .default
      ) async -> Int {
          var syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
          let alreadySynced = Set(syncState.values)
          var importedCount = 0

          for descriptor in registry.collectionDescriptors { // confirm exact accessor name in Step 1
              guard let files = try? filesForImport(descriptor: descriptor, siteDirectory: siteDirectory) else { continue }
              for fileURL in files {
                  let relPath = fileURL.path.replacingOccurrences(of: siteDirectory.path + "/", with: "")
                  guard !alreadySynced.contains(relPath) else { continue }
                  guard let values = try? TypedContentEditor.read(from: fileURL, descriptor: descriptor) else { continue }
                  let status: MicropubPostStatus = (values["draft"] == .flag(true)) ? .draft : .published
                  let properties = MicropubComposerProjection.properties(for: descriptor, values: values, status: status)
                  do {
                      let url = try await client.create(MicropubPost(properties: properties))
                      syncState[url.absoluteString] = relPath
                      importedCount += 1
                  } catch {
                      await LogCenter.shared.append(
                          source: "MicropubContentImport", stream: .stderr,
                          text: "Skipping \(relPath): \(error.localizedDescription)")
                  }
              }
          }
          if importedCount > 0 {
              try? MicropubContentCommitter.writeSyncState(syncState, to: configDirectory)
          }
          return importedCount
      }

      private static func filesForImport(descriptor: ContentTypeDescriptor, siteDirectory: URL) throws -> [URL] {
          // Reuse whatever helper Step 1 found; placeholder shape only until that's confirmed.
          []
      }
  }
  ```

  `registry.collectionDescriptors` is illustrative — `ContentTypeRegistry` may expose collection
  descriptors under a different accessor name (`allDescriptors.filter { if case .collection = $0.storage { true } else { false } }`,
  or a dedicated property). Confirm with `grep -n "storage\|case .collection\|var all" Sources/AnglesiteCore/ContentTypeRegistry.swift`
  before finalizing.

- [ ] **Step 5: Run tests to verify they pass**

  Run: `swift test --package-path . --filter MicropubContentImportTests`
  Expected: PASS

- [ ] **Step 6: Run the full AnglesiteCore suite**

  Run: `swift test --package-path .`
  Expected: PASS

- [ ] **Step 7: Commit**

  ```bash
  git add Sources/AnglesiteCore/MicropubContentImport.swift Tests/AnglesiteCoreTests/MicropubContentImportTests.swift
  git commit -m "feat(#800): one-time content import into D1 via MicropubClient"
  ```

### Task 8 (B2): Trigger import after Mac sign-in, track completion

**Files:**
- Modify: `Sources/AnglesiteCore/SiteConfigStore.swift` (add `contentImportCompleted: Bool?` to `SiteSettings`)
- Modify: `Sources/AnglesiteApp/MicropubSiteConnectSheet.swift` (Task A2 — call import on `.signedIn`)
- Test: extend `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift` if one exists (`find Tests -iname "*SiteConfigStore*"`)

**Interfaces:**
- Consumes: `MicropubContentImport.importIfNeeded` (Task B1), `model.micropubClient` (`MicropubOnboardingModel.micropubClient`, `Sources/AnglesiteIOS/MicropubOnboardingModel.swift:81`)

- [ ] **Step 1: Add the flag**

  In `SiteConfigStore.swift`, add near the other optional `Bool?`/state fields:
  ```swift
  /// Set once `MicropubContentImport.importIfNeeded` has run at least once for this site,
  /// successfully or not — the one-time gate that stops a signed-out-then-signed-back-in Mac
  /// from re-attempting a full import every time (`importIfNeeded` is independently idempotent
  /// via the sync-state map, but this flag avoids re-scanning every file on every sign-in).
  public var contentImportCompleted: Bool?
  ```
  Add it to the memberwise `init` alongside the other optional fields, default `nil`.

- [ ] **Step 2: Write a test for the new field's round-trip**

  Follow whatever pattern the existing `SiteConfigStoreTests` file uses for its other optional
  fields (write settings with the field set, read back, compare) — copy that pattern exactly
  rather than inventing a new one.

- [ ] **Step 3: Wire the trigger into `MicropubSiteConnectSheet`**

  In the `.signedIn` case's handling (Task A2, Step 3), after reaching `.signedIn`:
  ```swift
  case .signedIn:
      Label("Connected", systemImage: "checkmark.seal.fill")
          .task {
              guard let client = model.micropubClient else { return }
              var settings = (try? SiteConfigStore.read(from: configDirectory)) ?? SiteSettings()
              guard settings.contentImportCompleted != true else { return }
              _ = await MicropubContentImport.importIfNeeded(
                  siteDirectory: sourceDirectory, configDirectory: configDirectory, client: client)
              settings.contentImportCompleted = true
              try? SiteConfigStore.write(settings, to: configDirectory)
          }
      Button("Done") { dismiss() }
  ```
  `configDirectory`/`sourceDirectory` need to be threaded into `MicropubSiteConnectSheet.init`
  alongside `site` (Task A2 already takes a `SiteStore.Site`, which has both as computed
  properties per `AnglesitePackage` — use `site.configDirectory`/`site.sourceDirectory` directly
  rather than adding new parameters).

- [ ] **Step 4: Run tests**

  Run: `swift test --package-path .`
  Expected: PASS

- [ ] **Step 5: Build the app and manually verify**

  Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
  Manually onboard a real (or stub) provisioned site with existing typed content and confirm the
  import runs once, and a second sign-out/sign-in doesn't re-run it. Record in the PR body.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/AnglesiteCore/SiteConfigStore.swift Sources/AnglesiteApp/MicropubSiteConnectSheet.swift Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift
  git commit -m "feat(#800): trigger one-time content import after Mac IndieAuth sign-in"
  ```

### Task 9 (B3): Lossless round-trip test

**Files:**
- Modify: `Tests/AnglesiteCoreTests/MicropubContentImportTests.swift`

**Interfaces:**
- Consumes: `MicropubContentSync.values(for:properties:updatedAt:slug:)` (`Sources/AnglesiteCore/MicropubContentSync.swift:173`) — the reverse mapping, to prove import → export round-trips.

- [ ] **Step 1: Write the failing test**

  ```swift
  @Test("import then export reconstructs equivalent field values (lossless round-trip)")
  func importExportRoundTrips() async throws {
      // Reuse importsNewFile()'s fixture. After importIfNeeded, capture the mf2 `properties`
      // the fake transport received (store it in a captured var, same pattern as Task A5's
      // capturedRequest). Then call MicropubContentSync.values(for: descriptor, properties:
      // capturedProperties, updatedAt: ..., slug: "hello-world") and assert the result equals
      // the original file's TypedContentEditor.read(...) values for every field except any the
      // spec already documents as lossy by design (there should be none for the built-in
      // `blog`/post-family descriptors — if this test finds one, that's a real bug, not a test
      // to loosen).
  }
  ```

- [ ] **Step 2: Run, verify fail, implement any gap found, verify pass**

  This test may pass immediately if Task B1's `properties(for:...)` and the existing
  `MicropubContentSync.values(for:...)` are already exact inverses (they're designed to be, per
  both files' doc comments) — if so, this step is pure verification, not new production code.
  If it fails, the bug is in whichever direction doesn't match the other; fix the mapping, not
  the test's expectations.

- [ ] **Step 3: Commit**

  ```bash
  git add Tests/AnglesiteCoreTests/MicropubContentImportTests.swift
  git commit -m "test(#800): prove content import/export round-trip is lossless"
  ```

**Milestone B PR:** title `feat(#800): one-time content import into CMS mode (§C.7)`. `Refs #800`.

---

## Milestone C — Opt-in live e2e

Depends on Milestones A and B. One test, gated like the existing container/e2e suites (real
Cloudflare account required, skips cleanly otherwise).

### Task 10 (C1): Gated live e2e test

**Files:**
- Create: `Tests/AnglesiteCoreTests/CMSModeLiveE2ETests.swift`

**Interfaces:**
- Consumes: `MicropubClient` (real `defaultTransport`, not faked), `MicropubContentImport.importIfNeeded`, `CMSModeStatus.isProvisioned`, whatever the existing container/e2e suites use for their `.enabled(if:)` gate (`grep -n "enabled(if:" Tests/AnglesiteContainerLocalTests/*.swift` or `Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift` for the exact trait syntax and env-var convention already established).

- [ ] **Step 1: Find the existing opt-in e2e gating convention**

  Run: `grep -n "enabled(if:\|ProcessInfo.processInfo.environment" Tests/AnglesiteCoreTests/AppliesEditEndToEndTests.swift Tests/AnglesiteCoreTests/MCPClientHTTPEndToEndTests.swift`
  Confirm the exact env-var name pattern (e.g. `ANGLESITE_PLUGIN_PATH`, `ANGLESITE_CONTAINER_E2E`)
  this codebase already uses for "skip cleanly unless a real external dependency is present," and
  pick a new, consistently-named var for this suite (e.g. `ANGLESITE_MICROPUB_E2E` +
  `ANGLESITE_MICROPUB_E2E_SITE_URL`/credentials) rather than inventing a different naming shape.

- [ ] **Step 2: Write the gated test**

  ```swift
  import Testing
  import Foundation
  @testable import AnglesiteCore

  @Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E"] == "1"))
  struct CMSModeLiveE2ETests {
      @Test("provisioned site: import existing content, create a new post, read it back, publish")
      func fullLoop() async throws {
          guard let siteURLString = ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E_SITE_URL"],
                let accessToken = ProcessInfo.processInfo.environment["ANGLESITE_MICROPUB_E2E_TOKEN"]
          else { Issue.record("missing ANGLESITE_MICROPUB_E2E_SITE_URL/TOKEN"); return }

          // 1. Discover the micropub/media endpoints from siteURLString's well-knowns (reuse
          //    whatever discovery function MicropubOnboardingModel itself calls, kept
          //    accessible for tests — check its `private`/`internal` access level first).
          // 2. Build a MicropubClient with a fresh DPoPKeyPair and the provided access token.
          // 3. Call MicropubContentImport.importIfNeeded against a fixture site directory with a
          //    few typed posts, assert imported > 0 the first run, 0 the second.
          // 4. client.create(...) a new draft post, assert the returned URL resolves via
          //    client.source(url:) with matching properties.
          // 5. client.setStatus(url:, .published), poll (bounded retries, not a busy loop) until
          //    the live URL 200s, per the spec's "published — site rebuilding" bake-lag handling.
      }
  }
  ```

  This is intentionally a skeleton — fill in real assertions once a real V-3-conformant test site
  is available to run this against (per the live-checked conformance gap noted in the Context
  recap table, that isn't true yet as of 2026-08-12). Land the gated skeleton now so CI never
  attempts it (the `.enabled(if:)` trait keeps it inert), and note in the PR body that this test
  is unexercised until a real site exists — flagged, not silently skipped, matching this
  codebase's existing convention for every other opt-in e2e suite.

- [ ] **Step 3: Confirm it's skipped in normal CI runs**

  Run: `swift test --package-path . --filter CMSModeLiveE2ETests`
  Expected: 0 tests run (skipped by the trait), not a failure.

- [ ] **Step 4: Commit**

  ```bash
  git add Tests/AnglesiteCoreTests/CMSModeLiveE2ETests.swift
  git commit -m "test(#800): add opt-in live e2e for CMS-mode import/create/publish"
  ```

**Milestone C PR:** title `test(#800): opt-in live e2e for CMS mode`. `Closes #800` (this is the
last remaining piece — Milestones A and B plus the already-shipped #867/#868/#869 complete the
issue's full scope).

---

## Self-review notes

- **Spec coverage:** all seven of #800's checklist items are covered — `MicropubClient`/IndieAuth/iOS
  compose UI already shipped (#867–869, verified against `git log`, not re-planned here);
  conformance gating is already satisfied on iOS via per-site discovery (Context recap); Milestone
  A covers "Mac CMS-mode save path"; Milestone B covers "provisioning... content import" (the
  deployed-source bundle half of that bullet already shipped per #799, verified directly against
  `DeployExecutor.swift`/`DeployCommand.swift`); Milestone C covers "opt-in live e2e."
- **Known gaps flagged, not hidden:** Task A1/A2/A6 rely on manual QA where `ASWebAuthenticationSession`/AppKit
  UI can't be driven by `swift test` — same limitation the existing macOS Cloudflare sign-in
  already carries, called out explicitly rather than silently claimed as tested. Task C1 ships
  inert until a real V-3-conformant site exists to run it against.
  Several steps (A3 Step 3, A5 Step 3, B1 Step 1/4) tell the implementer to re-confirm one exact
  field/accessor name against the live file before finalizing — these are the handful of spots
  where the research above was confident about a type's *existence* and *shape* but not
  byte-exact about every internal field name; each says exactly what to grep to resolve it, not
  "figure it out."
- **Sequencing decision surfaced, not buried:** Milestone B's design-rationale section explains
  and flags the choice to trigger import on first sign-in rather than at provision time — worth a
  quick nod from the issue owner before or during review, not a silent judgment call.
