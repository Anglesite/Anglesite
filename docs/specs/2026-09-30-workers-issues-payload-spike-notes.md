# Workers Issues webhook payload — spike notes (slice 0)

**Date:** 2026-09-30
**Status:** draft
**Issue:** #2095 (slice 0 of [`../superpowers/specs/2026-09-30-worker-issues-autofix-design.md`](../superpowers/specs/2026-09-30-worker-issues-autofix-design.md))

## Question

Slice 2's relay attributes each Issue to a `@dwk/*` package (design §3) and de-duplicates it by
fingerprint (§4). It does this **only** from what a Workers Issues automation POSTs to a generic
webhook, because the relay holds no owner token. The question is whether that payload carries:

1. **Stack frames**, and whether they are source-mapped back to package paths. If there are no
   frames, the rule is "no stack, no filing".
2. **A stable grouping id**, such as a fingerprint or issue id, to de-duplicate on.
3. **Visitor data** the relay must drop (design §5), such as request URLs, headers or span
   attributes.

## What the docs already say

- The [automations page](https://developers.cloudflare.com/workers/observability/issues/automations/)
  says generic webhooks "receive the issue summary and diagnostic context" and "use the standard
  Cloudflare Notifications webhook payload".
- The [payload schema page](https://developers.cloudflare.com/notifications/reference/webhook-payload-schema/)
  documents a `{name, text, data, ts}` envelope.
- For `workers_observability_alert`, `data` holds only account/config info and an `episode` with
  timestamps and a `summary` string. No frames are documented, so the spike has to settle it.
- The secret arrives as the `cf-webhook-auth` header.

## Kit

`Workers/issues-spike/` was a throwaway Worker with three routes. It was removed from the tree
before the capture ran, and it is kept in git history at `2d43c50025`. Restore it to run the
runbook below:

```sh
git checkout 2d43c50025 -- Workers/issues-spike
```

The relay doesn't depend on the kit: payload parsing is confined to
`Workers/issues-relay/src/extract.ts` and enforces "no stack, no filing".

| Route | Purpose |
|---|---|
| `GET /boom` | Throws `SpikePackageError` from `src/vendor/dwk-spike-pkg/`, a stand-in `@dwk` package with two named frames, so Issues records an issue |
| `POST /hook` | The automation's generic-webhook destination. It checks `cf-webhook-auth` in constant time and stores the raw body plus a few delivery headers (never the auth header) in KV for 7 days |
| `GET /captures` | Requires `Authorization: Bearer <secret>`. Returns every capture with `analyzePayload()`'s verdict |

The config has `observability.issues.enabled = true` and `upload_source_maps = true`. The KV
namespace is auto-provisioned on first deploy. A dry-run bundle (wrangler 4.145.0) validates the
config.

`analyzePayload()` (`src/analyze.ts`) does the following:

- Walks the JSON and pulls out frames, whether they are structured frame objects or V8
  `at fn (file:line:col)` stack-trace text.
- Reports whether any frame is source-mapped (`.ts`) and whether any hits `dwk-spike-pkg`.
- Lists key paths that look like a grouping id, and paths that look like visitor data.
- Returns one of three verdicts:
  - `viable`: frames and a grouping id are both present.
  - `no-stack`: no frames.
  - `no-fingerprint`: frames but no grouping id.

## Runbook

This needs a Cloudflare login on the `dwk` account. The dashboard steps can't be scripted yet
(design §8 Q1).

```sh
cd Workers/issues-spike
npm ci
npx wrangler deploy                       # note the *.workers.dev URL it prints
openssl rand -hex 32 | tee /dev/stderr | npx wrangler secret put WEBHOOK_SECRET
```

1. **Dashboard.** Open Workers & Pages ▸ `anglesite-issues-spike` ▸ **Issues** ▸ **Automations** ▸
   **Add automation**. Use these settings:
   - trigger: occurrence threshold **1**
   - destination: **Generic Webhook**, pointing at `https://<worker>.workers.dev/hook`
   - webhook secret: the value printed above
   - **Enabled** on
2. Trigger the issue. Run
   `for i in 1 2 3; do curl -s https://<worker>.workers.dev/boom >/dev/null; done`.
   Then run the loop again after a few minutes to learn whether a repeat occurrence re-delivers.
3. Collect the captures with
   `curl -s -H "Authorization: Bearer <secret>" https://<worker>.workers.dev/captures | jq .`.
   Paste the output here, or into a comment on #2095.
4. **Teardown.** Once the findings below are recorded, run `npx wrangler delete`. Then delete the
   automation and destination in the dashboard, and discard the restored `Workers/issues-spike/`.
   Don't commit it again.

## Findings

*Pending the runbook above.* Record the following:

- [ ] verdict, and the payload's key paths
- [ ] frames: where they sit, their encoding, whether they are source-mapped, and what a package
      path looks like. The dry-run source map lists sources as paths relative to the bundle
      (`…/src/vendor/dwk-spike-pkg/index.ts`), so attribution should match a path **segment**
      (`/node_modules/@dwk/`), not a prefix.
- [ ] grouping id: which key it is, and whether it stays stable across the two `/boom` rounds
- [ ] visitor-data paths present
- [ ] delivery headers: whether there is a timestamp or delivery id to use for replay protection
- [ ] re-delivery behaviour: one delivery per threshold crossing, or one per occurrence

## Decision rule

| Verdict | Consequence for slice 2 |
|---|---|
| `viable` | Proceed as designed. |
| `no-fingerprint` | Derive the fingerprint in the relay: a hash of the exception class plus the top package frames. |
| `no-stack` | The relay design is reconsidered before slice 2. The likely replacement is the app pulling issues with the owner's own token and filing through the relay. |
