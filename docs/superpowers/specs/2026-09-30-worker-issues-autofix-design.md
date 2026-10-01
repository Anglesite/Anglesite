# Developer features: Worker Issues → `@dwk/workers` auto-fix — design

**Date:** 2026-09-30
**Status:** draft
**Issue:** #2095
**Related:** [Cloudflare blog: "Detect and send production issues straight to your agent"](https://blog.cloudflare.com/real-time-issue-detection/);
[Workers Issues docs](https://developers.cloudflare.com/workers/observability/issues/);
[`2026-09-04-worker-provisioning-deploy-spine-design.md`](2026-09-04-worker-provisioning-deploy-spine-design.md) (`observabilityBlock`);
[`../../specs/2026-06-29-c2-workers-integration-seam.md`](../../specs/2026-06-29-c2-workers-integration-seam.md) (the `@dwk/workers` seam);
[`../../specs/2026-08-04-software-factory-design.md`](../../specs/2026-08-04-software-factory-design.md) (#1256 — the agent pipeline these tickets feed);
[`../../specs/2026-09-08-product-direction-review-decisions.md`](../../specs/2026-09-08-product-direction-review-decisions.md) (D1 developer-tools gate, D7 `anglesite.dwk.io`)

## 1. Goal

When a `@dwk/*` catalog Worker fails in production on a site Anglesite deployed, the package's
maintainers get a de-duplicated, privacy-safe GitHub issue on
[`davidwkeith/workers`](https://github.com/davidwkeith/workers) automatically. That repo's own
coding-agent routine turns the issue into a fix PR. The site owner does nothing beyond the opt-in.

This is the first entry in a **Developer features** set. It lives behind
Settings ▸ Advanced ▸ *Show developer tools* (`DeveloperToolsVisibility`, #1964), because it
sends diagnostics to a third party and exposes infrastructure vocabulary. The first user is the
owner, on the `*.dwk.io` sites.

## 2. What Cloudflare provides

- **Issues** ([docs](https://developers.cloudflare.com/workers/observability/issues/)). Enable
  it per Worker with `[observability.issues] enabled = true`. It needs Wrangler ≥ 4.134.0, and the
  template pins 4.136.3.
  - A Wrangler deploy **without** the key turns Issues back off. The key therefore has to live in
    the generated config, not be set once in the dashboard.
  - Issues groups these into issues: uncaught exceptions, failed invocations, 5xx responses,
    `console.error`, and logs that carry stacks.
- **Automations** ([docs](https://developers.cloudflare.com/workers/observability/issues/automations/)).
  - Triggers: an occurrence threshold, or a recurrence after inactivity.
  - Destinations: the built-in Claude Code / Cursor / Devin agents, a generic webhook, or chat and
    incident tools.
  - Generic webhooks use the [Notifications webhook payload](https://developers.cloudflare.com/notifications/reference/webhook-payload-schema/)
    and carry a `cf-webhook-auth` shared-secret header.

## 3. The attribution problem

Catalog Workers are **not** separate scripts. `WorkerComposition.generateWranglerToml`
(`Sources/AnglesiteCore/Cloudflare/WorkerComposition.swift`) mounts every active `@dwk/*`
package into **one** site Worker (the template's `worker/worker.ts`). Its generated
`Config/wrangler.toml` already emits `[observability] enabled = true`.

So a Cloudflare "issue" belongs to the site Worker, not to a package. A frame can come from three
places, and each gets a different destination:

| Top in-app frame resolves to | Destination |
|---|---|
| `node_modules/@dwk/<pkg>/…` | `davidwkeith/workers`, labelled `pkg:<pkg>` |
| template code (the composed Worker's `worker/…` sources) | **not filed in v1**. Routing to `Anglesite/Anglesite` comes in a later slice, after v1 proves the pipeline. |
| site-owner code (any other in-app path), or unattributable | **not filed**; shown to the owner in the app only |

Attribution depends on source-mapped stack traces. Issues source-maps when the upload includes
maps, so composition must keep `upload_source_maps = true`; confirm this during slice 1.
Attribution uses the **first** frame that is not a runtime or `node_modules/wrangler` frame, so a
package that calls back into template code is filed against whoever threw.

A throw inside a package isn't always the package's bug. A site owner's bad config or input can
also make a package throw. The relay files against a package only when **no owner-code frame sits
above the package frame**, meaning no owner code called into it. If one does, the occurrence is
treated as unattributable and not filed. Some noise remains: a package can still throw on owner
config it reads directly, not through a call. Maintainers close those issues as `config`, and the
relay suppresses that fingerprint afterwards.

## 4. Flow

```
site Worker (Issues on) ──automation: generic webhook──▶ issues-relay (anglesite.dwk.io)
                                                         │ verify cf-webhook-auth (per-site secret, constant-time)
                                                         │ registration check (registered, not expired)
                                                         │ attribute (§3) → redact (§5) → fingerprint
                                                         ▼
                                   GitHub: search marker → comment "+N occurrences"  or  open issue
                                                         ▼
                                   davidwkeith/workers agent routine → fix PR → catalog release
                                                         ▼
                                   Anglesite catalog pin bump (scripts/bump-worker-catalog.sh)
```

**Why a relay rather than pointing each site's automation at a coding agent directly:**

- The built-in Claude Code destination needs a routine ID and token. Pasting those into every
  owner's Cloudflare account would hand out the maintainer's agent credentials.
- A per-site agent also can't de-dupe across sites. With N sites that all hit the same bug, the
  agent would open N PRs.

The relay is the one place that sees across sites. The maintainer's agent sits behind the GitHub
issue, where the repo already controls it: a label-triggered routine, or the #1256 factory.

The relay is a new first-party Worker under `Workers/issues-relay/`, next to `ControlWorker`,
served at `issues.anglesite.dwk.io` (D7). It keeps state in:

- **KV `SITES`:** one record per registered site: the hash of its secret and the catalog commit it
  last registered with. The KV TTL *is* the 30-day expiry, so no sweeper job is needed.
  *(Slice 2 chose KV over the D1 originally sketched here: the data is small key-value records
  with a TTL, and it needs no queries.)*
- **KV `STATE`:** per-fingerprint filing state (issue number, last comment day, suppression), the
  per-site replay snapshots, and the rate-limit counters.

**Fingerprinting is cross-site.** Cloudflare groups occurrences per Worker, which here means per
site, so its id can't de-duplicate one package bug hit on N sites. The relay keys GitHub issues
on a hash of the package, the exception class, and the top three package frames' file and
function. Line numbers are left out because they shift between package versions. Cloudflare's own
id, when present, is used only for per-site replay protection.

**Filing behaviour.**
- A new fingerprint opens an issue with the labels `source:anglesite-issues` and `pkg:<name>`,
  subject to the daily cap.
- An open issue gets at most one "reported again" comment per day.
- A fingerprint whose issue a maintainer closed with the `config` label is suppressed for good.
- A fingerprint whose issue was closed any other way (fixed) and then recurs opens a new issue
  that links back as a regression.
- If KV state is lost, the relay recovers the issue from a hidden
  `<!-- anglesite-issues fingerprint=… -->` marker in the issue body.

It files as a **GitHub App** installed only on `davidwkeith/workers` and `Anglesite/Anglesite`,
with Issues read/write and nothing else. A PAT would tie filing to one person and to broader
scopes.

### Registration and webhook authentication

- **Registration is authorized.** `POST /sites` never accepts a bare UUID.
  - **Domain proof** *(slice 5, shipped; replaces the app's pre-shared token)*.
    - The app keeps a random 256-bit proof key per site in the secret store
      (`WorkerIssuesProof`, `SecretAccounts.workerIssuesProofKey`). Every publish with reports on
      serves `sha256("anglesite-issues-proof:<uuid>:<key>")` from the site Worker at
      `/.well-known/anglesite-issues-proof`. That path is the `ANGLESITE_ISSUES_PROOF` var, claimed
      through `WorkerComposition.withIssuesProofClaim` so the `.well-known` collision check sees it.
    - Registration sends the key. The relay (`Workers/issues-relay/src/proof.ts`) fetches the hash
      from the claimed hostname: HTTPS only, no redirects, a 5 s timeout, at most 1 KiB, and DNS
      names only, never IP literals or `localhost`. It recomputes the hash and compares in
      constant time.
    - The proof needs no relay-side nonce state and no extra publish. A matching pair needs
      control of both the site and the key, and the hash is bound to the UUID, so it can't be
      replayed for another site.
    - Swift and TypeScript pin the same test vector.
    - A `422` means the proof isn't visible yet, usually because the publish hasn't reached every
      edge. The app retries twice, after 3 s and then 8 s, then reports and tries again on the next
      publish.
  - **Pre-shared token** (`REGISTRATION_TOKEN`). The relay still accepts it as an alternative, for
    maintainer-run registrations such as `curl` tests. The app no longer uses it and has no field
    for it.
- **The allowlist binds to the hostname only at registration.** The relay checks the claimed
  hostname against the allowlist (`*.dwk.io` for now; `*` admits any hostname), and the domain
  proof shows the registrant controls it. The relay stores only the site UUID and a SHA-256 hash of the per-site secret, then discards
  the hostname. Webhook deliveries never carry or need a hostname, which keeps §5's
  "drop the hostname" rule intact.
- **Webhook auth.** The relay hashes the incoming `cf-webhook-auth` value and compares it with the
  stored hash in constant time (`crypto.subtle.timingSafeEqual`). An unknown or expired site gets
  a `401`, and nothing is logged beyond a counter.
- **Replay protection.** Occurrence counts in the payload are absolute snapshots, not deltas. The
  relay stores `(fingerprint → last_seen, count)`. It *sets* the count and ignores any delivery
  whose `last_seen` is not newer than the stored value. A captured request replayed later
  therefore changes nothing.
- **Expiry.** A registration expires 30 days after the last deploy that renewed it. Every deploy
  with the setting on re-registers the site and slides the window forward. Expired sites are
  rejected, so an owner who revokes their Cloudflare token (and so can't delete the automation)
  leaves nothing active behind: the dangling automation just gets `401`s. The owner can also
  revoke a site from Settings, which calls `DELETE /sites/{uuid}` with the site's own secret.

### Deploying the relay

The maintainer does this once. The app never deploys the relay.

1. Create a GitHub App with **Issues: read and write** and no other permissions, and with its
   webhook turned off. Install it on `davidwkeith/workers` only.
2. Convert the App's key to PKCS#8 with
   `openssl pkcs8 -topk8 -nocrypt -in app.pem -out app.pkcs8.pem`.
3. Set the secrets. From `Workers/issues-relay`, run `npx wrangler secret put` once each for
   `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY`. `REGISTRATION_TOKEN`
   (`openssl rand -hex 32`) is optional and needed only for manual registrations.
4. Run `npx wrangler deploy`. This provisions both KV namespaces and the
   `issues.anglesite.dwk.io` custom domain.

## 5. Privacy and redaction

`davidwkeith/workers` is public, and `docs/release.md` declares **no collected data types** in the
privacy manifest. The payload can contain visitor data: request URLs, headers, logs, and any
`user.id`-style span attributes. The relay therefore builds each issue from an **allowlist** and
drops everything else:

- **Kept:**
  - the exception class (e.g. `TypeError`)
  - the stack frames under `@dwk/*` and the template, as path:line:col with no source lines
  - the package name, and the catalog commit the site sent when it registered. The payload carries
    no version, and the commit pins every package version.
  - the Worker compatibility date
  - the occurrence count, and the first-seen and last-seen times
  - the relay's cross-site fingerprint, in a hidden marker. Cloudflare's own id isn't published,
    since it is per site.
- **Dropped:**
  - the exception **message**. Masking URLs, emails and hex runs is a denylist over free text, and
    names, order ids and other identifiers would slip through. Messages stay out until the privacy
    review; a per-package opt-in may follow, for packages whose messages are known to be static.
  - request URL, headers and body
  - logs, and trace attributes
  - the site hostname and the account id (the relay keys on an opaque site UUID)

Owners who want the full context open it in their own Cloudflare dashboard. The public issue
carries **no** link there: building one needs the account id, which the relay never receives.

Before opt-in widens beyond `*.dwk.io`, a privacy review must update the manifest and add
owner-facing consent copy that is explicit about what leaves their account.

## 6. App changes

1. **Setting** *(slice 1, shipped)*. `AppSettings.workerIssuesEnabled` stores the opt-in, a new
   `Key` + `@AppStorage` flag. The toggle, *"Track errors in your site's Workers"*, appears in the
   Developer Tools section only while developer tools are on
   (`DeveloperToolsVisibility.showsWorkerIssuesSetting`). Deploy reads
   `AppSettings.tracksWorkerIssues`, which requires both settings. Hiding developer tools therefore
   switches Issues off on the next publish but keeps the stored choice. Slice 3, the slice that
   actually starts sending reports, changes the copy to say that errors go to the Workers'
   authors. A per-site override in the Workers tab can come
   later if needed.
2. **Composition** *(slice 1, shipped)*. Add a parameter `issuesEnabled: Bool` to `generateWranglerToml`,
   threaded through `SocialWorkerProvisionCommand`/`SocialWorkerProvisionTarget` from both
   `DeployModel` and the headless `SiteOperations` deploy. When both it
   and `composesWorker` are true, the observability block also emits `[observability.issues]` with
   `enabled = true`. It defaults to `false`, so existing `WorkerCompositionTests` stay
   byte-identical; add cases for the on state. Local `wrangler dev`
   (`ContainerizationControl`) always passes `false`.
3. **Registration** *(slice 3, shipped)*. After every successful publish, both deploy paths
   (`DeployModel` and the headless `SiteOperations`) call
   `WorkerIssuesReconciler.reconcileAfterPublish`. It reads `Config/wrangler.toml` to learn what the
   publish actually deployed.
   - **Issues on:** registers or renews the site with `WorkerIssuesRelayClient`, which calls
     `POST /sites`.
     - The request carries the site's proof key (slice 5; slice 3 used a pre-shared token), its
       public hostname, and `WorkerCatalogPin.commit`.
     - The per-site secret is kept in the secret store; renewal presents it so it isn't rotated.
     - `Config/settings.plist` records the hook URL, the expiry, and whether the automation step
       is done (`WorkerIssuesRelayState`).
   - **Issues off:** makes a best-effort `DELETE /sites/:uuid` and forgets the secret. If the relay
     is unreachable, its 30-day expiry cleans up.
   - **Never fails the publish.** Every outcome becomes one Debug-pane line with no secrets.
     Headless publishes read the keychain without prompting.
   - **Automation (§8 Q1): a guided dashboard step.** Cloudflare still documents no API for
     creating automations. While the owner hasn't confirmed the step for the current secret, the
     site's Workers tab shows a one-time guide: **Open Cloudflare** (the new
     `WorkerDashboardLinks.issuesURL`), **Copy Address**, **Copy Secret**, then **Done**. A rotated
     secret resets it. The step is acceptable for the `*.dwk.io` rollout but not for owners (D1),
     so replacing it with API provisioning gates slice 5.
4. **Token.** No Cloudflare API calls are needed while automations are a dashboard step, so the
   token template is unchanged. When an automations API appears, add its permission group to
   `AnglesiteTokenTemplate` (key verified live, like `ai_search`), and have
   `CloudflareCapabilityProber` show *"Reconnect Cloudflare to turn this on"* when it's missing.
4. **Token.** Add the Issues and Notifications permission groups to `AnglesiteTokenTemplate`
   (keys to be verified live, like `ai_search`). `CloudflareCapabilityProber` degrades gracefully:
   when the token lacks them, the setting shows *"Reconnect Cloudflare to turn this on."*
5. **Catalog field (optional, backward-compatible).** Add `issueTracker` to `WorkerDescriptor`.
   It lets the catalog name a package's repo if packages ever move out of the monorepo, and the
   relay defaults to `WorkerCatalogPin.repository`. It decodes with `decodeIfPresent` per
   CONTRIBUTING ▸ "`@dwk/workers` catalog coordination".

## 7. Slices

| # | Slice | Repo |
|---|---|---|
| 0 | **Spike, blocks slice 2:** capture a real generic-webhook payload with `Workers/issues-spike` and confirm it carries the stack and fingerprint (§8 Q2). Runbook and findings are in [`../../specs/2026-09-30-workers-issues-payload-spike-notes.md`](../../specs/2026-09-30-workers-issues-payload-spike-notes.md). | Anglesite (throwaway) |
| 1 | `[observability.issues]` in composition + the developer setting (no filing yet; the owner can already see Issues in the dashboard) | Anglesite |
| 2 | *(built, not deployed)* `Workers/issues-relay`, allowlist of `*.dwk.io` only. It covers authorized registration, webhook verification, attribution to `@dwk/*` only (no template routing), redaction, fingerprinting, and filing through a GitHub App to `davidwkeith/workers`. Payload parsing is confined to `src/extract.ts` and accepts any frame encoding, so slice 0's findings only ever touch that file. | Anglesite |
| 3 | *(shipped)* App registration, renewal and revocation after every publish. The automation is a guided one-time dashboard step (§8 Q1 has no API). | Anglesite |
| 4 | *(in review: [davidwkeith/workers#530](https://github.com/davidwkeith/workers/pull/530))* A `claude-code-action` workflow runs on relay-authored `source:anglesite-issues` issues. It reproduces the error with a failing test, then either opens a fix PR for review or comments a diagnosis (`agent:needs-human`, or a recommended `config` label). | workers |
| 5 | *(partly shipped)* The following are done:<br>• the domain proof replaces the access code;<br>• the owner must consent before reports start (`WorkerIssuesConsent`, versioned);<br>• the [privacy review](../../specs/2026-10-01-worker-issues-privacy-review.md) is written;<br>• the privacy manifest declares Other Diagnostic Data.<br>**Still gated:** widening (setting `ALLOWED_HOST_SUFFIXES` to `*`) waits for an Issues-automations API (§8 Q1). | Anglesite |

## 8. Open questions

1. **Can automations be created by API?** The blog says the `cf` CLI can do it, but the docs show
   only the dashboard. If there is no public endpoint, slice 3 becomes a guided dashboard step.
   That step is acceptable for the `*.dwk.io` rollout, but not for owners (D1).
2. **Payload shape (blocking, see slice 0).** Confirm that the generic-webhook payload carries the
   stack and fingerprint. The alternative is a link that the relay must dereference with a token,
   and the relay holds no owner token by design. The fallback rule is **no stack, no filing**: a
   payload without frames is counted and dropped, never filed. If the spike shows that payloads
   never carry frames, the relay design is reconsidered before slice 2. The likely replacement is
   the app itself pulling issues with the owner's token.
3. **Plan availability and cost** of Issues on Free-plan accounts once it leaves beta.
4. **Abuse.** Authorized registration (§4) keeps out spoofed sites, but a legitimately registered
   site could still flood the relay. Mitigations:
   - per-site rate limits
   - at most one new GitHub issue per fingerprint per day
   - one global daily cap on new issues per repo
