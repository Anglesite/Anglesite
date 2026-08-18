# Design: DeployTarget seam (slice 1 of #1015)

**Date:** 2026-08-17
**Status:** Design approved — ready for implementation planning
**Issue:** [#1015 — Deploy-target seam + a second static host (GitHub Pages) beyond Cloudflare](https://github.com/Anglesite/Anglesite/issues/1015)

## Problem

Deploy is Cloudflare-only. `Sources/AnglesiteCore/DeployCommand.swift` is a single actor whose
`deploy(...)` method interleaves provider-agnostic steps (build, `.well-known` claim merge,
`PreDeployCheck` preflight) with Cloudflare-specific ones (token resolution, worker-name-conflict
check, domain-config-drift check, wrangler upload, custom-domain attach, markdown-for-agents zone
setting, R2 source-bundle upload, `CF_*` `.site-config` persistence). There is no seam a second
host (e.g. GitHub Pages) could plug into, and no field anywhere records which target a site uses
— it's implicit.

**Owner decision (2026-08-15, issue #1015):** approved — extract a `DeployTarget` protocol seam
(the `PreDeployCheck` gate stays non-bypassable in the shared path) and ship GitHub Pages as the
second static host later, riding the existing `HTTPGitHubClient` + token onboarding. rsync/SFTP
and Netlify/Vercel are out. Direction: slice into seam-first PRs as the work dictates.

This document scopes **slice 1**: extract the seam and add the persisted deploy-target field.
No GitHub Pages conformer, no target-selection UI, no behavior change for existing sites — every
site continues deploying through Cloudflare exactly as it does today.

## Goals (this slice)

- Extract a `DeployTarget` protocol so `DeployCommand` no longer hardcodes Cloudflare.
- Move all Cloudflare-specific logic into a `CloudflareDeployTarget` conformer.
- Add a `deployTarget` field to `anglesite.json` (`DomainConfig`) so slice 2 has schema to build
  target selection on top of, without its own migration.
- Zero behavior change: every existing `DeployCommand` call site, every existing test assertion
  about Cloudflare deploy behavior, and every produced `Result` case stays identical.

## Non-goals (deferred to later slices)

- A GitHub Pages `DeployTarget` conformer.
- Reading `deployTarget` to actually select a conformer — `DeployCommand`'s target stays
  hardcoded to `CloudflareDeployTarget()` this slice.
- Site Settings UI for picking a deploy target.
- Gating Cloudflare-only features (inbox capture, membership, worker catalog) as "unavailable"
  on non-Cloudflare targets — moot until a second target exists to select.
- Any change to `HTTPGitHubClient` or GitHub token scopes.

## Architecture

`DeployTarget` becomes the seam, sitting *above* the existing `DeployExecutor` (the host-vs-
container substrate seam — unchanged, orthogonal to this one). `DeployCommand` shrinks to the
provider-agnostic spine:

1. `.well-known` claim inventory/merge (already provider-agnostic)
2. Build (via `executor`, unchanged)
3. `PreDeployCheck` preflight — **stays hard-coded in `DeployCommand`, not delegated.** This is
   the non-bypassable gate the issue calls out by name; no `DeployTarget` conformer gets a hook
   into it, and a target's `publish(context:)` is never invoked when preflight blocks.
4. Hand off to `target.publish(context:)`, which owns everything else: token resolution,
   target-specific pre-checks, the actual upload, and post-publish effects.

`CloudflareDeployTarget` is the sole conformer this slice, absorbing today's Cloudflare-specific
code from `DeployCommand.swift` close to verbatim (moved, not rewritten).

```
DeployCommand.deploy()
  ├─ merge .well-known claims                    (shared)
  ├─ executor.run(.build) / runBuildWithClaimManifest   (shared, via DeployExecutor)
  ├─ executor.run(.preflight) → PreDeployCheck.parse    (shared, non-bypassable)
  │    └─ blocked? → return .blocked(...) — target.publish is never called
  └─ target.publish(context: DeployTargetContext) → DeployCommand.Result
       (CloudflareDeployTarget owns: token gate, worker-name-conflict check,
        domain-config-drift check, wrangler run, URL extraction, custom-domain
        attach, markdown-for-agents, R2 bundle upload, CF_* .site-config writes)
```

## Components

### `DeployTarget` protocol (new: `Sources/AnglesiteCore/DeployTarget.swift`)

```swift
public protocol DeployTarget: Sendable {
    /// Stable identifier persisted in anglesite.json's `deployTarget` field (e.g. "cloudflare").
    static var id: String { get }

    /// Publishes the build produced by the shared spine and performs any target-specific
    /// pre-checks and post-publish effects. Only called after PreDeployCheck has passed.
    func publish(context: DeployTargetContext) async -> DeployCommand.Result
}

/// Everything a DeployTarget needs to publish one deploy — bundles what DeployCommand.deploy's
/// own parameter list already carries, so publish(context:) doesn't grow an unwieldy signature.
public struct DeployTargetContext: Sendable {
    public let siteID: String
    public let siteDirectory: URL
    public let configDirectory: URL
    public let executor: any DeployExecutor
    public let claimManifest: ClaimManifest?   // whatever runBuildWithClaimManifest produced
    public let onDomainAttach: (@Sendable (String) -> Void)?
    public let onMarkdownForAgents: (@Sendable () -> Void)?
    public let onProgress: @Sendable (DeployProgress) -> Void
}
```

Exact field list to be finalized against `DeployCommand.deploy`'s current parameter list during
implementation — this is illustrative, not final.

### `CloudflareDeployTarget` (new: `Sources/AnglesiteCore/CloudflareDeployTarget.swift`)

Owns the injected closures/types that `DeployCommand` injects today: `tokenSource`,
`workerScriptNamesSource`, `domainConfigDriftSource`, `customDomainAttachCommand`,
`markdownForAgentsCommand` — all move to `CloudflareDeployTarget`'s initializer, with the same
default production values (`CloudflareAPICredentials.resolve`, `HTTPCloudflareClient`, etc.)
`publish(context:)`'s body is today's `DeployCommand.deploy` steps for token gate, worker-name
conflict, domain-config drift, wrangler run, URL extraction, custom-domain attach,
markdown-for-agents, `.site-config` persistence, and R2 upload — moved over close to verbatim.

### `DeployCommand` changes

`init` gains a `target: any DeployTarget` parameter, defaulting to `CloudflareDeployTarget()` —
every existing call site (`DeployModel`, `SiteIntents`/`CommandFactory`,
`SocialWorkerProvisionCommand`) keeps compiling unchanged. `deploy()` becomes: well-known merge →
build → `PreDeployCheck` → `target.publish(context:)`. `Result` (the 5-case enum) is unchanged —
`.workerNameConflict`/`.domainConfigDrift` stay defined there since they're still valid outcomes,
just now produced by `CloudflareDeployTarget` instead of `DeployCommand` directly.

### `anglesite.json` / `DomainConfig` change

One new top-level field, following the `Domain.choice` precedent (an open string, not a closed
`enum`, so an unrecognized future value degrades gracefully for a reader that predates it):

```swift
public var deployTarget: String?  // "cloudflare" | future values; nil ≡ "cloudflare" today
```

Round-tripped by `DomainConfigStore` like every other field (unknown-key-preserving on save,
defaults to absent on a fresh file). Nothing reads this field to select a `DeployTarget`
conformer this slice — `DeployCommand`'s target stays hardcoded. The field exists purely so
slice 2 (target selection + Settings UI) has schema to build on without a migration of its own.

## Error handling

No new error surface. `DeployCommand.Result` is unchanged; `CloudflareDeployTarget.publish`
returns it exactly as `DeployCommand.deploy` does today. `PreDeployCheck` failures stay a
`DeployCommand`-level `.blocked` before `target.publish` is ever called — a target cannot bypass
it because it never runs when preflight fails. A future non-Cloudflare target simply never
produces `.workerNameConflict`/`.domainConfigDrift`.

## Testing

`Tests/AnglesiteCoreTests/DeployCommandTests.swift`'s existing `FakeExecutor`-injection pattern
keeps working unchanged (the executor is still threaded through, now via `DeployTargetContext`).
Tests that exercise Cloudflare-specific behavior (worker-conflict, domain-drift, custom-domain
attach, markdown-for-agents, R2 upload) move to a new `CloudflareDeployTargetTests.swift`,
constructing `CloudflareDeployTarget` directly instead of `DeployCommand`. Tests of the shared
spine (well-known merge, build-seam wiring, `PreDeployCheck` parsing, pre-spawn refusal) stay in
`DeployCommandTests.swift`, using a trivial fake `DeployTarget` where a target is needed at all.
This is a mechanical test-suite split — same assertions, same fakes, filed under whichever type
now owns that behavior — not new test design.

New test: `anglesite.json` round-trips `deployTarget` and preserves it as an unknown-tolerant
field, matching every other `DomainConfig` section's test coverage in
`Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift` (or equivalent).

## Migration / compatibility

None needed. `deployTarget` is a new optional field on an already-optional-everything schema
(`DomainConfig`'s own doc comment: "an absent file means 'no declarations'"). Existing
`anglesite.json` files without the field decode as `nil`, treated identically to `"cloudflare"`
everywhere it matters (nowhere, this slice — nothing reads it yet).

## Later slices (not this one, tracked against #1015)

- Slice 2+: `GitHubPagesDeployTarget` conformer, riding `HTTPGitHubClient` + a Pages-aware token
  onboarding variant (current GitHub token scopes don't include Pages — see research notes).
- Target selection: `DeployCommand` reads `deployTarget` from `anglesite.json` and picks the
  conformer; Settings UI to change it.
- Gating Cloudflare-only features (inbox capture, membership, worker catalog) as unavailable on
  non-Cloudflare targets, per the BBEdit-style capability-gated-feature labeling policy.
