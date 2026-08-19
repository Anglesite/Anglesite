# Restricted Post Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `public | contacts` visibility toggle to both the iOS and Mac post composers so a
restricted post publishes straight into the site's D1 store via Micropub, never touching `Source/`.

**Architecture:** A new `MicropubPostVisibility` wire-format enum (mirroring the existing
`MicropubPostStatus`) is stamped by both composers' Micropub property-building code. iOS's
`PostComposerModel` already publishes every post via Micropub, so it's an additive diff. Mac's
`NewPostSheet` currently only writes files (`NativeContentOperations.createPost`) — a new
`RestrictedPostPublisher` type gives it a second, Micropub-only creation path used exclusively
when `visibility == .contacts`.

**Tech Stack:** Swift 6.4 / SwiftUI, `@Observable` models, Swift Testing (`import Testing`,
`@Test`, `#expect`/`#require`) — no XCTest in any touched module.

## Global Constraints

- Every new/changed test uses Swift Testing, matching every existing test file in
  `AnglesiteCoreTests`/`AnglesiteIOSTests`/`AnglesiteAppTests` (no XCTest).
- Commit subjects ≤72 characters, conventional-commit format, referencing `#1566`.
- Design authority: `docs/superpowers/specs/2026-08-18-restricted-post-composer-design.md` —
  read it in full before starting; every task below implements a specific section of it.
- Do not touch `ContentCreateResult` (`Sources/AnglesiteCore/ContentOperationsService.swift`) —
  the design deliberately avoids it (design §5.4) to keep this change from forcing edits across
  ~15 unrelated call sites.
- `TypedEntryEditorModel.swift`'s session-resolution behavior (its `save()` CMS-mode branch and
  every existing test in `TypedEntryEditorModelCMSModeTests.swift`) must not change — Task 6's
  refactor of it is a pure internal delegation to the new shared `MicropubSessionResolver`, not a
  behavior change. If any existing test in that file needs an edit to keep passing, that's a
  signal the refactor changed behavior — stop and reconsider, don't adjust the test to match.
