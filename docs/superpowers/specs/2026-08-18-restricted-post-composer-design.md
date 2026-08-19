# Restricted post composer: visibility toggle + Micropub publish (#1566)

**Status:** approved design, 2026-08-18. Pre-implementation.
**Issue:** [#1566](https://github.com/Anglesite/Anglesite/issues/1566), epic [#963](https://github.com/Anglesite/Anglesite/issues/963).
Decision record: `docs/superpowers/specs/2026-08-18-audience-limited-posting-decisions.md` §2.1–2.2 (this
design operationalizes that record's work slice 2 only).

## 1. Scope

A post composer visibility toggle (`public | contacts`, single tier in v1) that, when set to
`contacts`, publishes straight to the site's D1 post store via the Micropub write path —
**never** written to `Source/`, never in git, never in the static build.

Out of scope (separate issues per the decision record's work-slice list):

- Allowlist push / membership enforcement (slice 3). `ContactStore.knownMeURLs()` is not called
  from anywhere added by this design — it stays the forward-looking hook it already is.
- The Worker's authenticated read gate (slice 4).
- The `PreDeployCheck` build-exclusion backstop (slice 5).
- `bto` federated delivery (slice 1, upstream).
- Editing an *existing* restricted post from the Mac app (no file exists to open — see §4).

## 2. Cross-repo dependency (blocking, not blocking this PR)

The deployed `@dwk/micropub` Worker (`davidwkeith/workers`, vendored as
`@dwk/micropub@1.0.0-beta.1`) validates `visibility` against
`VISIBILITY_VALUES = ["public", "unlisted", "private"]`. Sending `"contacts"` 400s
(`Mf2ParseError`) against every currently-deployed site until the enum is extended upstream.

Tracked as [davidwkeith/workers#498](https://github.com/davidwkeith/workers/issues/498). This
app-side PR ships regardless, following the same paired-repo convention CONTRIBUTING.md already
documents for the `@dwk/workers` catalog: the PR body notes the pending dependency, and a 400
from a stale Worker surfaces through the composers' existing `MicropubError.requestFailed`
handling — no special-casing required in this repo.

## 3. Wire format (`AnglesiteCore`)

All in `Sources/AnglesiteCore/MicropubClient.swift` unless noted.

- **`MicropubPostVisibility: String, Sendable, Equatable, CaseIterable`** — `public`, `contacts`.
  Mirrors `MicropubPostStatus`'s shape exactly (same file, same doc-comment conventions). A
  string enum, not a boolean, per the decision record's extensibility requirement (§2.2).
- **`MicropubPost.visibility`** — computed property, `firstString("visibility").flatMap(MicropubPostVisibility.init(rawValue:)) ?? .public`, mirroring `.status`'s absent-defaults-to-known-value pattern.
- **`MicropubPost.entry(title:content:status:slug:extraProperties:)`** gains a
  `visibility: MicropubPostVisibility = .public` parameter, unconditionally stamped into
  `properties["visibility"]` alongside the existing `post-status` stamp.
- **`MicropubComposerProjection.properties(for:values:status:)`** (`MicropubComposerProjection.swift`)
  gains a `visibility: MicropubPostVisibility = .public` parameter, stamped the same
  unconditional way as `post-status` — **not** routed through the per-field iteration loop.
  The decision record is explicit that `visibility` is a Micropub/D1 wire concern, not a
  `ContentTypeDescriptor` field or frontmatter, so it must never gain a registry field mapping.

Stamping `visibility: "public"` on every ordinary post (the new default) is a no-op against
today's deployed Worker — `"public"` is already a valid enum value — so no existing flow
regresses while workers#498 is pending.

## 4. iOS composer (`AnglesiteIOS`)

`PostComposerModel` already composes and publishes every post via `MicropubClient`; this is an
additive diff:

- New `public var visibility: MicropubPostVisibility = .public` property.
- `create()` and `update(url:status:)` pass `visibility` into their
  `MicropubComposerProjection.properties(...)` calls.
- `adopt(post:url:)` reads `post.visibility` back into `self.visibility` — editing an existing
  restricted post preserves its toggle state.
- `ComposerDraft` (`ComposerDraftStore.swift`) gains a `visibility: String?` field
  (raw value), persisted/restored the same way `queuedStatus` is, so an interrupted restricted
  composition doesn't silently revert to public on relaunch.
- UI: a visibility picker added to the composer screen, alongside the existing draft/publish
  controls.

## 5. Mac composer (`AnglesiteApp`)

Mac's `NewPostSheet` → `SiteWindowModel.createPost` → `NativeContentOperations.createPost` is
**pure file+git today — no Micropub branch exists** for creating new posts (`#800`'s CMS-mode
branch only covers *editing* an already-open typed entry, in `TypedEntryEditorModel.save()`).
Since a restricted post must never touch `Source/`, this path needs new plumbing rather than an
extension of the existing one.

### 5.1 Gating

The "Restricted" option only appears when the site has a resolvable Micropub session — the same
check `TypedEntryEditorModel.load()` already performs: `CMSModeStatus.isProvisioned(settings:)`
plus a session resolved via the same `StoredMicropubSessions`-backed factory pattern
`TypedEntryEditorModel.MicropubClientFactory` uses. `SiteWindowModel` precomputes this once
(mirroring `TypedEntryEditorModel.isCMSMode`) and passes it into `NewPostSheet`. When
unavailable, the picker is simply absent — no new onboarding UX is introduced by this issue; the
owner connects the site via the existing Connect Site flow (`MicropubSiteConnectSheet`)
separately, same as CMS mode already requires today.

### 5.2 Sheet UI

`NewPostSheet` gains:

- A `Picker`/segmented visibility control (Public / Restricted), shown only per §5.1.
- A markdown body `TextEditor`, shown **only** when Restricted is selected. Public posts keep
  today's title-only-then-scaffold-then-open-to-edit flow unchanged — a restricted post has no
  follow-up file to open, so its full content (title + body) must be composed in the sheet
  itself, matching how the iOS composer already works.

### 5.3 Create path

`NewPostSheet.onCreate` changes shape to
`(_ title: String, _ visibility: MicropubPostVisibility, _ body: String) async -> ComposerCreateOutcome`
(§5.4; `body` empty/unused when `visibility == .public`). `SiteWindow.swift`'s call site
branches on `visibility`: `.public` calls the existing `SiteWindowModel.createPost(title:)` and
maps its `ContentCreateResult` down to `ComposerCreateOutcome`; `.contacts` calls the new method
below, which already returns `ComposerCreateOutcome` directly.

`TypedEntryEditorModel` already has this exact resolution (its `MicropubClientFactory` typealias
+ `defaultMicropubClientFactory`) for its own CMS-mode save branch. Rather than duplicating it,
that logic is extracted into a shared `MicropubSessionResolver` enum
(`Sources/AnglesiteApp/MicropubSessionResolver.swift`) that both `TypedEntryEditorModel` and the
new `RestrictedPostPublisher` (`Sources/AnglesiteApp/RestrictedPostPublisher.swift`) consume —
`TypedEntryEditorModel`'s own behavior and tests are unchanged, only its internal implementation
delegates:

```swift
enum MicropubSessionResolver {
    typealias Factory = @Sendable (_ siteID: String, _ sourceDirectory: URL) async -> MicropubClient?

    static func defaultFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> Factory {
        { siteID, sourceDirectory in
            await sessions.session(siteID: siteID, sourceDirectory: sourceDirectory)?.makeClient()
        }
    }
}

struct RestrictedPostPublisher {
    private let makeMicropubClient: MicropubSessionResolver.Factory

    init(makeMicropubClient: @escaping MicropubSessionResolver.Factory = MicropubSessionResolver.defaultFactory()) {
        self.makeMicropubClient = makeMicropubClient
    }

    func isAvailable(siteID: String, sourceDirectory: URL) async -> Bool {
        await makeMicropubClient(siteID, sourceDirectory) != nil
    }

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

`status: .published` — a single "Create" action, immediately published, matching
`NewPostSheet`'s existing single-action semantics (no separate draft/publish step on Mac today).

`SiteWindowModel` gains a `private let restrictedPostPublisher = RestrictedPostPublisher()`
stored property (fixed default, mirroring the existing `private let integrationOps =
IntegrationOperations.live()` pattern — no init signature change needed) and two thin methods:

```swift
func canPublishRestrictedPosts() async -> Bool {
    guard let site else { return false }
    return await restrictedPostPublisher.isAvailable(siteID: site.id, sourceDirectory: site.sourceDirectory)
}

func createRestrictedPost(title: String, body: String) async -> ComposerCreateOutcome {
    guard let site else { return .siteNotFound }
    return await restrictedPostPublisher.createPost(
        title: title, body: body, siteID: site.id, sourceDirectory: site.sourceDirectory)
}
```

Deliberately never calls `refreshAfterContentMutation()` or `registerContentUndo(...)` — both
assume a `Source/`-relative file path that doesn't exist for this path. `RestrictedPostPublisher`
is the real unit under test (§7); these two methods are thin enough not to need their own
separate fakes-heavy coverage.

### 5.4 Result type: `ComposerCreateOutcome`, not `ContentCreateResult`

`ContentCreateResult` (`Sources/AnglesiteCore/ContentOperationsService.swift`) has ~15
call sites across `AnglesiteIntents`, `AnglesiteShareExtension`, `AnglesiteApp`, and
`AnglesiteCore` — most switch over it exhaustively for operations (pages, components, link
posts, AppleScript, Intents) that will never produce a restricted-post result. Adding a case to
that shared enum would force every one of those unrelated switches to grow a dead arm just to
keep compiling — exactly the drive-by-refactor blast radius CONTRIBUTING.md's PR guidance warns
against.

`NewPostSheet` doesn't actually need `ContentCreateResult`'s payload (`filePath`/`identifier`)
at all — today's `create()` handler already discards it, branching only on
success/site-not-found/failed. So instead: a small new type, scoped to the composer UI only,
in `NewContentSheets.swift` next to `NewPostSheet`:

```swift
/// The composer-facing outcome of a create attempt — deliberately smaller than
/// `ContentCreateResult`: the sheet only needs to know whether to dismiss or show an error,
/// never a created file's path/identifier (that bookkeeping is `SiteWindowModel`'s own
/// concern, already handled before this value is returned).
enum ComposerCreateOutcome {
    case success
    case siteNotFound
    case failed(reason: String)
}
```

`NewPostSheet.onCreate` returns `ComposerCreateOutcome` directly.
`SiteWindow.swift`'s public-visibility branch maps the existing
`SiteWindowModel.createPost(title:)`'s `ContentCreateResult` down to it inline (`.created` →
`.success`, `.siteNotFound` → `.siteNotFound`, `.failed(let r)` → `.failed(reason: r)`).
`SiteWindowModel.createRestrictedPost(title:body:)` (§5.3) returns `ComposerCreateOutcome`
directly — `ContentCreateResult` is never touched.

## 6. Error handling

- A 400 from a Worker that hasn't picked up workers#498 yet surfaces as
  `MicropubError.requestFailed(status: 400, ...)`, already routed to a plain error message by
  both composers' existing catch arms (`Self.describe(error)` on iOS, an inline `catch` on Mac
  mirroring `TypedEntryEditorModel.saveViaMicropub`). No new error type or special-casing.
- 401/403 → `authRequired`/re-auth phase, already handled by both composers' existing
  `requiresReauthorization` branch.
- No Micropub session resolvable at all (§5.1) → the Restricted option is absent, not a runtime
  error path.

## 7. Testing

All Swift Testing (`AnglesiteCoreTests`/`AnglesiteIOSTests`/`AnglesiteAppTests` convention).

- `AnglesiteCoreTests`: new `MicropubPostVisibilityTests` (rawValue round-trip, default-when-absent)
  and extended `MicropubComposerProjectionTests` (visibility stamped alongside post-status) and
  `MicropubClientTests`-adjacent coverage for `.entry(...)`'s new parameter.
- `AnglesiteIOSTests`: extend `PostComposerModelTests` — visibility set on create, read back on
  `openExisting`, restored from a persisted `ComposerDraft`.
- `AnglesiteAppTests`: new `RestrictedPostPublisherTests` — a fake `MicropubClientFactory`
  closure (mirroring how `TypedEntryEditorModelTests` fakes its own factory) covering
  `isAvailable` (session resolves vs. `nil`) and `createPost` (success → `.success`, a faked
  400/401/5xx `MicropubError` from the client → the matching `.failed(reason:)`/re-auth
  message). `SiteWindowModel.createRestrictedPost`/`canPublishRestrictedPosts` are thin
  pass-throughs (§5.3) and don't need separate coverage beyond a compile-time check that they
  wire `site.id`/`site.sourceDirectory` through correctly.

## 8. Explicitly out of scope (deferred, not forgotten)

- Editing an existing restricted post on Mac — there is no file-backed editor surface for
  Micropub-only content today; a future issue if this becomes a real gap.
- Any UI affordance for connecting a site's Micropub session from within the New Post sheet
  itself — the owner uses the existing Connect Site flow.
- Everything already listed as out of scope in the epic decision record §4.
