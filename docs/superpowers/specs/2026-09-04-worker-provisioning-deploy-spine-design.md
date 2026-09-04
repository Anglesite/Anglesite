# Design: Route Worker provisioning through the DeployCommand spine (#1821)

**Date:** 2026-09-04
**Status:** draft
**Issue:** [#1821 — Deploy: route Worker provisioning through the DeployCommand spine; typed TOML result](https://github.com/Anglesite/Anglesite/issues/1821)

## Problem

`DeployCommand.deploy` (`Sources/AnglesiteCore/DeployCommand.swift`) is a provider-agnostic spine:
resolve target → `authorize` → build → `PreDeployCheck` (non-bypassable) → `target.publish`. Two
`DeployTarget` conformers exist, `CloudflareDeployTarget` and `GitHubPagesDeployTarget`.

Worker provisioning (`SocialWorkerProvisionCommand`, 938 lines) does not go through this seam for
most of its work. It authorizes with a hand-duplicated fragment of `CloudflareDeployTarget`'s
checks (only `checkWorkerNameConflict`, not `checkDomainConfigDrift`), then runs its own sequence
of `wrangler d1 create` / `kv namespace create` / `r2 bucket create` / `queues create` / `wrangler
secret put` / `d1 migrations apply` calls through a private `runWrangler` closure — entirely
outside `authorize`/`PreDeployCheck`. Only the very last step, the actual `wrangler deploy`,
reaches the spine, via a call to `DeployCommand(target: CloudflareDeployTarget(...)).deploy(...)`
at `SocialWorkerProvisionCommand.swift:622`.

This matters beyond tidiness: "the app cannot bypass the pre-deploy security gate" is a stated
invariant (`AGENTS.md`). A second route to Cloudflare that only partially passes through the spine
is a second place the gate — and the debug-pane log plumbing — can be forgotten or
under-applied. Concretely today: `checkDomainConfigDrift` never runs before provisioning begins,
only before the final deploy.

Separately, `["npx", "wrangler"]` argv is assembled independently in three places
(`ContainerCommandRunner.swift:47`, `ContainerCommandRunner.swift:97` (`runSecret`, shell-wrapped),
`ContainerDeployExecutor.swift:401`), each with its own copy of the `AsyncStream`-drain-to-
`LogCenter` boilerplate, and `WorkerComposition.generateWranglerToml` computes a deduped
route-pattern set (the `[assets] run_worker_first` list) that it discards into the TOML string
rather than returning to its caller.

**Correction to the issue's framing** (confirmed by code inspection, 2026-09-04): the issue was
filed against a slightly earlier snapshot. Today, `WorkerComposition.ProvisionedResources`
(`WorkerComposition.swift:153-209`) already exists as a typed, `Sendable`/`Codable` struct — it is
`generateWranglerToml`'s *input*, not something recovered by re-parsing its output. The `Result`
enum (`SocialWorkerProvisionCommand.swift:16-47`) is 6 cases, not 13. The three TOML-regex
extractors this issue asks to delete are used **only** by `readPersistedResources`
(`SocialWorkerProvisionCommand.swift:744-782`), itself invoked only as a fallback when the caller
has no `SiteSettings.provisionedWorkerResources` — i.e. they exist to recover resource ids from a
`wrangler.toml` written in a *previous app session* (or by a config predating that persisted
field), not to undo work `generateWranglerToml` "just did" in the same call. A fourth extractor,
`extractResourceID(from:)` (`:784-798`), parses `wrangler <cmd> --json` stdout for a resource just
created — a different, still-needed parser that this design leaves alone.

## Goals

- Every `wrangler` invocation the app makes — provisioning creates, secret pushes, migrations, and
  the final deploy — flows through one executor abstraction and one spine call per operation, so
  `authorize` (full checks) and `PreDeployCheck` run exactly once, before any of it, with no
  hand-duplicated fragment of the gate.
- `generateWranglerToml` returns a typed result carrying the resource ids (already typed via
  `ProvisionedResources`) alongside the route-pattern set it computes and currently discards.
  Split its 471-line body into per-binding-type section builders.
- One `WranglerInvocation` helper backs argv assembly, env allowlisting, and log draining for every
  `npx wrangler` call site.
- Delete the three TOML-regex extractors (`extractTomlString`, `extractKVNamespaceID`,
  `extractAllTomlStrings`) and their fallback-recovery caller.

## Non-goals

- Changing what gets provisioned, or the per-worker gating logic (`hasActivityPub`,
  `hasSolidOidc`, etc.) — this is a plumbing refactor, not a feature change.
- Touching `GitHubPagesDeployTarget` beyond what `DeployCommand.Result`'s new case requires it to
  exhaustively switch over.
- A general TOML parser dependency. `extractResourceID`'s JSON-output parsing is untouched.
- Retroactively migrating any pre-`provisionedWorkerResources` site config (see Open Questions).

## Approach

Considered three shapes for closing the "provisioning skips the spine" gap:

- **(A, chosen) Provisioning as a `DeployTarget` conformer.** A new conformer's `publish` does
  resource creation → secret pushes → migrations → final `wrangler deploy`, all reached through
  one `DeployCommand.deploy` call. Only option that removes the second route entirely — every
  wrangler call, not just the last one, is downstream of one `authorize`/`PreDeployCheck` pair.
- **(B, rejected) Shared plumbing, two entry points.** Extract `authorize`+`PreDeployCheck`+
  logging into a helper both `DeployCommand.deploy` and a slimmer provisioning-only command call.
  Tidier than today but preserves exactly the bug shape the issue is about: two call sites, two
  places to remember to wire the gate into.
- **(C, rejected) Defer spine unification.** Ship the typed-TOML-result and `WranglerInvocation`
  work now, leave provisioning's control flow as-is. Lower risk, but leaves the issue's headline
  concern (`checkDomainConfigDrift` not running before provisioning starts) unaddressed.

### 1. `WranglerInvocation`

New type in `AnglesiteCore` (file: `WranglerInvocation.swift`) that owns: `["npx", "wrangler"] +
subcommandArgs` assembly, env-allowlist resolution (token-only vs. token+account, per call kind),
the optional wrangler.toml guest-resync precondition (today's `.wrangler`-only #1084 fix), and the
`AsyncStream`-drain-to-`LogCenter` loop — one implementation instead of four near-identical copies
across `ContainerCommandRunner.run`/`.runSecret` and `ContainerDeployExecutor.run`'s `.wrangler`/
`.bundleUpload` cases. `runSecret`'s shell-wrapped stdin-piping stays a distinct code path (it
genuinely needs `sh -c` for the pipe), but calls into the same argv/env/drain logic.

`DeployExecutor`'s `DeployStep` enum gains a new case, `.wranglerSubcommand(args: [String])`, so
provisioning's arbitrary `d1 create <name>` / `kv namespace create <name>` / etc. calls go through
the *same* `DeployExecutor.run(step:...)` abstraction as the fixed pipeline steps
(`.build`/`.preflight`/`.wrangler`/`.bundleUpload`/`.githubPagesPublish`), rather than a separate
`CommandRunner` closure injected only into `SocialWorkerProvisionCommand`. `ContainerDeployExecutor`
implements the new case by delegating to `WranglerInvocation`.

### 2. Typed TOML result

`generateWranglerToml` changes from returning `String` to returning a new `WranglerConfiguration`
struct:

```swift
public struct WranglerConfiguration: Sendable, Equatable {
    public let toml: String
    public let resources: ProvisionedResources   // echoed back, unchanged shape
    public let effectiveRoutes: [String]          // NEW — the computed run_worker_first pattern set
}
```

`resources` is mostly an echo (it's already typed on the way in — this ask's "typed result" value
is really about not losing the route computation, plus giving callers one bundled return instead
of tracking `effectiveRouteClaims` separately for the well-known-collision check
(`WorkerComposition.withAPICatalogClaim`, `DeployModel.swift:950`) and the TOML's own route set).

The 471-line body (`WorkerComposition.swift:323-776`) splits into private per-binding-type
builders returning `[String]`, composed by the top-level function:
`assetsHeaderBlock`, `d1Block(binding:database:migrationsDir:)` (parameterized — collapses the six
near-identical `[[d1_databases]]` blocks: `DB`, `EXPERIMENTS_DB`, `AUTH_DB`, `WEBMENTION_INBOX`,
`MICROPUB_DB`, `WEBSUB_DB`, `MICROSUB_DB`), `queueBlock(prefix:queueName:)` (collapses the three
producer/consumer pairs), `kvNamespaceBlock`, `r2BucketBlock`, `durableObjectBlock`,
`triggersBlock`, `varsBlock`, `secretCommentsBlock`, `observabilityBlock`. Route-claim validation
(`:326-386`) stays inline in the top-level function since it gates the whole call (can throw
`ConfigError.invalidRouteClaim`); its output (`patterns`, `:419-424`) becomes `effectiveRoutes`.

Existing `WorkerCompositionTests.swift` (94 tests) assert on the generated TOML string — the split
must keep that string byte-for-byte identical; only the return type changes (tests read `.toml`).

### 3. Delete the TOML-regex extractors

`extractTomlString`, `extractKVNamespaceID`, `extractAllTomlStrings`
(`SocialWorkerProvisionCommand.swift:800-830`) and their caller `readPersistedResources`
(`:744-782`) are deleted outright, not replaced with a real parser. Provisioning always reads
`SiteSettings.provisionedWorkerResources` (persisted by `DeployCoordinator.persistProvisionedResources`
on every provisioning run since #1015) as the source of truth for already-created resource ids; if
that field is empty, provisioning proceeds as a fresh run. `extractResourceID(from:)` (`:784-798`,
parses `wrangler --json` create output) is unrelated and stays.

### 4. Provisioning as a `DeployTarget` conformer

New conformer, `SocialWorkerProvisionTarget` (file: `SocialWorkerProvisionTarget.swift`),
constructed from the site's `[WorkerDescriptor]`, route claims, and the same injected seams
`CloudflareDeployTarget` already exposes (`tokenSource`, `accountIDSource`, etc. — reused, not
duplicated):

- `authorize(siteDirectory:)` delegates to (wraps) `CloudflareDeployTarget`'s full authorize —
  both `checkWorkerNameConflict` *and* `checkDomainConfigDrift` — so both run once, before any
  resource creation, closing today's gap where only the name-conflict check ran early.
- `publish(context:)` runs, in order: resource creation for each gated binding (D1, KV, R2,
  queues) via `context.executor.run(step: .wranglerSubcommand(...))`, `persistConfig` after each
  step (unchanged — still needed mid-sequence since later steps like `secret put`/`migrations
  apply` need a `wrangler.toml` with a concrete id already on disk), per-worker secret pushes,
  the paid-plan/queue gate, D1 migrations, then delegates the final `wrangler deploy` to
  `CloudflareDeployTarget.publish(context:)` (composition — not a re-implementation).

`SocialWorkerProvisionCommand` shrinks to a thin adapter: build inputs, construct
`SocialWorkerProvisionTarget`, call `DeployCommand(target:).deploy(siteDirectory:)`, map the
returned `DeployCommand.Result` to its own 6-case domain result for `DeployModel`.

`DeployCommand.Result` gains one new case, `.webmentionPaidPlanConfirmationNeeded(resources:
ProvisionedResources)` — today's `asDeployCommandResult` collapses this into `.failed`, losing the
distinction `DeployModel` needs to show a "confirm paid plan" prompt rather than a hard error.
Adding the case means `CloudflareDeployTarget` and `GitHubPagesDeployTarget`'s callers gain one
more case to switch over; both simply never produce it.

`DeployModel.swift`'s `resolvedTarget as? CloudflareDeployTarget` downcast (used today to pull
`tokenSource`/`workerScriptNamesSource` out for `SocialWorkerProvisionCommand`) is replaced by
constructing `SocialWorkerProvisionTarget` directly from the same seams, rather than casting.

## Data flow

1. `DeployModel` builds a `SocialWorkerProvisionTarget` from the site's worker descriptors and the
   same Cloudflare credential/seam sources `CloudflareDeployTarget` uses.
2. `DeployCommand(target: SocialWorkerProvisionTarget(...)).deploy(siteDirectory:)` runs:
   `authorize` (name-conflict + domain-drift, once) → build → `PreDeployCheck` (once) →
   `publish(context:)`.
3. `publish` runs the resource-creation/secret/migration sequence (each step through
   `context.executor.run(step: .wranglerSubcommand(...))`, itself backed by `WranglerInvocation`),
   persisting `resources` after each step, then delegates to `CloudflareDeployTarget.publish` for
   the final deploy.
4. `DeployCommand.Result` (now 6 cases) returns to `SocialWorkerProvisionCommand`, which maps it to
   its existing domain-facing result for `DeployModel`.

## Error handling

- Partial-progress `resources` on a mid-sequence failure must remain recoverable for a retry, so a
  retry doesn't recreate already-created resources. This is unchanged from today:
  `persistConfig`/`SiteSettings.provisionedWorkerResources` writes happen *before* a step can fail,
  not after `publish` returns — so `DeployCommand.Result`'s cases don't need to carry `resources`
  themselves. `SocialWorkerProvisionCommand`'s domain result (unchanged, 6 cases, still carries
  `resources`) reads that same persisted state to re-attach it for its callers.
- Behavior change to call out explicitly in the PR: `checkDomainConfigDrift` now runs before
  resource creation begins (previously only before the final deploy) — a site with domain drift
  will now be blocked earlier, before any Cloudflare resources are created for it. This is a
  strictly earlier failure for the same underlying condition, not a new failure mode.

## Testing

- `WorkerCompositionTests.swift` (94 tests): update for the `WranglerConfiguration` return type
  (`.toml` instead of the bare string); add coverage for `effectiveRoutes`.
- `SocialWorkerProvisionCommandTests.swift` (61 tests): delete the extractor-specific tests
  (`"extracts resource ids from common wrangler JSON shapes"`, `"reads persisted resource ids from
  active wrangler.toml bindings only"`, the four `readPersistedResources` classification tests);
  replace `asDeployCommandResult` mapping tests with tests of the new unified result mapping
  (including the new `.webmentionPaidPlanConfirmationNeeded` case).
- `DeployCommandTests.swift` / `ContainerDeployExecutorTests.swift`: extend for
  `.wranglerSubcommand` and the new conformer's `authorize`/`publish` behavior (including the
  domain-drift-before-provisioning ordering change).