- The deployed `@dwk/micropub` Worker rejects `visibility: "contacts"` until
  [davidwkeith/workers#498](https://github.com/davidwkeith/workers/issues/498) ships — this is
  expected and out of scope to fix here; error paths already handle it as an ordinary
  `MicropubError.requestFailed`.

---

## Task 1: `MicropubPostVisibility` wire-format enum

**Files:**
- Modify: `Sources/AnglesiteCore/MicropubClient.swift`
- Test: `Tests/AnglesiteCoreTests/MicropubPostVisibilityTests.swift` (new)
- Test: `Tests/AnglesiteCoreTests/MicropubClientTests.swift` (extend)

**Interfaces:**
- Produces: `public enum MicropubPostVisibility: String, Sendable, Equatable, Hashable, CaseIterable { case `public`, contacts }`
- Produces: `MicropubPost.visibility: MicropubPostVisibility` (computed, defaults to `.public`)
- Produces: `MicropubPost.entry(title:content:status:slug:visibility:extraProperties:)` — same
  signature as today plus `visibility: MicropubPostVisibility = .public`, inserted before
  `extraProperties` in parameter order.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/MicropubPostVisibilityTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// `MicropubPostVisibility` (#1566): the `public | contacts` audience tier, mirroring
/// `MicropubPostStatus`'s absent-defaults-to-a-known-value shape.
struct MicropubPostVisibilityTests {
    @Test("visibility reads back as an enum, defaulting to public when absent")
    func visibilityDefaultsToPublic() {
        let post = MicropubPost(properties: ["content": [.string("hi")]])
        #expect(post.visibility == .public)
    }

    @Test("visibility reads a stamped contacts value")
    func visibilityReadsContacts() {
        let post = MicropubPost(properties: ["visibility": [.string("contacts")]])
        #expect(post.visibility == .contacts)
    }

    @Test("an unrecognized visibility value reads as public, mirroring status's tolerance")
    func visibilityUnrecognizedReadsPublic() {
        let post = MicropubPost(properties: ["visibility": [.string("unlisted")]])
        #expect(post.visibility == .public)
    }

    @Test("entry stamps visibility alongside post-status, defaulting to public")
    func entryStampsVisibilityDefault() {
        let post = MicropubPost.entry(title: "Hello", content: "Body", status: .published)
        #expect(post.properties["visibility"] == [.string("public")])
    }

    @Test("entry stamps an explicit contacts visibility")
    func entryStampsVisibilityContacts() {
        let post = MicropubPost.entry(content: "Body", visibility: .contacts)
        #expect(post.properties["visibility"] == [.string("contacts")])
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --package-path . --filter MicropubPostVisibilityTests`
Expected: FAIL to build — `MicropubPostVisibility` doesn't exist yet, `.entry` has no
`visibility` parameter.

- [ ] **Step 3: Add the enum, computed property, and `.entry` parameter**

In `Sources/AnglesiteCore/MicropubClient.swift`, immediately after the closing brace of
`MicropubPostStatus` (currently ending at line 18, before the `MicropubPost` struct doc comment):

```swift
/// The restricted-posting epic's audience tier (#963 §2.2, #1566): `public` is the default,
/// `contacts` restricts the post to the site's `ContactStore` allowlist (enforced by a later
/// slice — this client only stamps and reads the value). A string enum, not a boolean, so finer
/// tiers can layer on later without breaking already-stored posts.
public enum MicropubPostVisibility: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Visible to anyone — the default when the property is absent.
    case `public`
    /// Visible only to the site's known contacts, once a later slice enforces membership.
    case contacts
}
```

Inside `MicropubPost`, immediately after the `status` computed property (after its closing
brace, currently ending at line 60):

```swift
    /// The post's visibility, defaulting to ``MicropubPostVisibility/public`` when absent —
    /// same absent-defaults-to-known-value shape as ``status``. An unrecognized value also reads
    /// as public: the server validates the enum on write.
    public var visibility: MicropubPostVisibility {
        firstString("visibility").flatMap(MicropubPostVisibility.init(rawValue:)) ?? .public
    }
```

Change `MicropubPost.entry`'s signature and body (currently lines 80–102) to:

```swift
    public static func entry(
        title: String? = nil,
        content: String,
        status: MicropubPostStatus = .draft,
        slug: String? = nil,
        visibility: MicropubPostVisibility = .public,
        extraProperties: [String: [JSONValue]] = [:]
    ) -> MicropubPost {
        var properties: [String: [JSONValue]] = [
            "content": [.string(content)],
            "post-status": [.string(status.rawValue)],
            "visibility": [.string(visibility.rawValue)],
        ]
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanTitle, !cleanTitle.isEmpty {
            properties["name"] = [.string(cleanTitle)]
        }
        if let derived = MicropubClient.deriveSlug(title: title, explicitSlug: slug) {
            properties["mp-slug"] = [.string(derived)]
        }
        for (key, values) in extraProperties {
            properties[key] = values
        }
        return MicropubPost(properties: properties)
    }
```

Also update the doc comment above `entry` (currently lines 62–79) to add a `visibility` bullet
to its `- Parameters:` list, right after `status`:

```
///   - visibility: Stamped as `visibility`. Defaults to public.
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `swift test --package-path . --filter MicropubPostVisibilityTests`
Expected: PASS, all 5 tests.

- [ ] **Step 5: Extend `MicropubClientTests.swift`'s existing `.entry` tests**

In `Tests/AnglesiteCoreTests/MicropubClientTests.swift`, `entryBuildsProperties` currently reads:

```swift
    @Test("entry stamps content, name, post-status, and a derived mp-slug")
    func entryBuildsProperties() {
        let post = MicropubPost.entry(title: "Hello World", content: "Body text", status: .published)
        #expect(post.type == ["h-entry"])
        #expect(post.properties["content"] == [.string("Body text")])
        #expect(post.properties["name"] == [.string("Hello World")])
        #expect(post.properties["post-status"] == [.string("published")])
        #expect(post.properties["mp-slug"] == [.string("hello-world")])
    }
```

Add one line, right after the `mp-slug` assertion:

```swift
        #expect(post.properties["visibility"] == [.string("public")])
```

- [ ] **Step 6: Run the full `AnglesiteCoreTests` Micropub suite**

Run: `swift test --package-path . --filter MicropubClientTests`
Expected: PASS, including the updated `entryBuildsProperties`.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/MicropubClient.swift \
  Tests/AnglesiteCoreTests/MicropubPostVisibilityTests.swift \
  Tests/AnglesiteCoreTests/MicropubClientTests.swift
git commit -m "feat(#1566): add MicropubPostVisibility wire-format enum"
```

---

## Task 2: `MicropubComposerProjection` stamps visibility

**Files:**
- Modify: `Sources/AnglesiteCore/MicropubComposerProjection.swift`
- Test: `Tests/AnglesiteCoreTests/MicropubComposerProjectionTests.swift` (extend)

**Interfaces:**
- Consumes: `MicropubPostVisibility` (Task 1).
- Produces: `MicropubComposerProjection.properties(for:values:status:visibility:)` — same
  signature as today plus `visibility: MicropubPostVisibility = .public`.

- [ ] **Step 1: Write the failing test**

The file already declares a `Self.everyKind` descriptor and `Self.filledValues()` fixture (used
by `projectsEveryKind`, its first test). Add this test using the same fixtures, placed right
after `projectsEveryKind`:

```swift
    @Test("visibility is stamped alongside post-status, defaulting to public")
    func visibilityStampedWithDefault() {
        let defaulted = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .published)
        #expect(defaulted["visibility"] == [.string("public")])

        let restricted = MicropubComposerProjection.properties(
            for: Self.everyKind, values: Self.filledValues(), status: .published, visibility: .contacts)
        #expect(restricted["visibility"] == [.string("contacts")])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter MicropubComposerProjectionTests`
Expected: FAIL — `properties(for:values:status:)` has no `visibility` parameter.

- [ ] **Step 3: Add the parameter**

In `Sources/AnglesiteCore/MicropubComposerProjection.swift`, change `properties(for:values:status:)`
(currently lines 32–46) to:

```swift
    public static func properties(
        for descriptor: ContentTypeDescriptor,
        values: TypedContentEditor.Values,
        status: MicropubPostStatus,
        visibility: MicropubPostVisibility = .public
    ) -> [String: [JSONValue]] {
        var out: [String: [JSONValue]] = [
            "post-status": [.string(status.rawValue)],
            "visibility": [.string(visibility.rawValue)],
        ]
        for field in descriptor.fields where field.name != "draft" {
            guard let property = descriptor.projections.rawMf2Property(forField: field.name),
                  let value = values[field.name],
                  let encoded = mf2Values(for: value, kind: field.kind)
            else { continue }
            out[property] = encoded
        }
        return out
    }
```

Update the doc comment above it to add a `visibility` line to its `- Parameters:` list, after
`status`:

```
    ///   - visibility: Stamped as the `visibility` property. Defaults to public.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter MicropubComposerProjectionTests`
Expected: PASS, all tests in the file (the new one plus every pre-existing one — `visibility`'s
new unconditional stamp must not break assertions in tests that check the full output map for
equality; if any test asserts `properties == [...]` with an exact dictionary literal missing
`visibility`, update that literal to include `"visibility": [.string("public")]`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/MicropubComposerProjection.swift \
  Tests/AnglesiteCoreTests/MicropubComposerProjectionTests.swift
git commit -m "feat(#1566): stamp visibility in MicropubComposerProjection"
```

---

## Task 3: `ComposerDraft` persists a pending visibility selection

**Files:**
- Modify: `Sources/AnglesiteIOS/ComposerDraftStore.swift`
- Test: `Tests/AnglesiteIOSTests/PostComposerModelTests.swift` (extend — draft persistence is
  exercised through `PostComposerModel`, not `ComposerDraftStore` directly; there is no
  dedicated `ComposerDraftStoreTests.swift` in this repo today)

**Interfaces:**
- Produces: `ComposerDraft.visibility: String?` (raw value of `MicropubPostVisibility`, mirroring
  the existing `queuedStatus: String?`).

- [ ] **Step 1: Add the field**

In `Sources/AnglesiteIOS/ComposerDraftStore.swift`, in `ComposerDraft`'s stored-property list
(currently right after `public var queuedStatus: String?`, before `baselineJSON`), add:

```swift
    /// The visibility selection to restore alongside the queued send — `nil` for a not-yet-set
    /// composition (defaults to public when absent, matching `MicropubPostVisibility`'s own
    /// absent-defaults-to-public rule).
    public var visibility: String?
```

Add `visibility: String? = nil` as a new parameter to **both** of `ComposerDraft`'s
initializers — the memberwise one (currently `init(siteID:typeID:postURL:values:queuedStatus:baselineJSON:)`)
and the editor-values one (currently `init(siteID:typeID:postURL:editorValues:fieldNames:queuedStatus:baseline:)`)
— inserted right after `queuedStatus` in each parameter list, and assign `self.visibility = visibility`
in the memberwise initializer's body (the editor-values initializer already forwards to the
memberwise one via `self.init(...)`, so add `visibility: visibility` to that forwarding call too).

Since `ComposerDraft` is `Codable` via automatic synthesis (no custom `init(from:)`/`encode(to:)`
in the file — confirm this by reading the file before editing), adding an `Optional` stored
property is a backward-compatible decode: existing persisted drafts with no `visibility` key
decode with `visibility == nil`.

- [ ] **Step 2: Build to verify no call sites broke**

Run: `swift build --target AnglesiteIOS`
Expected: SUCCESS. (No existing call site needs updating since both new parameters default to
`nil` — but verify this by running the build rather than assuming it.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteIOS/ComposerDraftStore.swift
git commit -m "feat(#1566): persist pending visibility in ComposerDraft"
```

(This task's field is exercised by Task 4's tests, once `PostComposerModel` actually reads and
writes it — that's why there's no standalone test here.)

---

## Task 4: `PostComposerModel` gains a visibility property

**Files:**
- Modify: `Sources/AnglesiteIOS/PostComposerModel.swift`
- Test: `Tests/AnglesiteIOSTests/PostComposerModelTests.swift` (extend)

**Interfaces:**
- Consumes: `MicropubPostVisibility` (Task 1), `MicropubComposerProjection.properties(...:visibility:)`
  (Task 2), `ComposerDraft.visibility` (Task 3).
- Produces: `PostComposerModel.visibility: MicropubPostVisibility` (public var, default `.public`).

- [ ] **Step 1: Write the failing tests**

Read `Tests/AnglesiteIOSTests/PostComposerModelTests.swift` in full first (it's long — use the
`model(transport:store:siteID:)` helper and `TransportBox` already defined there, don't
reinvent them). Add these three tests, placed near the existing `saveDraftCreates` test:

```swift
    @Test("a restricted composition stamps visibility: contacts on create")
    func saveDraftStampsContactsVisibility() async throws {
        nonisolated(unsafe) var capturedProperties: [String: [Any]]?
        let box = TransportBox { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            capturedProperties = body?["properties"] as? [String: [Any]]
            return (Data(), Self.response(201, headers: ["Location": Self.postURL.absoluteString]))
        }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")
        model.visibility = .contacts

        await model.saveDraft()

        let properties = try #require(capturedProperties)
        #expect(properties["visibility"] as? [String] == ["contacts"])
    }

    @Test("opening an existing restricted post reads its visibility back")
    func openExistingReadsVisibility() async throws {
        let box = TransportBox { request in
            (Self.sourceJSON(properties: ["content": ["hi"], "visibility": ["contacts"]]), Self.response(200))
        }
        let model = try await PostComposerModel.openExisting(
            url: Self.postURL, descriptor: Self.noteDescriptor(), siteID: UUID(),
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: box.transport))
        #expect(model.visibility == .contacts)
    }

    @Test("a queued restricted composition's visibility survives a persisted draft restore")
    func draftRestoresVisibility() {
        let store = Self.scratchStore()
        let siteID = UUID()
        let model = Self.model(transport: { _ in fatalError("no network expected") }, store: store, siteID: siteID)
        model.values["body"] = .text("hi")
        model.visibility = .contacts
        model.persistDraft()

        let restoredDraft = store.loadNewDraft(forSite: siteID, typeID: Self.noteDescriptor().id)
        let restored = try! #require(restoredDraft)
        #expect(restored.visibility == "contacts")

        let restoredModel = PostComposerModel(
            descriptor: Self.noteDescriptor(), siteID: siteID,
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in fatalError("no network expected") }),
            draftStore: store, restoringDraft: restored)
        #expect(restoredModel.visibility == .contacts)
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --package-path . --filter PostComposerModelTests`
Expected: FAIL to build — `PostComposerModel` has no `visibility` property yet.

- [ ] **Step 3: Add the property and thread it through create/update/adopt/drafts**

In `Sources/AnglesiteIOS/PostComposerModel.swift`:

Add a new public stored property right after `public var values: TypedContentEditor.Values`
(currently line 53):

```swift
    /// The composition's audience tier (#1566) — `public` by default. Stamped into every
    /// create/update alongside `post-status`; read back from an opened post's stored properties.
    public var visibility: MicropubPostVisibility = .public
```

In `init(descriptor:siteID:client:draftStore:restoringDraft:)` (currently lines 79–112), restore
it from the draft. Add this alongside the existing `restoredStatus` local (right after the
`if let restoringDraft, restoringDraft.typeID == descriptor.id {` block's existing lines, inside
that same `if`):

```swift
        var restoredVisibility: MicropubPostVisibility?
```

and inside the `if let restoringDraft...` block body, alongside `restoredStatus = ...`:

```swift
            restoredVisibility = restoringDraft.visibility.flatMap(MicropubPostVisibility.init(rawValue:))
```

then after `self.queuedStatus = restoredStatus` (currently the line right before
`if restoredStatus != nil { ... }`), add:

```swift
        if let restoredVisibility { self.visibility = restoredVisibility }
```

In `private func adopt(post: MicropubPost, url: URL) -> Bool` (currently lines 150–169), after
`self.values = values` add:

```swift
        self.visibility = post.visibility
```

In `private func create(status: MicropubPostStatus) async throws -> URL` (currently lines
278–298), change the `MicropubComposerProjection.properties` call to pass `visibility`:

```swift
        var properties = MicropubComposerProjection.properties(
            for: descriptor, values: values, status: status, visibility: visibility)
```

In `private func update(url: URL, status: MicropubPostStatus) async throws` (currently lines
300–321), make the same change to its `MicropubComposerProjection.properties` call:

```swift
        let replace = MicropubComposerProjection.properties(
            for: descriptor, values: values, status: status, visibility: visibility)
```

In `private func persistQueuedDraft(status: MicropubPostStatus?)` (currently lines 362–371), add
`visibility: visibility.rawValue` to the `ComposerDraft(...)` construction, right after
`queuedStatus: status?.rawValue,`:

```swift
        let draft = ComposerDraft(
            siteID: siteID, typeID: descriptor.id, postURL: postURL,
            editorValues: values, fieldNames: descriptor.fields.map(\.name),
            queuedStatus: status?.rawValue,
            visibility: visibility.rawValue,
            baseline: postURL != nil ? baseline : nil)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter PostComposerModelTests`
Expected: PASS, all tests in the file (new and pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIOS/PostComposerModel.swift \
  Tests/AnglesiteIOSTests/PostComposerModelTests.swift
git commit -m "feat(#1566): thread visibility through PostComposerModel"
```

---

## Task 5: iOS composer UI — visibility picker

**Files:**
- Modify: `Sources/AnglesiteMobile/ComposeScreen.swift`

**Interfaces:**
- Consumes: `PostComposerModel.visibility` (Task 4), `MicropubPostVisibility` (Task 1).

No dedicated test — this is a SwiftUI view body change with no existing precedent for
view-body-level tests in this repo (`ComposeScreen`/`MicropubEntryForm` have no test file);
verified by build plus the manual smoke-test note in Task 5's Step 3.

- [ ] **Step 1: Add the picker to `MicropubEntryForm`**

In `Sources/AnglesiteMobile/ComposeScreen.swift`, inside `struct MicropubEntryForm`'s `body`
(currently lines 216–233), add a new `Section` before the existing `ForEach(scalarFields, ...)`
line:

```swift
    var body: some View {
        Form {
            Section {
                Picker("Visibility", selection: $model.visibility) {
                    Text("Public").tag(MicropubPostVisibility.public)
                    Text("Restricted to Contacts").tag(MicropubPostVisibility.contacts)
                }
            }
            ForEach(scalarFields, id: \.name) { field in
                control(for: field)
            }
            if let body = bodyField {
                Section("Body") {
                    MarkdownTextView(
                        text: model.textBinding(body.name),
                        documentId: model.postURL?.absoluteString ?? model.descriptor.id,
                        fitsContent: true
                    )
                    .id(model.postURL?.absoluteString ?? model.descriptor.id)
                    .frame(minHeight: 160)
                }
            }
        }
    }
```

`$model.visibility` works directly (no custom binding helper needed, unlike the `values`
dictionary's `textBinding`/`boolBinding`/etc.) because `@Bindable var model: PostComposerModel`
is already declared on `MicropubEntryForm`, and `visibility` is a plain `var` on the
`@Observable` `PostComposerModel` — SwiftUI's `@Bindable` projects a `Binding` for any such
property automatically.

- [ ] **Step 2: Build**

Run: `swift build --target AnglesiteMobile`
Expected: SUCCESS.

- [ ] **Step 3: Manual smoke test (documented, not automated)**

Per `docs/testing-macos-app.md`'s guidance for verifying UI changes: this is an iOS-only view
(`AnglesiteMobile` target), so it can't be smoke-tested via the Mac app build. Note in the PR
description that the visibility picker was verified by code review and the model-level tests in
Task 4, not a live device/simulator run — flag this explicitly rather than silently skipping it.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteMobile/ComposeScreen.swift
git commit -m "feat(#1566): add visibility picker to iOS composer"
```

---

## Task 6: `MicropubSessionResolver` (shared) + `RestrictedPostPublisher`

`TypedEntryEditorModel.swift` already has a small "resolve this site's Micropub client" factory
(its `MicropubClientFactory` typealias + `defaultMicropubClientFactory`). `RestrictedPostPublisher`
needs the exact same resolution. Rather than duplicating it, this task extracts it into a shared
`MicropubSessionResolver` enum that both consume — `TypedEntryEditorModel`'s own behavior does
not change, only its internal implementation delegates.

**Files:**
- Create: `Sources/AnglesiteApp/MicropubSessionResolver.swift`
- Modify: `Sources/AnglesiteApp/TypedEntryEditorModel.swift:16-33` (the `MicropubClientFactory`
  typealias and `defaultMicropubClientFactory` — internal delegation only, no signature or
  behavior change)
- Create: `Sources/AnglesiteApp/RestrictedPostPublisher.swift`
- Test: `Tests/AnglesiteAppTests/RestrictedPostPublisherTests.swift` (new)
- Test: `Tests/AnglesiteAppTests/TypedEntryEditorModelCMSModeTests.swift` (unchanged — run as a
  regression check, not edited)

**Interfaces:**
- Consumes: `MicropubClient`, `MicropubPost.entry(...)`, `MicropubError` (Task 1, `AnglesiteCore`);
  `StoredMicropubSessions` (`AnglesiteIOS`, already imported by `TypedEntryEditorModel.swift` —
  mirror that import).
- Produces:
  - `enum MicropubSessionResolver` with:
    - `typealias Factory = @Sendable (_ siteID: String, _ sourceDirectory: URL) async -> MicropubClient?`
    - `static func defaultFactory(sessions: StoredMicropubSessions = StoredMicropubSessions()) -> Factory`
  - `enum ComposerCreateOutcome { case success, siteNotFound, failed(reason: String) }`
  - `struct RestrictedPostPublisher` with:
    - `init(makeMicropubClient: @escaping MicropubSessionResolver.Factory = MicropubSessionResolver.defaultFactory())`
    - `func isAvailable(siteID: String, sourceDirectory: URL) async -> Bool`
    - `func createPost(title: String, body: String, siteID: String, sourceDirectory: URL) async -> ComposerCreateOutcome`

- [ ] **Step 1: Extract `MicropubSessionResolver`**

Create `Sources/AnglesiteApp/MicropubSessionResolver.swift`:

```swift
// Sources/AnglesiteApp/MicropubSessionResolver.swift
import Foundation
import AnglesiteCore
import AnglesiteIOS

/// Resolves a ready-to-use `MicropubClient` for a site, or `nil` when no CMS-mode session has
/// been onboarded yet (or the stored session was signed out). Shared by every Mac call site that
/// needs "does this site have a working Micropub session right now" — `TypedEntryEditorModel`'s
/// CMS-mode save branch (#800) and `RestrictedPostPublisher`'s restricted-post create path
/// (#1566) — so there is exactly one implementation of that resolution on the Mac side.
enum MicropubSessionResolver {
    typealias Factory = @Sendable (_ siteID: String, _ sourceDirectory: URL) async -> MicropubClient?

    /// Production factory: resolves the session via `StoredMicropubSessions` (Keychain read +
    /// endpoint re-discovery — discovery is never persisted) and builds a client from it.
    static func defaultFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> Factory {
        { siteID, sourceDirectory in
            await sessions.session(siteID: siteID, sourceDirectory: sourceDirectory)?.makeClient()
        }
    }
}
```

- [ ] **Step 2: Delegate `TypedEntryEditorModel` to the shared resolver**

In `Sources/AnglesiteApp/TypedEntryEditorModel.swift`, this is the current code (lines 16–33):

```swift
    typealias MicropubClientFactory = @Sendable (_ siteID: String, _ sourceDirectory: URL) async -> MicropubClient?

    /// Production factory: resolves the session via `StoredMicropubSessions` (Keychain read +
    /// endpoint re-discovery — discovery is never persisted, see its doc comment) and builds a
    /// client from it. `nonisolated` (rather than implicitly `@MainActor`, like every other
    /// member of this class) because `init`'s default-argument expressions run in a nonisolated
    /// context, not the initializer body's — this is what `init` calls to build its own default.
    private nonisolated static func defaultMicropubClientFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> MicropubClientFactory {
        { siteID, sourceDirectory in
            await sessions.session(siteID: siteID, sourceDirectory: sourceDirectory)?.makeClient()
        }
    }
```

Replace it with (same doc comment trimmed to reflect the delegation, same `typealias` name and
same `defaultMicropubClientFactory` name — every other line in the file that references either
name is untouched):

```swift
    typealias MicropubClientFactory = MicropubSessionResolver.Factory

    /// Delegates to ``MicropubSessionResolver/defaultFactory(sessions:)`` — the same resolution
    /// `RestrictedPostPublisher` (#1566) uses, kept in exactly one place. `nonisolated` (rather
    /// than implicitly `@MainActor`, like every other member of this class) because `init`'s
    /// default-argument expressions run in a nonisolated context, not the initializer body's —
    /// this is what `init` calls to build its own default.
    private nonisolated static func defaultMicropubClientFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> MicropubClientFactory {
        MicropubSessionResolver.defaultFactory(sessions: sessions)
    }
```

- [ ] **Step 3: Build and run the existing CMS-mode suite to confirm no behavior change**

Run: `swift build --target AnglesiteAppCore`
Expected: SUCCESS.

Run: `swift test --package-path . --filter TypedEntryEditorModelCMSModeTests`
Expected: PASS, every test unchanged — this refactor must not require editing this test file. If
any assertion in it needs to change to pass, stop: that means the delegation altered behavior,
not just its implementation, and this step must not proceed until the cause is found.

- [ ] **Step 4: Commit the extraction**

```bash
git add Sources/AnglesiteApp/MicropubSessionResolver.swift Sources/AnglesiteApp/TypedEntryEditorModel.swift
git commit -m "refactor(#1566): extract MicropubSessionResolver from TypedEntryEditorModel"
```

- [ ] **Step 5: Write the failing `RestrictedPostPublisher` tests**

Create `Tests/AnglesiteAppTests/RestrictedPostPublisherTests.swift`, mirroring
`Tests/AnglesiteAppTests/TypedEntryEditorModelCMSModeTests.swift`'s faked-transport style (read
that file first for the exact `HTTPURLResponse`-building helper pattern):

```swift
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteAppCore
import AnglesiteCore
import AnglesiteIOS

/// `RestrictedPostPublisher` (#1566): the Mac composer's only Micropub-write path — creates a
/// restricted post directly via `MicropubClient`, never touching `Source/` or git. Injectable
/// `makeMicropubClient`, same faked-seam style as `TypedEntryEditorModelCMSModeTests`.
@Suite(.serialized)
struct RestrictedPostPublisherTests {
    private nonisolated static let endpoint = URL(string: "https://owner.example/micropub")!

    private nonisolated static func response(_ code: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    @Test("isAvailable is true when the factory resolves a client")
    func isAvailableTrueWhenResolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(200)) })
        })
        let available = await publisher.isAvailable(siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(available)
    }

    @Test("isAvailable is false when the factory resolves no session")
    func isAvailableFalseWhenUnresolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in nil })
        let available = await publisher.isAvailable(siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(!available)
    }

    @Test("createPost sends a create with visibility: contacts and status: published")
    func createPostSendsContactsVisibility() async throws {
        nonisolated(unsafe) var capturedProperties: [String: [Any]]?
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { request in
                    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                    capturedProperties = body?["properties"] as? [String: [Any]]
                    return (Data(), Self.response(201, headers: ["Location": "https://owner.example/2026/my-post"]))
                })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body text", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        #expect(outcome == .success)
        let properties = try #require(capturedProperties)
        #expect(properties["visibility"] as? [String] == ["contacts"])
        #expect(properties["post-status"] as? [String] == ["published"])
        #expect(properties["content"] as? [String] == ["Body text"])
    }

    @Test("createPost reports failed when no session resolves")
    func createPostFailedWhenUnresolvable() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in nil })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test("createPost surfaces a distinct message on 401")
    func createPostReauthMessage() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(401)) })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("sign in"))
    }

    @Test("createPost surfaces the server's status on a plain request failure")
    func createPostRequestFailedMessage() async {
        let publisher = RestrictedPostPublisher(makeMicropubClient: { _, _ in
            MicropubClient(endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in (Data(), Self.response(400)) })
        })
        let outcome = await publisher.createPost(
            title: "Hello", body: "Body", siteID: "site-1", sourceDirectory: URL(filePath: "/tmp/site"))
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }
}
```

Add `Equatable` conformance requirements: for `#expect(outcome == .success)` to compile,
`ComposerCreateOutcome` must be `Equatable`. Include that in Step 7 below.

- [ ] **Step 6: Run the new tests to verify they fail**

Run: `swift test --package-path . --filter RestrictedPostPublisherTests`
Expected: FAIL to build — `RestrictedPostPublisher`/`ComposerCreateOutcome` don't exist yet.

- [ ] **Step 7: Create `RestrictedPostPublisher.swift`**

Create `Sources/AnglesiteApp/RestrictedPostPublisher.swift`:

```swift
// Sources/AnglesiteApp/RestrictedPostPublisher.swift
import Foundation
import AnglesiteCore
import AnglesiteIOS

/// The composer-facing outcome of a create attempt — deliberately smaller than
/// `ContentCreateResult`: the sheet only needs to know whether to dismiss or show an error,
/// never a created file's path/identifier (that bookkeeping is `SiteWindowModel`'s own concern,
/// already handled before this value is returned). See design doc §5.4 for why this isn't a new
/// `ContentCreateResult` case.
enum ComposerCreateOutcome: Equatable {
    case success
    case siteNotFound
    case failed(reason: String)
}

/// Publishes a new restricted (`visibility: contacts`) post straight to the site's Micropub
/// endpoint — the Mac composer's only Micropub-write path today (#1566); everything else on Mac
/// still writes through `NativeContentOperations`. Uses ``MicropubSessionResolver`` (the same
/// resolution `TypedEntryEditorModel`'s CMS-mode save path uses) so both stay unit-testable
/// without a real Keychain/network.
struct RestrictedPostPublisher {
    private let makeMicropubClient: MicropubSessionResolver.Factory

    init(makeMicropubClient: @escaping MicropubSessionResolver.Factory = MicropubSessionResolver.defaultFactory()) {
        self.makeMicropubClient = makeMicropubClient
    }

    /// Whether this site has a resolvable Micropub session right now — gates the composer's
    /// "Restricted" visibility option (design §5.1).
    func isAvailable(siteID: String, sourceDirectory: URL) async -> Bool {
        await makeMicropubClient(siteID, sourceDirectory) != nil
    }

    /// Creates a restricted post directly via Micropub — never touches `Source/` or git.
    func createPost(title: String, body: String, siteID: String, sourceDirectory: URL) async -> ComposerCreateOutcome {
        guard let client = await makeMicropubClient(siteID, sourceDirectory) else {
            return .failed(reason: "This site isn't connected for restricted posts. Connect it from Website ▸ Connect Site first.")
        }
        let post = MicropubPost.entry(title: title, content: body, status: .published, visibility: .contacts)
        do {
            _ = try await client.create(post)
            return .success
        } catch let error as MicropubError where error.requiresReauthorization {
            return .failed(reason: "Sign in again to publish restricted posts on this site.")
        } catch {
            return .failed(reason: "Publish failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path . --filter RestrictedPostPublisherTests`
Expected: PASS, all 6 tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/RestrictedPostPublisher.swift \
  Tests/AnglesiteAppTests/RestrictedPostPublisherTests.swift
git commit -m "feat(#1566): add RestrictedPostPublisher for Mac's restricted posts"
```

---

## Task 7: Wire the Mac composer end-to-end

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/NewContentSheets.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `RestrictedPostPublisher`, `ComposerCreateOutcome` (Task 6); `MicropubPostVisibility`
  (Task 1); `SiteStore.Site.id: String`, `SiteStore.Site.sourceDirectory: URL` (existing).
- Produces: `SiteWindowModel.canPublishRestrictedPosts() async -> Bool`,
  `SiteWindowModel.createRestrictedPost(title:body:) async -> ComposerCreateOutcome`.

No new dedicated tests for this task — `RestrictedPostPublisher` (Task 6) is the tested unit;
`SiteWindowModel`'s two new methods are thin pass-throughs, and `NewPostSheet`/`SiteWindow.swift`
are SwiftUI view/wiring code with no existing test precedent in this repo (same reasoning as
Task 5). Verified by build + the manual smoke test in Step 4.

- [ ] **Step 1: Add `RestrictedPostPublisher` to `SiteWindowModel`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add a new stored property right after the
existing `private let integrationOps = IntegrationOperations.live()` line (around line 61):

```swift
    private let restrictedPostPublisher = RestrictedPostPublisher()
```

Add two new methods right after the existing `createPost(title:)` method (currently lines
1802–1812, ending right before the `createComponent` doc comment):

```swift
    /// Whether this site can publish restricted (`visibility: contacts`) posts right now — a
    /// resolvable Micropub session must exist (#1566 design §5.1). Gates the New Post sheet's
    /// visibility picker.
    func canPublishRestrictedPosts() async -> Bool {
        guard let site else { return false }
        return await restrictedPostPublisher.isAvailable(siteID: site.id, sourceDirectory: site.sourceDirectory)
    }

    /// Creates a restricted post directly via Micropub — never touches `Source/`, so unlike
    /// `createPost(title:)` this never calls `refreshAfterContentMutation()` or
    /// `registerContentUndo(...)`, both of which assume a `Source/`-relative file path.
    func createRestrictedPost(title: String, body: String) async -> ComposerCreateOutcome {
        guard let site else { return .siteNotFound }
        return await restrictedPostPublisher.createPost(
            title: title, body: body, siteID: site.id, sourceDirectory: site.sourceDirectory)
    }
```

- [ ] **Step 2: Update `NewPostSheet`**

In `Sources/AnglesiteApp/NewContentSheets.swift`, replace the entire `NewPostSheet` struct
(currently lines 331–388) with:

```swift
struct NewPostSheet: View {
    /// Whether this site can currently publish restricted posts (#1566) — checked once when the
    /// sheet appears; the visibility picker is hidden entirely when this resolves to `false`
    /// rather than shown-and-disabled (design §5.1).
    let checkRestrictedAvailability: () async -> Bool
    let onCreate: (_ title: String, _ visibility: MicropubPostVisibility, _ body: String) async -> ComposerCreateOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var visibility: MicropubPostVisibility = .public
    @State private var postBody = ""
    @State private var restrictedAvailable = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return false }
        if visibility == .contacts {
            return !postBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Post") {
                    TextField("Title", text: $title)
                    if restrictedAvailable {
                        Picker("Visibility", selection: $visibility) {
                            Text("Public").tag(MicropubPostVisibility.public)
                            Text("Restricted to Contacts").tag(MicropubPostVisibility.contacts)
                        }
                    }
                }
                if visibility == .contacts {
                    Section("Content") {
                        TextEditor(text: $postBody)
                            .frame(minHeight: 120)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, minHeight: visibility == .contacts ? 340 : 160)
            .navigationTitle("New Post")
            .task {
                restrictedAvailable = await checkRestrictedAvailability()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        create()
                    }
                    .disabled(isCreating || !canCreate)
                }
            }
        }
    }

    private func create() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(cleanTitle, visibility, postBody)
            await MainActor.run {
                isCreating = false
                switch result {
                case .success:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}
```

- [ ] **Step 3: Wire `SiteWindow.swift`'s call site**

In `Sources/AnglesiteApp/SiteWindow.swift`, replace the current `NewPostSheet` presentation
(currently lines 1033–1037):

```swift
        .sheet(isPresented: $bindableModel.newPostPresented) {
            NewPostSheet { title in
                await model.createPost(title: title)
            }
        }
```

with:

```swift
        .sheet(isPresented: $bindableModel.newPostPresented) {
            NewPostSheet(
                checkRestrictedAvailability: { await model.canPublishRestrictedPosts() }
            ) { title, visibility, body in
                switch visibility {
                case .public:
                    switch await model.createPost(title: title) {
                    case .created: return .success
                    case .siteNotFound: return .siteNotFound
                    case .failed(let reason): return .failed(reason: reason)
                    }
                case .contacts:
                    return await model.createRestrictedPost(title: title, body: body)
                }
            }
        }
```

- [ ] **Step 4: Build and manually smoke test**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: SUCCESS.

Per `docs/testing-macos-app.md`, launch the built app against a test site and verify:
1. Website ▸ New Post on a site with no Micropub session connected — the sheet shows only the
   title field, no visibility picker (matches today's behavior exactly).
2. Creating a public post still writes a file under `src/content/posts/` as before.
3. (If a CMS-mode-connected test site is available) the visibility picker appears; selecting
   "Restricted to Contacts" reveals the body field and requires non-empty body before "Create"
   enables; submitting attempts a Micropub create (expect it to surface an error today, since the
   deployed Worker rejects `visibility: "contacts"` until
   [workers#498](https://github.com/davidwkeith/workers/issues/498) ships — confirm the error
   surfaces cleanly in the sheet rather than crashing or hanging).

Note in the PR body which of these three were actually run, and which couldn't be (e.g. no
CMS-mode test site available) — per this repo's verification norms, report what you could and
couldn't check rather than asserting full manual coverage happened.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift \
  Sources/AnglesiteApp/NewContentSheets.swift \
  Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1566): wire restricted post creation into New Post sheet"
```

---

## Task 8: Full verification and PR

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift package test suite**

Run: `swift test --package-path .`
Expected: PASS. If `AnglesiteIntentsTests` fails to build only because it's excluded on this
toolchain (see CONTRIBUTING.md's Swift 6.4/Xcode 27 note), that's expected — everything else
must pass.

- [ ] **Step 2: Run the JS overlay checks (unaffected, but part of the standard gate)**

Run: `cd JS/edit-overlay && npm run lint && npm run typecheck && npm test`
Expected: PASS (no files in this plan touch `JS/edit-overlay/`, so this should be a no-op
confirmation, not a real risk — run it anyway per CONTRIBUTING.md's standard checklist).

- [ ] **Step 3: Full app build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: SUCCESS.

- [ ] **Step 4: Check the `.xcstrings` localization catalog**

The new UI strings ("Visibility", "Public", "Restricted to Contacts", "Content", the two error
messages) are extracted at build time but only merged into
`Sources/AnglesiteApp/Localizable.xcstrings` inside the Xcode IDE, not a CLI build. Follow
CONTRIBUTING.md's "Commit String Catalog updates" recipe (the `xcrun xcstringstool sync ...
--skip-marking-strings-stale` command, scoped to this worktree's own `BUILD_DIR`) and review the
resulting diff before committing — discard and rescope if it contains keys you didn't add.

- [ ] **Step 5: Open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan).
In **Paired PR check**, note the cross-repo dependency on
[davidwkeith/workers#498](https://github.com/davidwkeith/workers/issues/498) (visibility enum
extension) — this app PR is self-contained and merges independently, but restricted posts won't
actually succeed against a deployed site until that upstream change ships, per the
`@dwk/workers` catalog-coordination convention. Body must include `Closes #1566`.

```bash
gh pr create --repo Anglesite/Anglesite --title "feat(#1566): restricted post composer" --body "$(cat <<'EOF'
## Summary
- Add a `public | contacts` visibility toggle to both composers (iOS `PostComposerModel`/
  `ComposeScreen`, Mac `NewPostSheet`).
- A restricted post publishes straight to the site's D1 store via `MicropubClient` and never
  touches `Source/` — Mac's `RestrictedPostPublisher` is a new Micropub-only creation path used
  only when visibility is set to Restricted.

## Paired PR check
Depends on davidwkeith/workers#498 (extend `@dwk/micropub`'s `visibility` enum to accept
`"contacts"`) to actually succeed against a deployed site — the deployed Worker currently
rejects that value with a 400. This app PR ships independently; the dependency is documented,
not blocking, per the existing `@dwk/workers` catalog-coordination convention in
CONTRIBUTING.md.

## Test plan
- [x] `swift test --package-path .`
- [x] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
- [x] `cd JS/edit-overlay && npm run lint && npm run typecheck && npm test`
- [ ] Manual smoke test on a CMS-mode-connected site (see Task 7 Step 4 for exactly what was/wasn't run)

Closes #1566
EOF
)"
```
