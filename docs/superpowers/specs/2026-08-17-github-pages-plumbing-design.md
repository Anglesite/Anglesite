# Design: GitHub Pages plumbing (slice 2a of #1015)

**Date:** 2026-08-17
**Status:** Design approved — ready for implementation planning
**Issue:** [#1015 — Deploy-target seam + a second static host (GitHub Pages) beyond Cloudflare](https://github.com/Anglesite/Anglesite/issues/1015)

## Problem

Slice 1 ([#1541](https://github.com/Anglesite/Anglesite/pull/1541)) extracted a `DeployTarget` protocol seam with `CloudflareDeployTarget` as the only conformer. Shipping a second target — GitHub Pages — needs more than a new conformer: research while scoping "slice 2" turned up three gaps in the surrounding machinery that a `GitHubPagesDeployTarget` would hit immediately:

1. **`DeployStep` is a closed 4-case enum** (`.build`, `.preflight`, `.wrangler`, `.bundleUpload`) that `ContainerDeployExecutor` maps to argv run *inside the container guest*. The built `dist/` only ever exists in that guest's filesystem (`/workspace/site/dist`) — it is never synced back to the host. Cloudflare's target can use `context.executor.run(step: .wrangler, ...)` because `wrangler deploy` also runs in-guest, next to the build output it needs. A GitHub Pages target needs the same treatment — its publish step must run in-guest too — which means a new `DeployStep` case, not something a target can do entirely on its own.
2. **No existing config tracks a site's GitHub repo.** `.site-config`/`SiteSettings` has nothing; the only source of truth today is `git remote origin`, read live via `RepoBootstrap.remote(of:)` and never persisted app-side. Publishing to a dedicated repo (decided below) needs somewhere durable to record which one.
3. **No GitHub Pages API client method exists.** `HTTPGitHubClient` has `createRepo`, repo-security, and advisory methods, but nothing for `POST /repos/{owner}/{repo}/pages`.

This document scopes **slice 2a**: the plumbing alone — extend the executor seam, add the config field, add the API client method. **No behavior change**: nothing calls any of this yet. Slice 2b (a separate design) builds `GitHubPagesDeployTarget` on top of it — repo creation, token onboarding UX, and the actual deploy flow.

## Owner decisions from brainstorming (2026-08-17)

- **Repo visibility:** GitHub Pages on a free plan requires a **public** repo (private-repo Pages needs GitHub Pro/Team). Anglesite's existing "Publish to GitHub" flow pushes the whole `Source/` repo (git history, drafts, `.site-config`) as the site's canonical backup — making that public by default is the wrong tradeoff for most owners. Pages instead publishes to a **separate, dedicated public repo** containing only built `dist/` output. `Source/` stays exactly as private (or not) as the owner already has it, independent of choosing GitHub Pages as a deploy target.
- **Publish mechanism:** each deploy does a **fresh, force-pushed commit** — `git init` a throwaway repo directly in `dist/`, one commit, force-push to the Pages repo's `main` branch. No deploy history is preserved on that branch, matching how the ecosystem's `gh-pages` tool and `peaceiris/actions-gh-pages` GitHub Action both work by default. Simplest possible guest script: no clone step, no working-tree diff against the previous deploy.
- **Config location:** a new top-level `githubPages` section on `DomainConfig`/`anglesite.json`, git-tracked — following the schema-versioned "declared intent" pattern the file already established in slice 1, and the section-per-provider precedent (`edge.cloudflare`) the original domain-config investigation doc anticipated. Not `.site-config`: that file's `CF_*` keys are exactly the "provider-shaped flat file" pattern the anglesite.json investigation doc was moving away from; adding `GHP_*` keys would repeat it for a second provider.
- **Since the repo is dedicated** (only ever contains built output, created and controlled by the app), there is no need to distinguish a `gh-pages` branch from the default branch the way a shared source+output repo would — publish straight to `main`. No `branch` field in the schema; the guest script's target branch is hardcoded.

## Goals (this slice)

- Add `DeployStep.githubPagesPublish` and wire it through `ContainerDeployExecutor` (guest git-push script) and `HostDeployExecutor` (`.unavailable`, matching `.bundleUpload`).
- Add `HTTPGitHubClient.enablePages(owner:repo:token:)`.
- Add `DomainConfig.githubPages: GitHubPages?` (`owner`, `repo`), round-tripped by `DomainConfigStore` like every other section.
- Zero behavior change: no new call sites invoke any of this yet.

## Non-goals (deferred to slice 2b)

- `GitHubPagesDeployTarget` itself (the `DeployTarget` conformer).
- Repo auto-creation, first-deploy detection, Pages-enable orchestration.
- Token onboarding UX for the new `Pages` fine-grained PAT permission (confirmed via GitHub's docs to be **distinct from `Administration`** — not covered by today's token recipe).
- Reading `anglesite.json`'s `deployTarget` (from slice 1) to actually select a conformer — still out of scope until a target-selection slice exists.
- Any Settings UI.

## Components

### `DeployStep` (modify: `Sources/AnglesiteCore/DeployExecutor.swift`)

One new case:

```swift
public enum DeployStep: Sendable {
    case build
    case preflight
    case wrangler
    case bundleUpload
    /// Force-pushes the built `dist/` to the site's dedicated GitHub Pages repo (#1015 slice 2a).
    /// Only meaningful for `ContainerDeployExecutor` — `dist/` lives in the guest's filesystem,
    /// never synced to the host, so this step (like `.wrangler`) must run in-guest.
    case githubPagesPublish
}
```

### `ContainerDeployExecutor.guestArgv` (modify: `Sources/AnglesiteCore/DeployExecutor.swift`)

A new case in the `switch step` in `guestArgv(for:siteDirectory:)`. Reads `githubPages.owner`/`.repo` from the HOST `siteDirectory`'s `anglesite.json` (mirroring `bundleUploadBucket(siteDirectory:)`'s synchronous `.site-config` read for `.bundleUpload`) and builds a script that:

1. `cd`s into `dist/` (relative to `/workspace/site`, the guest's working directory).
2. `git init`, stages everything, commits once with a fixed author/message (no owner git identity needed — this is a throwaway commit, never attributed to the owner's own git config).
3. Force-pushes to `https://x-access-token:$GITHUB_PAGES_TOKEN@github.com/<owner>/<repo>.git` on `main`.

Owner and repo are passed as **positional shell parameters** (`sh -c 'script' sh "$1" "$2"`), never spliced into the script text — matching `.bundleUpload`'s injection-safety pattern for the bucket name exactly, including its verification method (feeding a payload containing shell metacharacters through a real `sh` invocation and confirming nothing executes). The token itself is read from the guest's own environment (`$GITHUB_PAGES_TOKEN`, added to `guestEnvAllowlist` below) — never a shell argument, never logged, matching `CLOUDFLARE_API_TOKEN`'s existing handling.

Returns an empty/no-op script (or a step that fails cleanly with a clear reason) when `anglesite.json` has no `githubPages` section — this step should never be reached in that state once 2b's target guards it, but the argv builder itself should degrade safely rather than crash, matching `bundleUploadBucket`'s `nil`-returns-empty-string precedent... except here the safer behavior is failing loudly (missing owner/repo is a real misconfiguration, unlike `.bundleUpload`'s "not configured = skip the whole step" case, which `DeployCommand`/the future target guard before ever calling `.run(step: .githubPagesPublish, ...)`). Concretely: if owner or repo is missing, `guestArgv` returns a script that echoes an error to stderr and exits 1, rather than a script that would silently push to a malformed URL.

### `ContainerDeployExecutor.guestEnvAllowlist` (modify)

Add `"GITHUB_PAGES_TOKEN"` alongside `"CLOUDFLARE_API_TOKEN"`.

### `HostDeployExecutor.defaultResolver` (modify)

Add a `case .githubPagesPublish:` arm returning `{ _ in .unavailable(reason: HostNodeRetirement.reason("GitHub Pages publish")) }`, matching `.bundleUpload`'s arm exactly.

### `HTTPGitHubClient.enablePages` (new method: `Sources/AnglesiteCore/HTTPGitHubClient.swift`)

```swift
public func enablePages(owner: String, repo: String, token: String) async throws {
    // POST /repos/{owner}/{repo}/pages — build_type: "legacy", source: {branch: "main", path: "/"}
    // (POST creates a Pages site; PUT would update an already-configured one — POST is correct
    // here since 2b calls this to configure Pages for the first time). Not idempotent: throws on
    // any non-2xx status, mirroring createRepo's error mapping exactly — transport failure →
    // .network, 401/403 → .unauthorized(status:), 422 → .api(message:) decoded from
    // GitHubErrorResponse, any other non-2xx (including 409) → .http(status:). Unlike createRepo,
    // there is no tolerance shape here: a repo that already has Pages configured surfaces as an
    // error from this method, and it's on the caller (slice 2b) to decide how to handle that,
    // since the exact status GitHub returns for "already enabled with this source" vs. "already
    // enabled with a different source" wasn't verified against a live account.
}
```

Uses the file's existing `repoRequest(method:path:token:)`/`send(_:)` machinery and `GitHubErrorResponse` decoding, matching every other method in the file. Exact request/response types (a `PagesConfigRequest` Codable struct for the body) get nailed down at implementation time against GitHub's actual JSON shape — this design fixes the endpoint, method, and body semantics, not the Swift type's field-by-field spelling.

### `DomainConfig.githubPages` (modify: `Sources/AnglesiteCore/DomainConfig.swift`)

```swift
/// The dedicated public repo a GitHub Pages deploy target publishes built output to (#1015
/// slice 2a) — always a separate repo from wherever Source/ itself might be backed up, so
/// choosing GitHub Pages never forces the site's source history public. `nil` until a
/// GitHubPagesDeployTarget has created (or been pointed at) one.
public struct GitHubPages: Codable, Equatable, Sendable {
    public var owner: String?
    public var repo: String?

    public init(owner: String? = nil, repo: String? = nil) {
        self.owner = owner
        self.repo = repo
    }
}
```

Added as `public var githubPages: GitHubPages?` on `DomainConfig`, wired into the manual `Codable` conformance (`CodingKeys`, `decodeIfPresent`/`encodeIfPresent` in both `init(from:)` and `encode(to:)`) exactly like slice 1's `deployTarget` field — same mechanical pattern, reusable as a template.

## Error handling

No new error surface. `.githubPagesPublish`'s guest-script failures (push rejected, network failure, bad token, malformed owner/repo) surface through the existing `DeployStepResult`/`exitCode` path unchanged, the same as every other `DeployStep`. `HTTPGitHubClient.enablePages` throws the file's existing `GitHubRepoAPIError` cases (`.network`, `.unauthorized`, `.http(status:)`), matching every other method.

## Testing

- `Tests/AnglesiteCoreTests/DeployExecutorTests.swift` (or `ContainerDeployExecutorTests.swift`): argv shape for `.githubPagesPublish` (via `ContainerDeployExecutorTestHook`), plus an injection-safety test for both `owner` and `repo` mirroring `bundleUploadArgvIsSafeAgainstShellInjectionInBucketName` — feed a payload containing shell metacharacters through a real `sh` invocation, confirm nothing executes.
- `HostDeployExecutor`: a test confirming `.githubPagesPublish` resolves to `.unavailable`, matching the existing `.bundleUpload`/`.wrangler`/`.build` coverage in `DeployCommandTests.swift`'s `defaultHostResolversUnavailable`-style tests.
- `guestEnvAllowlist`: a test confirming `GITHUB_PAGES_TOKEN` passes through `guestEnvironment(from:)` and nothing else does, mirroring the existing `CLOUDFLARE_API_TOKEN` coverage.
- `Tests/AnglesiteCoreTests/HTTPGitHubClientTests.swift` (existing file, extend): `enablePages` success, 401/403, and network-failure cases via the file's existing transport-mock pattern.
- `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`: extend the comprehensive round-trip test with `githubPages: .init(owner: "example-owner", repo: "example-site-pages")`, matching slice 1's `deployTarget` addition exactly.

## Migration / compatibility

None needed. `githubPages` is a new optional field on an already-optional-everything schema; existing `anglesite.json` files decode it as `nil`. `DeployStep.githubPagesPublish` is additive to a `Sendable` enum with no `@unknown default` exhaustiveness concerns inside this module (every `switch` over `DeployStep` in `Sources/AnglesiteCore` gets a compiler error at the new case until handled — a natural, compiler-enforced checklist of every place slice 2a must touch).

## Later slices (not this one, tracked against #1015)

- **Slice 2b:** `GitHubPagesDeployTarget` conformer — repo auto-creation (`HTTPGitHubClient.createRepo(isPrivate: false, ...)`) on first deploy, calling `enablePages` once Pages is configured, `authorize()`/`publish()` wiring `context.executor.run(step: .githubPagesPublish, ...)` with `GITHUB_PAGES_TOKEN` in the environment, and persisting `DomainConfig.githubPages` once the repo exists.
- **Slice 2c (likely):** token onboarding UX for the `Pages` fine-grained PAT permission — either broadening the existing GitHub token recipe copy for everyone, or a separate additive prompt shown only when GitHub Pages is chosen as a deploy target. Needs its own design; not decided here.
- Target selection (reading `deployTarget` to pick a conformer) and Settings UI, per slice 1's own deferred list.
