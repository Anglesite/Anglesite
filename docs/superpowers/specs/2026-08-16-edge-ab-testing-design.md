# Edge A/B testing machinery + persisted experiment config — design (#1270)

**Status:** approved design, pre-implementation — the three open questions were
answered by the owner 2026-08-16 (§12). Implementation slices get filed from
this doc (owner decision on #1270, 2026-08-15).
**Issue:** [#1270](https://github.com/Anglesite/Anglesite/issues/1270), follow-up to
#769 (manual-entry Experiment Results sheet + `AnalyzeExperimentIntent`).
**Prior art:** the retired `experiment` Claude skill (ADR-0014 "edge A/B testing":
build-time variants + edge assignment) and its `ab-stats.ts`, whose math already
lives on as `ExperimentStats` (`Sources/AnglesiteCore/ExperimentStats.swift`).

## 1. Context and goal

#769 shipped the "monitor" half of the experiment lifecycle: the owner types each
variant's visitor/conversion counts into the Experiment Results sheet
(`ExperimentStatsSheetView` / `ExperimentStatsModel`) or Siri
(`AnalyzeExperimentIntent`), and `ExperimentStats` returns an exact Bayesian
verdict in plain language. Nothing feeds those counts: there is no variant
assignment at the edge, no persisted experiment config, and no pipeline that
turns visits into numbers. The retired skill had all three (KV config, Worker
middleware, Analytics Engine events) but none of it survived the Claude Code
removal (#466) — the machinery must be rebuilt as deterministic template
TypeScript + Swift, with no LLM in the loop.

**Goal:** a site owner can run a real A/B test end to end — propose, configure,
run at the edge, read live results, promote the winner — without leaving the
app, without statistics vocabulary, and without leaving the Cloudflare free
tier. A CLI user editing a clone of `Source/` can do the same by hand, because
every piece of experiment state that defines the site's behavior lives in git
(#72).

Like the retired skill, experiments run in three layers, now with deterministic
owners:

1. **Build time** — the variant page is an ordinary Astro page committed in
   `Source/`, built into `dist/` alongside the control. Zero flicker, zero
   client JS, and every existing gate (a11y, PII, CSP) sees variant markup.
2. **Edge** — the site's existing composed Worker
   (`Resources/Template/worker/worker.ts`) assigns visitors to a variant via a
   first-party cookie and serves the matching built asset.
3. **Analysis** — the Worker records first-visit and first-conversion counts in
   the site's D1 database; the app reads them over the Cloudflare REST API and
   feeds `ExperimentStats.analyze` — the same function the manual sheet uses
   today.

## 2. `experiments` config schema

A new optional `experiments` section in `Source/anglesite.json`, joining
`domain`/`dns`/`edge`/`email`/`workers` in `DomainConfig` (#1169) and the
template-side mirror in `scripts/anglesite-config.ts`:

```jsonc
{
  "experiments": {
    "active": [
      {
        "id": "homepage-hero",             // [A-Za-z0-9-]+, stable, cookie + D1 key
        "name": "Homepage headline",       // owner-facing display name
        "page": "/",                        // route under test (control serves as-is)
        "variant": {
          "id": "b",
          "name": "Fresh eggs headline",   // owner-facing variant name
          "page": "/x/homepage-hero/b/"    // built route of the variant page
        },
        "split": 0.5,                       // control share; app always writes 0.5
        "goal": { "kind": "pageview", "path": "/contact/thanks/" },
        // or, client-side kinds (owner decision, 2026-08-16 — see §4):
        //   { "kind": "scroll",  "depth": 75 }
        //   { "kind": "visible", "selector": "#testimonials" }
        "status": "running",               // "draft" | "running"
        "startedAt": "2026-08-16"          // ISO date; drives the 30-day rule
      }
    ]
  }
}
```

Schema notes:

- **Two variants per experiment, one experiment active at a time** (v1). This is
  the retired playbook's "one test at a time, sequential" rule and exactly
  matches `ExperimentStats.analyze`'s control/treatment signature. The `active`
  array leaves room to relax both later without a schema break.
- **`variant.page` is an explicit route**, not a naming convention. The app
  scaffolds variant pages under a reserved namespace (working name
  `/x/<experimentId>/<variantId>/`), but nothing at the edge or in validation
  depends on the convention — a hand author can point at any built route.
- **Four `goal` kinds in v1** (owner decision, 2026-08-16). Two edge-visible:
  a `pageview` of a goal path (thank-you page), and — once the Cloudflare-native
  contact form (free-services Slice 2) lands — a claimed POST route like
  `/api/contact` (`kind: "route"`). Two client-side, observed on the tested
  page itself and reported through the goal beacon (§4): `scroll` (visitor
  scrolled past `depth` percent, 1–100) and `visible` (the element matching
  `selector` entered the viewport). Client-side kinds cover the playbook tests
  that never leave the page (headline, narrative structure, social-proof
  placement).
- **`split` is control's share.** The app always writes `0.5`; the field exists
  so `hasSampleRatioMismatch(expectedControlWeight:)` and a hand author agree on
  what was intended.

### Why git-canonical

Per the domain-config investigation (2026-07-31, §5.1), *declared intent* lives
in `Source/anglesite.json`; identity and observation stay out. An experiment
definition is declared intent in the strictest sense: it determines what the
deployed site serves, its variant page is already a committed file in
`Source/`, and a clone edited outside the app must be able to see, start, and
stop tests (git is the source of truth, #72). It contains no secrets, no
resource IDs, and no counts.

The *observed* side — impression/conversion tallies and concluded-experiment
outcomes ("what have we learned") — is not intent and never enters git. Live
tallies exist only in D1; when an experiment concludes, the app appends an
outcome record (winner, final counts, dates, the applied decision) to an
app-owned `Config/experiment-history.json` and removes the entry from
`anglesite.json`. `DomainConfigStore`'s unknown-key-preserving round trip
already covers hand edits and forward compatibility.

Rejected: KV-persisted config (the retired skill's choice, "mutable without
rebuild"). Variants are build-time pages, so every meaningful config change
requires a build + deploy anyway — KV's one advantage never materializes, and it
would put site-defining state outside git and cost a KV read on every bucketed
request for nothing (§9).

## 3. Edge bucketing

### Assignment and serving

`worker.ts` gains an experiments middleware ahead of the `ROUTES` dispatch,
reading a build-time artifact (working name `worker/experiments.json`,
generated at prebuild from `anglesite.json` the same way the other
config-derived edge artifacts are — gitignored, derived, never hand-edited).
For a request whose pathname matches a running experiment's `page`:

1. Read `exp_<id>` from the Cookie header.
2. No cookie → draw a variant by `split`, and count one **impression** for the
   drawn arm (first visit only — see §4).
3. Serve the assigned arm: control → pass the request through to `ASSETS`
   untouched; variant → `env.ASSETS.fetch` for `variant.page`'s asset, returned
   under the original URL (no redirect, no flicker).
4. On first assignment, `Set-Cookie: exp_<id>=<variantId>; Path=/; Max-Age=2592000;
   SameSite=Lax; HttpOnly; Secure`. HttpOnly because no client script ever needs
   it; 30 days matches the experiment-duration rule of thumb.

For a goal signal — a request on a `pageview` goal path, a conversion hook
inside the claimed route handler for `route` goals, or a beacon hit for the
client-side kinds (§4) — the same conversion rule applies everywhere: if an
`exp_<id>` cookie is present and no `exp_<id>_c` cookie is, count one
**conversion** for that arm and set `exp_<id>_c=1` (same attributes). Unique
visitors and unique converters, matching the "Visitors / Conversions" semantics
the sheet and `ExperimentStats` already use.

### Routing the requests into the Worker

Static assets normally serve asset-first; the Worker only sees claimed routes.
Experiment pages are arbitrary site paths — including `/`, which
`WorkerRouteClaims.pathProblem` deliberately refuses to let a *catalog worker*
claim, and which must stay unclaimable by them. So experiment paths do **not**
become catalog route claims. Instead `WorkerComposition.generateWranglerToml`
gains an `experiments` input alongside `routeClaims` and emits the experiment
`page`, pageview-goal, and (when a client-side goal is configured) beacon
endpoint paths into the same `[assets].run_worker_first` list,
with their own narrower validation (absolute path, no traversal/encoding —
reusing `pathProblem`'s character rules — but permitting `/`) plus a collision
check against active route claims (an experiment can't sit on `/micropub`).
Because run-worker-first patterns are exact paths, the rest of the site keeps
Cloudflare's asset-first serving untouched.

A running experiment also becomes the third enabler of Worker composition
itself: `main = "worker/worker.ts"`, the `ASSETS` binding, and the D1 block are
emitted when `hasSocialFeatures || inboxCaptureEnabled || hasRunningExperiment`.
A static-only site that starts its first test gets a Worker for exactly the
experiment paths and nothing else.

### Cache implications

- **Edge:** run-worker-first routes bypass asset-first serving, so every request
  on the experiment page and goal path invokes the Worker — no shared cache sits
  between visitor and assignment, which is what makes cookie-keyed responses
  safe without `Vary: Cookie` gymnastics. `env.ASSETS.fetch` is still served
  from Cloudflare's asset store, so the cost is a Worker request, not an origin
  fetch.
- **Browser:** the template's `public/_headers` already serves HTML with
  `Cache-Control: public, max-age=0, must-revalidate`, so a visitor never keeps
  a stale arm after promotion. Hashed `/_astro/*` assets stay immutable and
  shared across arms.
- **SEO:** the scaffolded variant page carries `rel=canonical` → the control URL
  and `noindex`, and is excluded from the sitemap; the pre-deploy gate enforces
  all three (§6). Direct visits to the variant URL stay harmless.

### Privacy

Unchanged from the retired skill's posture, now enforced by construction:
first-party functional cookies holding only a variant id, no PII anywhere in
the pipeline, no third-party scripts (the CSP's `script-src 'self'` never
changes — the goal beacon in §4 is a first-party static file), all data in the
owner's own Cloudflare account. Bot Fight Mode (already integrated) filters
upstream; residual skew is what the SRM check is for.

## 4. Event recording and the analytics pipeline

### What Cloudflare gives us — and doesn't

Cloudflare Web Analytics / RUM (#1114, `CloudflareRUMAnalyticsClient`) reports
pageviews and visits by day; it has no custom dimensions on the free plan, so
it **cannot attribute anything to a variant**. It stays what it is — the site's
traffic overview and a sanity cross-check — and the experiment pipeline records
its own events at the moment of assignment, the only place variant attribution
exists.

### Client-side goals: the beacon

The `scroll` and `visible` goal kinds (owner decision, 2026-08-16) are observed
in the visitor's browser and reported to the same Worker that owns every other
count. Variant *assignment* stays entirely server-side — the beacon observes
goals only, so the §9 rejection of client-side assignment stands.

- **Injection is build-time and template-owned.** The base layout includes
  `<script src="/x/goal-beacon.js" defer …>` only on a running experiment's
  `page` and `variant.page` and only when that experiment's goal is a
  client-side kind — driven by the same prebuild config artifact as the Worker
  (§3), so a concluded experiment removes the script at the next publish. Goal
  parameters (experiment id, kind, `depth`/`selector`) travel as `data-`
  attributes on that tag; nothing is inline.
- **CSP stays exactly as shipped.** `script-src 'self'` covers a first-party
  static file; `connect-src 'self'` covers the beacon send. The gate would
  reject any variant of this design that needed the policy widened.
- **The beacon is a few hundred bytes and fires at most once per page view:**
  a passive scroll listener (threshold crossing) or one `IntersectionObserver`
  callback, then `navigator.sendBeacon("/x/goal?e=<id>")` (with a `keepalive`
  fetch fallback) and the listener disconnects. No polling, no scroll
  telemetry stream, no layout work.
- **Counting happens server-side, same rule as every goal.** The `/x/goal`
  endpoint (POST-only, routed through the experiments `run_worker_first`
  emission, §3) validates the id against config, reads the `exp_<id>` cookie
  for the arm, applies the `exp_<id>_c` dedupe, counts via `ctx.waitUntil`,
  and returns `204`. No assignment cookie → `204` no-op: unassigned visitors
  and bots produce nothing.
- **What is and isn't collected:** collected — that a configured goal was
  reached, for one experiment id, attributed to the arm already in the
  visitor's cookie, aggregated into a daily counter. Not collected — URLs
  beyond the same-origin request itself, referrers, scroll positions, element
  contents, timestamps finer than the day bucket, IP addresses (never stored),
  or any identifier; the beacon body is empty. The pipeline's privacy posture
  (§3) is unchanged: first-party functional measurement with no cross-site
  tracking, so it introduces no consent banner and respects whatever privacy
  stance the site already declares.

### D1 counters

Events land in the site's per-site D1 database — **decided (owner,
2026-08-16): the same database the social workers share** (`{siteName}-social`,
bindings `DB`/`AUTH_DB`/…, experiments tables beside the webmention inbox — one
database, one provisioning path), with an experiments migration in
`worker/migrations/`. One aggregate row per
`(experiment_id, variant_id, metric, day)`, written from the middleware via
`ctx.waitUntil` (never blocking the response) as
`INSERT … ON CONFLICT DO UPDATE SET n = n + 1`. Sites without social features
provision the database on first experiment start through the existing
provisioning seam (`SocialWorkerProvisionCommand`'s D1 path).

Free-tier accounting says D1 comfortably fits: only *first* visits and *first*
conversions write (a returning visitor costs zero writes, and a deduped beacon
hit costs zero too), and reads happen only when the app checks results.
Rejected alternatives — Analytics Engine, KV counters, and a dedicated
experiments database — in §9.

### App-side read path

A new `ExperimentEventsD1Client` in AnglesiteCore mirrors
`WebmentionInboxD1Client`: Cloudflare REST `d1/database/{id}/query` with the
existing onboarded token, returning per-arm visitor/conversion counts plus the
observed split. It feeds:

- **`ExperimentStatsModel`** — when the site has a running experiment and a
  token, the sheet pre-fills live counts (still editable; Analyze works exactly
  as today). No experiment, no token, or a non-Cloudflare deploy → the #769
  manual-entry behavior is the unchanged fallback, which is also the migration
  story: nothing about #769 is removed.
- **`AnalyzeExperimentIntent`** — gains a zero-argument path ("How is my test
  going?") that resolves the running experiment and its live counts; the
  count-parameter form stays for manual use.

## 5. Experiment lifecycle

`propose → configure → running → conclude (promote | keep | discard)`, with the
decision split following the experts-advise rule: **the app decides everything
it knows the answer to; the owner decides only what changes their site's
content.**

| Step | Who decides | What happens |
|---|---|---|
| Propose | App suggests, owner picks | `ExperimentStats.suggestionPlaybook` (already shipped) ordered by expected impact, or the owner's own idea. Nothing persisted. |
| Configure | Owner approves copy | App duplicates the page under test into the variant route (canonical + noindex + sitemap exclusion applied by the scaffold), owner edits the variant — the same editing surfaces as any page. Writes a `draft` entry. |
| Start | App | Flips `status` to `running`, stamps `startedAt`, regenerates wrangler config, and publishes through the ordinary deploy path — gate included. Copy: "Your test is live. Visitors will see one version or the other; I'll tell you when there's a clear answer." |
| Monitor | App | Sheet/intent show live counts in the existing plain-language format. Below the data floor (`minimumImpressionsPerVariant`, 30 days): "too early to tell", never numbers-as-verdict. SRM trip: the app says the test's traffic split looks broken and offers to restart it — it does not ask the owner to diagnose. |
| Conclude | **Owner** (one click) | At ≥95% confidence the app proposes the consequence, not the statistic: "*Fresh eggs headline* is bringing you about 18% more contact-form messages. Make it the site's headline?" Promote: apply the variant's content to the control page in git, delete the variant page, drop the config entry, append the outcome to `Config/experiment-history.json`, publish. Keep-the-original and discard-early do the same minus the content change. |

Promotion is a normal git commit through the app's normal editing machinery, so
"put it back" is the site's ordinary history/undo story — rollback needs no
dedicated mechanism. **Decided (owner, 2026-08-16): promotion is owner-click
only — there is no auto-promote**, and no per-experiment opt-in for one. The
app advises with the strongest consequence-phrased recommendation it can make;
the click that visibly changes the site's content always belongs to the owner
(the retired skill's auto-promotion does not return).

All UI extends the existing Experiment Results sheet surface and its menu
command — Mac-native sheet + App Intents per the platform UX standard, no new
window class.

## 6. Pre-deploy gate interaction

`pre-deploy-check.ts` stays network-free and unbypassable; it gains one check
family, `checkExperiments`, folded into the versioned scan envelope:

- `experiments` section parses and is schema-valid (extending
  `checkAnglesiteConfig`), ids well-formed, `split` in (0,1), one running
  experiment max, and goal parameters complete for the kind (`path` present and
  built for `pageview`, `depth` in 1–100 for `scroll`, non-empty `selector`
  for `visible`).
- Every running experiment's `page`, `variant.page`, and pageview-goal path
  exist in `dist/` (a test that 404s its own arm burns traffic silently — this
  is exactly the class of misconfiguration SRM would only catch a week later).
- The variant page carries canonical → control and `noindex`, and is absent
  from the generated sitemap.
- For a client-side goal: the beacon script asset exists in `dist/`, and both
  the control and variant pages' built HTML include the beacon tag (a test
  whose goal can never fire is the same silent-traffic-burn class as a 404
  arm).
- Experiment paths don't collide with worker route claims or `/.well-known/`.

Because starting, changing, and concluding an experiment all ship through the
ordinary deploy path, the gate covers every transition, including hand edits
pushed from outside the app (and, once #1266's CI workflow lands, pushes the
app never sees). App-side, deploy-time drift validation rides the existing
declared-vs-live slot (#1173) — no new mechanism.

## 7. Free-tier accounting

| Resource | Used for | Free-plan budget | Fit |
|---|---|---|---|
| Worker requests | experiment page, goal path, beacon endpoint | 100k/day | Only bucketed routes invoke the Worker; the beacon fires at most once per page view; the rest of the site stays asset-first |
| D1 | counters + outcomes | 100k row writes/day, 5M reads/day | Writes only on first visit / first conversion |
| KV | — | — | Not used |
| Analytics Engine | — | — | Not used |
| Web Analytics (RUM) | traffic overview only | free | Unchanged (#1114) |

No metered-by-reader-traffic service is introduced, keeping the roadmap's
flat-free posture (free-services design §12's disclosure pattern is not
needed here).

## 8. Testing

- **Template:** middleware + counting in `worker.test.ts` (vitest — worker
  suites are the template's one vitest holdout); config reader, artifact
  generation, and `checkExperiments` via `npx tsx --test` (node:test) per
  template-script convention. Cookie idempotence, split determinism under a
  seeded RNG, goal dedupe (including beacon hits with no/duplicate cookies and
  unknown experiment ids), and 404-arm cases covered. The beacon script itself
  gets vitest coverage with stubbed `IntersectionObserver`/scroll events and a
  captured `sendBeacon`.
- **Swift:** `DomainConfig` round-trip with unknown keys, composition snapshots
  (run-worker-first emission incl. `/`, third-enabler gating, claim-collision
  rejection), `ExperimentEventsD1Client` against stubbed HTTP, model prefill +
  fallback. `swift test` runs on any template change (Swift tests couple to
  template markup).
- **E2E:** opt-in live-Cloudflare case behind the existing container/E2E flag
  pattern; not required for CI.

## 9. Alternatives considered

- **KV for experiment config** (retired skill): rejected — §2; rebuilds are
  required anyway, git-canonicality wins, and it adds a per-request KV read.
- **Analytics Engine for events** (retired skill): rejected — 90-day retention
  loses slow experiments' history, beta pricing is unsettled, its SQL API is a
  second query surface to integrate, and it's write-only-then-aggregate where
  we need four counters. D1 is already provisioned, durable, and free at this
  scale.
- **Client-side assignment JS**: rejected — flicker, CLS, and the
  no-third-party-JS posture (ADR-0008). Assignment stays server-side even
  though v1 *observes* client-side goals: the goal beacon (§4) never chooses or
  swaps content, only reports that a threshold was crossed, so the flicker/CLS
  argument doesn't apply to it and the CSP never widens for either.
- **A dedicated experiments D1 database**: rejected (owner, 2026-08-16) — the
  per-site `{siteName}-social` database already exists in composition,
  provisioning, and migrations; experiments add namespaced tables beside the
  webmention inbox rather than a second database, binding, and provisioning
  path.
- **HTMLRewriter text-swap variants** (config carries the replacement copy; no
  variant page): genuinely attractive — no page duplication — but rejected for
  v1: selector coupling is fragile across theme edits, and variant markup would
  bypass every build-time gate (a11y, PII, microformats) and the preview. Built
  pages keep variants reviewable, previewable, and gate-checked. Revisitable
  for element-level tests once the WYSIWYG editor (#1221) gives variants a
  structural handle.
- **Attributing via Web Analytics**: impossible on the free plan (no custom
  dimensions) — §4.
- **A dedicated experiments Worker**: rejected — the composed per-site Worker
  already owns the request path and the D1 database; a second Worker means a
  second deploy artifact and route-claim arbitration for nothing.

## 10. Slices

Each slice is a single PR; slice 1 is buildable and useful standalone.

1. **Template edge machinery** — `experiments` types + reader in
   `scripts/anglesite-config.ts`, prebuild artifact generation, `worker.ts`
   middleware (assignment, serving, D1 counting), D1 migration,
   `checkExperiments` in the gate, template tests. Edge-visible goals
   (`pageview`/`route`) only, so the slice stays one PR. Hand-authorable end
   to end: a CLI user edits `anglesite.json` + `wrangler.toml` and has working
   edge A/B tests with no app release. App-only; no MCP schema change, no
   paired PR.
2. **Client-side goal beacon** (template) — `scroll`/`visible` goal kinds in
   the schema, the beacon script + conditional layout injection, the `/x/goal`
   endpoint in the middleware (writing the same D1 counters), the
   client-goal gate checks, and the beacon/endpoint tests. Extends slice 1's
   machinery; still app-only and hand-authorable.
3. **App config model + composition** — `DomainConfig.Experiments` +
   store write-through; `generateWranglerToml` learns experiments
   (run-worker-first emission incl. root and beacon endpoint, third-enabler
   gating, collision validation); D1 provisioning on first start for
   static-only sites.
4. **Results pipeline** — `ExperimentEventsD1Client`; `ExperimentStatsModel`
   live prefill with manual entry as fallback; zero-argument
   `AnalyzeExperimentIntent` path. Unchanged by goal kind: beacon conversions
   land in the same counters, so the app never distinguishes how a goal was
   observed.
5. **Configure/start UI** — lifecycle surface on the Experiment Results sheet:
   propose (playbook), configure (variant scaffold + editing, goal picker
   phrased as consequences — "counts when a visitor reaches your reviews", not
   "IntersectionObserver selector"), start (config write + publish), running
   status. Consequence-phrased copy throughout.
6. **Conclude: promote/keep/discard** — winner application in git, variant
   cleanup, `Config/experiment-history.json`, concluding dialogs and intent
   polish; refresh the `ExperimentStats`/`ExperimentStatsModel` doc comments
   that currently point at #1270 as missing machinery.

## 11. Out of scope

- Multivariate or multi-page experiments, >2 arms, overlapping experiments.
- Goal kinds beyond v1's four (`pageview`/`route`/`scroll`/`visible`) —
  click-level goals, custom events, revenue attribution.
- Non-Cloudflare deploy targets (manual entry remains their path).
- Auto-generated variant copy via Apple Intelligence — a natural later layer on
  the configure step, but the lifecycle must not depend on it.
- Experiment scheduling/queueing beyond one-at-a-time.

## 12. Decided (owner, 2026-08-16)

The design's three open questions, as answered:

1. **Goal types: client-side goals are in v1.** Not just edge-visible events —
   `scroll` (depth) and `visible` (element visibility) ship alongside
   `pageview`/`route`, via the first-party goal beacon (§4: static-file
   injection, unchanged CSP, same Worker endpoint and D1 counters, explicit
   collected/not-collected list). Slice plan updated: the beacon is its own
   slice 2, and the pipeline slice notes beacon conversions are
   indistinguishable from edge ones.
2. **Promotion is owner-click only — no auto-promote**, not even as an opt-in.
   The app advises in consequences; the owner makes the click that changes the
   site (§5).
3. **Tallies reuse the per-site `{siteName}-social` D1 database** —
   experiments tables land beside the webmention inbox; no dedicated database
   (§4, §9).