- New `SocialWorkerProvisionTargetTests.swift`, mirroring `GitHubPagesDeployTargetTests.swift`'s
  shape.
- New `WranglerInvocationTests.swift` covering argv assembly and env-allowlist resolution per call
  kind.
- `DeployModelDeployTargetTests.swift` / `DeployModelTests.swift`: update for the seam-construction
  change replacing the `as? CloudflareDeployTarget` downcast.

## Open questions

1. Dropping `readPersistedResources`'s TOML-reparse fallback assumes no live site's
   `SiteSettings.provisionedWorkerResources` is empty while its `wrangler.toml` already has
   provisioned bindings (i.e., no site config predates that persisted field going live). Pre-1.0
   and pre-release, this should hold, but is a one-line confirmation worth getting explicitly
   before deleting the fallback rather than assuming test coverage proves it.
2. `.webmentionPaidPlanConfirmationNeeded` becomes a real `DeployCommand.Result` case (this design)
   rather than staying wrapped only at the provisioning layer, because unifying provisioning onto
   `DeployCommand.deploy` means `DeployCommand.Result` is now the only channel back to the caller.
   Confirming this is the intended tradeoff (wider `Result` enum vs. a provisioning-specific
   wrapper type) before implementation starts.

## Related

#1682, #1683, #1750, #1015, #1515. Builds on
[`docs/superpowers/specs/2026-08-17-deploy-target-seam-design.md`](2026-08-17-deploy-target-seam-design.md)
(slice 1, which left `SocialWorkerProvisionCommand` "compiling unchanged" — this is the gap that
slice deliberately deferred) and touches the same `as? CloudflareDeployTarget` seam discussed in
[`docs/superpowers/specs/2026-08-31-capability-gating-design.md`](2026-08-31-capability-gating-design.md)
§"Relationship to `SocialWorkerProvisionCommand`'s `as?` cast".
