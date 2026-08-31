# Design: Capability gating for Workers-only features (#1015)

**Date:** 2026-08-31
**Status:** Draft — pending owner review
**Issue:** [#1015 — Deploy-target seam + a second static host (GitHub Pages) beyond Cloudflare](https://github.com/Anglesite/Anglesite/issues/1015)

## Problem

Slices 1, 2a, and 2b landed the `DeployTarget` seam, GitHub Pages plumbing, and
`GitHubPagesDeployTarget` itself ([#1541](https://github.com/Anglesite/Anglesite/pull/1541),
[#1555](https://github.com/Anglesite/Anglesite/pull/1555),
[#1673](https://github.com/Anglesite/Anglesite/issues/1673)). Once a later slice reads
`DomainConfig.deployTarget` to actually select a conformer, a site can be configured to publish
through GitHub Pages instead of Cloudflare — but nothing in the app knows that some features have
no equivalent there.

The worker catalog, Inbox Capture, and (per #1015's own body) membership are Cloudflare Workers
concepts. `Sources/AnglesiteApp/DeployModel.swift:891-896` already documents the sharp edge: the
`SocialWorkerProvisionCommand` closures do `command.target as? CloudflareDeployTarget` and
silently return `nil`/`[]` when the cast fails. That's fine as a crash-avoidance fallback, but on
its own it means a GitHub Pages site's Inbox Capture toggle would flip on, report no error, and
publish nothing — a silent degradation, not a failure. That is exactly the anti-pattern the
codebase's established **BBEdit-style capability-gated-feature labeling policy** exists to
prevent (see `PlatformCapabilities.swift` and its LLM-tier precedent in
`docs/superpowers/specs/2026-07-08-cross-platform-swift-port-design.md` §5/§10): a feature that
isn't available in the current context is shown, visibly disabled, with an explanation — never
hidden, and never a silent no-op.

This document scopes that gating mechanism and its one concrete application today: the `.workers`
Site Settings tab (`Sources/AnglesiteApp/PlistEditorView.swift:960-1095` — worker catalog groups,
production logs/analytics links, and the Inbox Capture toggle).

## Scope

**In scope:** everything currently in `PlistEditorView.workersTab` — the manifest-driven worker
catalog groups, the ActivityPub handle section, the production logs/analytics buttons, and the
Inbox Capture toggle/status/error text.

**Membership:** #1015's body lists membership alongside inbox capture and the worker catalog as a
Workers-only feature, but a repo-wide search found no membership implementation in `Sources/` —
it doesn't exist yet. This design does not invent gating for code that isn't there. It defines a
mechanism (`DeployTargetCapabilities.supportsWorkers`) that any future Workers-only feature checks
the same way the worker catalog and Inbox Capture will; membership gets no special-casing when it
ships, it just calls the same check.

**Out of scope:**
- Reading `deployTarget` inside `DeployCommand`/`DeployModel` to actually select a
  `GitHubPagesDeployTarget` conformer — that's mechanical wiring against an already-built seam,
  not a design question, and this doc's UI-facing resolver (below) is intentionally independent of
  it so gating doesn't have to wait on it landing first.
- Fixing the `command.target as? CloudflareDeployTarget` cast at `DeployModel.swift:896` — see
  "Relationship to `SocialWorkerProvisionCommand`" below for why this design makes it safe to
  leave as-is.
- The Site Settings deploy-target picker UI itself.
- Slice 2c (GitHub token onboarding for the `Pages` PAT permission) — unrelated.

## Design

### `DeployTargetKind` (new: `Sources/AnglesiteCore/DeployTargetKind.swift`)

A small enum mirroring the two existing `DeployTarget.id` values
(`CloudflareDeployTarget.id == "cloudflare"`, `GitHubPagesDeployTarget.id == "githubPages"`), so
UI-layer code can know which target a site uses without constructing a `DeployTarget` conformer
(which needs a live credential source, executor, etc. — overkill for a display-only check):

```swift
/// Which `DeployTarget` a site is configured to publish through, resolved from
/// `DomainConfig.deployTarget` (#1015). Exists so callers that only need to know *which* target
/// a site uses — UI gating, chiefly — don't have to construct a full `DeployTarget` conformer
/// (credential source, executor, etc.) just to read a label.
public enum DeployTargetKind: Sendable, Equatable {
    case cloudflare
    case githubPages

    /// `nil` and any unrecognized string resolve to `.cloudflare`, matching
    /// `DomainConfig.deployTarget`'s own doc comment ("`nil` means cloudflare, the only target
    /// that exists today") and its forward-compatibility precedent — an unrecognized future
    /// value degrades to the safe default for a reader that predates it, rather than crashing or
    /// silently gating a target this code doesn't know about.
    public init(rawValue: String?) {
        self = rawValue == GitHubPagesDeployTarget.id ? .githubPages : .cloudflare
    }
}
```

### `DeployTargetCapabilities` (new: `Sources/AnglesiteCore/DeployTargetCapabilities.swift`)

One flag today, deliberately not a per-feature enum — the worker catalog, Inbox Capture, and
membership are all "requires Cloudflare Workers," not three independently-available things:

```swift
/// Capability flags derived from a site's `DeployTargetKind` (#1015). Mirrors
/// `PlatformCapabilities`'s shape (a namespace of derived flags, not a stored type) but is
/// per-site rather than per-build, so it takes the kind as a parameter instead of being a
/// static `let`.
public enum DeployTargetCapabilities {
    /// Whether Cloudflare Workers-backed features — the worker catalog, Inbox Capture, and any
    /// future Workers feature such as membership — are available for a site on this target.
    /// `false` for every target except `.cloudflare` by construction: a plain static host has no
    /// equivalent to Workers, this isn't a gap to close per-target later.
    public static func supportsWorkers(for kind: DeployTargetKind) -> Bool {
        kind == .cloudflare
    }
}
```

### Resolving the kind in `PlistEditorModel`

`PlistEditorModel` already has `sourceDirectory` and the app already has an established pattern
for a one-off synchronous `DomainConfig` read (`ExperimentStatsModel`, `ConnectDomainModel`,
`DomainConfigAuditModel` all do `try? DomainConfigStore(sourceDirectory:).load()`). Add a
computed property following the same pattern:

```swift
var deployTargetKind: DeployTargetKind {
    DeployTargetKind(rawValue: (try? DomainConfigStore(sourceDirectory: sourceDirectory).load())?.deployTarget)
}
```

Read once when `workersTab` appears (alongside the existing `.task { await model.loadWorkers() }`
at `PlistEditorView.swift:1015`), not cached — `anglesite.json` is git-tracked and can change
underneath an open settings window (e.g. a git pull), and this is a cheap local file read, not a
network call.

### UI treatment (`PlistEditorView.workersTab`)

The `.workers` tab stays in the tab list unconditionally — same icon, same label, never hidden,
per the BBEdit-style policy. When `!DeployTargetCapabilities.supportsWorkers(for:
model.deployTargetKind)`, `workersTab`'s body is replaced with an explanation view instead of the
catalog/Inbox Capture content:

> **Worker features aren't available for this site.** [Site name] publishes to GitHub Pages, a
> plain static host with no equivalent to Cloudflare Workers. The worker catalog, Inbox Capture,
> and membership all require the Cloudflare deploy target.

This explanation intentionally does not offer a "switch to Cloudflare" action — the Settings
deploy-target picker (out of scope, above) doesn't exist yet. Once it lands, the explanation can
link to it; that's a follow-up to this design, not a blocker for it.

### Action-layer gating, not just visual

Hiding the controls is necessary but not sufficient — `PlistEditorModel.setInboxCaptureEnabled`
and the worker-catalog provisioning entry point must also guard on
`DeployTargetCapabilities.supportsWorkers(for:)` at the top and set `inboxCaptureError`/
`workersError` to the same explanation text (rather than proceeding into
`SocialWorkerProvisionCommand`) if somehow invoked anyway. This is defense in depth, not the
primary mechanism — the view won't expose the control once gated — but it matches the existing
non-bypassable-gate posture the codebase already applies to `PreDeployCheck`: a well-behaved
caller never needs the guard, but the guard exists so a future refactor of the view layer can't
silently reopen the hole by calling the model method directly.

### Relationship to `SocialWorkerProvisionCommand`'s `as?` cast

`DeployModel.swift:891-896`'s `command.target as? CloudflareDeployTarget` — and the two closures
that return `nil`/`[]` when it fails — needs no change from this design. Once action-layer gating
is in place, that code path is only reachable if gating is somehow bypassed, at which point
degrading to "provision nothing" rather than crashing is the correct fallback, not a competing
gating mechanism. Leave the comment and cast as-is.

## Error handling

No new error surface. `inboxCaptureError`/`workersError` already exist as displayed strings; the
gated state reuses them with the explanation copy above instead of a network-failure message.

## Testing

- New `DeployTargetKindTests`: `"cloudflare"` → `.cloudflare`, `"githubPages"` → `.githubPages`,
  `nil` → `.cloudflare`, an unrecognized string → `.cloudflare`.
- New `DeployTargetCapabilitiesTests`: `supportsWorkers` true only for `.cloudflare`.
- `PlistEditorModel` test: `setInboxCaptureEnabled(true)` on a site with
  `deployTarget: "githubPages"` sets `inboxCaptureError` to the explanation text and never invokes
  the provisioning closures (inject a fake that fails the test if called, matching the existing
  fake-injection pattern in `DeployModel`'s test suite).
- Manual QA per `docs/mac-assed-app-spec.md`: open Site Settings on a site with
  `deployTarget: "githubPages"` in `anglesite.json`, confirm the `.workers` tab is present in the
  tab list, and its body shows the explanation instead of the catalog/toggle.

## Migration / compatibility

None needed. `DeployTargetKind(rawValue:)` resolves `nil` (every existing site's current state)
to `.cloudflare`, so `supportsWorkers` stays `true` and the gated view never appears for a site
that hasn't opted into a non-Cloudflare target — zero behavior change until target selection
(a separate slice) actually lets a site choose GitHub Pages.

## Later slices (not this one, tracked against #1015)

- Target selection: `DeployCommand`/`DeployModel` reads `deployTarget` to pick the conformer; the
  Site Settings picker UI. Independent of this design — `DeployTargetKind`'s UI-facing resolver
  reads the same `anglesite.json` field directly rather than going through `DeployCommand`'s
  target construction, so gating works whether or not that wiring has landed yet.
- Slice 2c: token-onboarding UX for the fine-grained GitHub `Pages` PAT permission.
- Once the Settings picker exists, link the gated `.workers` tab's explanation to it.
