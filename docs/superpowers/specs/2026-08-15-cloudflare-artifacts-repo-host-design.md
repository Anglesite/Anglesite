# Cloudflare Artifacts as default site-repo host — design (#1266)

**Status:** approved design, pre-implementation. Implementation is gated on
Cloudflare Artifacts beta access (capability probe, §6).
**Issue:** [#1266](https://github.com/Anglesite/Anglesite/issues/1266) (becomes the epic).
**Reference:** [Cloudflare CI/CD announcement](https://blog.cloudflare.com/ci-workflows/).

## 1. Problem and goal

Publishing a site today requires two accounts: Cloudflare (deploy, DNS,
analytics — already integrated via `CloudflareOAuthSignIn`) and GitHub (repo
hosting for the site's `Source/` git repo, via `RepoProvider`). For Anglesite's
non-technical owners the GitHub signup is pure friction: they never see the
repo; it exists because git is the source of truth (#72).

**Goal:** a site owner publishes with only their Cloudflare account. New
sites bootstrap their `Source/` repo to **Cloudflare Artifacts** (Cloudflare's
git hosting product). GitHub remains a fully supported provider for existing
sites and by preference — no forced migration. Edits pushed from outside the
app (clone, VS Code, CLI) deploy automatically via a **CI Workflow** in the
user's Cloudflare account; in-app Publish keeps today's local
`DeployCoordinator` path.

### Decisions (owner, 2026-08-15)

| Question | Decision |
|---|---|
| Scope of "replace GitHub" | User-site repo hosting (app feature), not this repo's own CI/hosting |
| Provider mix | Artifacts is the default for new sites; GitHub kept, no migration |
| Deploy pipeline | App-local deploy stays primary; CI Workflow is a fallback that catches external pushes |
| Private beta | Design + build behind a capability probe; UI hidden for accounts without access |
| CI definition ownership | Template-owned (versions inside each site repo), per #1053 ownership rules |

## 2. Provider generalization

`RemoteRepo.parse` (AnglesiteCore/RepoBootstrapTypes.swift) currently rejects
any host that is not `github.com`. It generalizes to a `RepoHost` enum:

- `case github` — browse URL `https://github.com/{owner}/{name}` (today's behavior, unchanged).
- `case cloudflareArtifacts` — host + browse-URL shape per the Artifacts API
  (exact host TBD against the real API surface; the enum isolates it).

Unknown hosts still return `nil` — the "is this site published?" invariant
stays conservative. `RemoteRepo` gains a `host: RepoHost` property so
consumers (Settings, deploy drawer, advisories) can label the provider
without re-parsing URLs.

A new `ArtifactsRepoProvider: RepoProvider` implements the existing
two-method seam (`isAuthenticated()`, `createAndPush(name:isPrivate:source:)`):

- `isAuthenticated()` — Cloudflare OAuth token present with the Artifacts scope.
- `createAndPush` — create the repo via the Artifacts REST API, set `origin`,
  push over https with token auth. Errors map to `RepoBootstrapError` with
  owner-facing reasons, mirroring `HTTPRepoProvider`.

**Provider selection at bootstrap:** Artifacts when the capability probe (§6)
passes and the user is signed in to Cloudflare; otherwise the existing GitHub
flow, untouched. The choice is recorded implicitly by the `origin` remote —
no new per-site config key.

## 3. Auth

Reuse `CloudflareOAuthClient` / `CloudflareOAuthTokenSource`, extended with
the scope(s) Artifacts requires. Git push authenticates with the same token
over https (credential supplied per-invocation through the existing
`RepoCommandRunner` path — not written to the user's global git credential
store). No new PAT prompt; the GitHub token flow is unchanged for the GitHub
path.

## 4. CI workflow (template-owned)

A new template file — working name `Resources/Template/scripts/ci.ts`, final
name/shape per the CI SDK's conventions — ships in every new site's `Source/`
repo and defines the pipeline in TypeScript:

1. **SHA guard:** fetch the currently-deployed commit SHA (from deployment
   metadata recorded by the deploy step, both local and CI); exit successfully
   if the pushed SHA is already live. This is what makes app-driven publishes
   (local deploy, then push) cost only a no-op CI run instead of a double
   deploy.
2. Install dependencies (cached).
3. Run `scripts/pre-deploy-check.ts` — the **same file** the app runs locally.
   One gate implementation; CI makes it unbypassable even for edits the app
   never sees. Gate failures fail the run; there is no override input.
4. `astro build`.
5. Deploy (wrangler/API), recording the deployed SHA.

At bootstrap the app's only CI provisioning job is enabling CI on the
Artifacts repo. The pipeline itself versions with the template, so template
updates carry pipeline updates through the existing template-drift story.
Existing GitHub-hosted sites get no CI workflow (out of scope; no forced
migration).

## 5. App UX

- **Publish:** visually unchanged. Local deploy remains primary; the
  subsequent push triggers a CI run that no-ops on the SHA guard.
- **Deploy drawer:** learns to show CI-originated deploys — status and logs
  via the Workflows observability API — so a site updated from outside the
  app never changes silently.
- **Settings:** shows the site's repo provider (derived from `origin`).
- **Copy:** owner-language only ("where your site's files are kept safe"),
  never git/CI jargon, per the advises-not-delegates rule. Where the app
  knows the answer (which provider to use), it decides; it does not ask.

## 6. Beta gating

`CloudflareCapabilityProber` gains an Artifacts check that doubles as the
private-beta gate: accounts without access never see Artifacts UI and
bootstrap falls through to GitHub. The probe remains a permanent
availability check after GA (API outage ⇒ same graceful fallback). No
feature flag or settings toggle is needed beyond the probe.

## 7. Error handling

- Probe or repo-creation failure → clean fallback to the GitHub offer, with
  the owner-facing reason attached (`RepoBootstrapError` channel).
- Push failure → existing `RepoBootstrapError` surfacing, unchanged.
- CI failure on an external push → surfaced as an advisory in the app (same
  channel as pre-deploy gate failures today; `AdvisoryForwarding`), never
  swallowed. Logs stream to the debug pane per the logs-are-sacred rule.
- Beta API instability is contained behind `ArtifactsRepoProvider` and the
  probe; nothing outside AnglesiteCore touches the Artifacts API directly.

## 8. Testing

- `RemoteRepo` host generalization: exhaustive parse cases (both hosts, ssh
  + https forms, hostile inputs), extending the existing suite.
- `ArtifactsRepoProvider`: mocked-runner + stubbed-HTTP tests mirroring the
  existing `HTTPRepoProvider` suite; no network.
- Template `ci.ts`: `node:test` via `npx tsx --test` per template convention,
  with the deploy step stubbed; SHA-guard and gate-failure paths covered.
- E2E against real Artifacts: opt-in behind an env flag
  (`ANGLESITE_ARTIFACTS_E2E=1`), following the container-test pattern.
- `swift test` required for any template change (Swift tests couple to
  template contents).

## 9. Slices (epic breakdown)

1. **Host-agnostic `RemoteRepo` + provider selection** — pure refactor, no
   behavior change; unblocks everything else.
2. **Artifacts API client + OAuth scope + capability probe** — AnglesiteCore
   only, fully mockable.
3. **`ArtifactsRepoProvider` + bootstrap default** — new sites land on
   Artifacts when the probe passes.
4. **Template CI workflow** — `ci.ts` + SHA guard + enable-on-bootstrap;
   includes teaching the local deploy path (`DeployExecutor`) to record the
   deployed SHA the guard reads.
5. **CI surfacing** — deploy drawer status/logs + failure advisories.
6. **Settings/provider UI + docs** — polish and owner-facing copy.

Slices 1–2 can land before beta access exists (probe simply fails). 3–5
need a real API surface to verify against; the epic stays open until then.

## 10. Out of scope

- Migrating existing GitHub-hosted sites to Artifacts.
- Moving this repo's own hosting/CI/issues off GitHub.
- Retiring the GitHub providers (`GHRepoProvider`, `HTTPRepoProvider`).
- CI for GitHub-hosted sites (GitHub Actions templates).
