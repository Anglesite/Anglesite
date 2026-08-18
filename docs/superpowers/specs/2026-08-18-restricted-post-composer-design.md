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
`(_ title: String, _ visibility: MicropubPostVisibility, _ body: String) async -> ContentCreateResult`
(`body` empty/unused when `visibility == .public`). `SiteWindow.swift`'s call site branches on
`visibility`: `.public` calls the existing `SiteWindowModel.createPost(title:)` unchanged;
`.contacts` calls the new method below.

`SiteWindowModel` gains `createRestrictedPost(title:body:) async -> ContentCreateResult`:

1. Resolves a `MicropubClient` for the site (same factory pattern as §5.1's gating check —
   the gating check and this resolution should share one implementation rather than checking
   twice; the implementation plan decides whether that's a shared free function/type or
   duplicated per `TypedEntryEditorModel`'s existing precedent).
2. Builds the post via `MicropubPost.entry(title:content:status: .published, visibility: .contacts)` — a single "Create" action, immediately published, matching `NewPostSheet`'s existing
   single-action semantics (no separate draft/publish step on Mac today).
3. Calls `client.create(_:)`.
4. On success, returns the new `.createdRemote(url:)` result case (§5.4) — deliberately does
   **not** call `refreshAfterContentMutation()` or `registerContentUndo(...)`, both of which
   assume a `Source/`-relative file path that doesn't exist for this path.
5. On failure, maps `MicropubError` to `.failed(reason:)` the same way other call sites already
   describe Micropub errors (mirrors `TypedEntryEditorModel.saveViaMicropub`'s catch arms).

### 5.4 `ContentCreateResult`

`Sources/AnglesiteCore/ContentOperationsService.swift` gains a new case:

```swift
/// Created via Micropub directly into the site's D1 store — never written to Source/, so
/// there is no file path. Carries the post's canonical URL.
case createdRemote(url: URL)
```

`NewPostSheet`'s `onCreate` closure and `SiteWindow.swift`'s call site both need their `switch`
over `ContentCreateResult` extended for this case (dismiss on success, same as `.created`).

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
- `AnglesiteAppTests`: new tests for `SiteWindowModel.createRestrictedPost` against a faked
  `MicropubClient` transport (success → `.createdRemote`, 400/401/5xx → mapped `.failed`/error
  states) and the gating computation (provisioned+session vs. either missing).

## 8. Explicitly out of scope (deferred, not forgotten)

- Editing an existing restricted post on Mac — there is no file-backed editor surface for
  Micropub-only content today; a future issue if this becomes a real gap.
- Any UI affordance for connecting a site's Micropub session from within the New Post sheet
  itself — the owner uses the existing Connect Site flow.
- Everything already listed as out of scope in the epic decision record §4.
