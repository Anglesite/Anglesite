# Worker error reports — privacy review

**Date:** 2026-10-01
**Status:** draft
**Issue:** #2095 (slice 5 of [`../superpowers/specs/2026-09-30-worker-issues-autofix-design.md`](../superpowers/specs/2026-09-30-worker-issues-autofix-design.md))

## Scope

Design §5 requires this review before Worker error reports reach owners beyond the `*.dwk.io`
rollout. It covers:

- every piece of data the feature moves and who can see it;
- the consent the owner gives;
- how to stop it;
- the App Store privacy manifest.

The conclusion is in §6.

## 1. Data inventory

| # | Data | From | To | Retention | Who can see it |
|---|---|---|---|---|---|
| 1 | Production errors: messages, stacks, request data, logs, trace attributes | Visitors' requests to the site Worker | **Cloudflare Workers Issues**, in the owner's own account | Cloudflare's Issues retention | The owner only |
| 2 | Issue payload: the generic-webhook body | Cloudflare (owner's automation) | The relay (`issues.anglesite.dwk.io`) | Not stored: processed in memory per request | Anglesite operator's relay code only |
| 3 | Published issue: exception class, `@dwk/*` and template frames (path:line:col), occurrence count, first/last seen, catalog commit, cross-site fingerprint | The relay | **Public** GitHub issue on `davidwkeith/workers` | Indefinite (public) | Anyone |
| 4 | Registration: site UUID, hostname, catalog commit, proof key | The app | The relay | UUID, secret hash and commit for 30 days after the last publish. The hostname and proof key are not stored | The relay only |
| 5 | Domain proof: `sha256("anglesite-issues-proof:<uuid>:<key>")` | The site Worker | Anyone fetching `/.well-known/anglesite-issues-proof` | While reports are on | Anyone |
| 6 | Per-site replay and rate state: Cloudflare's fingerprint, last-seen time, count, daily counters | The relay | Relay KV | 2–30 days (KV TTL) | The relay only |
| 7 | The published issue (row 3) | GitHub | The triage agent (Anthropic API) in `davidwkeith/workers` CI | Per Anthropic API terms | The agent, then the public issue thread |

## 2. What never leaves the owner's account

The relay builds row 3 from an allowlist (`Workers/issues-relay/src/report.ts`). Its tests
assert that none of the following reach the issue:

- the error message;
- request URLs, headers or bodies;
- logs and trace attributes;
- the site's hostname and Cloudflare account;
- owner-code and third-party stack frames.

Frame text is limited to identifier and path characters, so it can't carry Markdown or
@-mentions. A frame that doesn't fit counts as owner code, which blocks filing.

**Residual risk.** Frame paths and function names come from package code, so they don't
identify a visitor. One edge case remains: a package that builds function names from data at
runtime. No `@dwk/*` package does this, and the sanitizer drops anything that isn't a plain
identifier.

## 3. Personal data

- **Visitors.** Rows 3 and 5 contain nothing about visitors. Visitor data stays in row 1, in the
  owner's own Cloudflare account, where it already lives because Workers Logs is on today. Error
  reports add no new visitor-data processor.
- **Owners.**
  - Row 4: the hostname can identify a personal site. It is used only for the domain proof and
    the allowlist check, then discarded. The relay keeps a random UUID and the hash of a random
    secret, neither linked to the owner's identity.
  - Row 5: publishing the proof hash reveals that the site has error reports on. That is
    comparable to `security.txt` and identifies no one.
  - Row 3: a public issue reveals that some site runs `@dwk/<package>` at a catalog commit,
    never which site.

## 4. Consent and control

- **Turning it on.** The setting is reachable only with Settings ▸ Advanced ▸ Show developer
  tools on.
- **Consent.** Turning it on asks first ("Send Worker errors to their authors?"). The alert
  states that the report is public, what it contains, and what is never sent.
  `AppSettings.workerIssuesConsentVersion` records which description the owner agreed to.
  `WorkerIssuesConsent.currentVersion` must be bumped whenever the data, destination or audience
  changes; `tracksWorkerIssues` then stays off until the owner agrees again.
- **Stopping.**
  - Turning the toggle or developer tools off removes `[observability.issues]` and the proof on
    the next publish, then revokes the registration and deletes the local secret and proof key.
  - If the app can't reach the relay, the registration lapses within 30 days on its own.
- **Erasure.** Rows 4 and 6 expire on their own. Row 3 issues are public and maintainers can
  close them, but they aren't deleted. That is acceptable only because they carry no personal
  data. Any change that adds personal data to row 3 needs a new review.

## 5. App Store privacy manifest

Apple counts data as collected when it leaves the device and is kept by the developer longer
than it takes to service the request.

- **Row 4** (site UUID and catalog commit, kept 30 days) qualifies.
- **Row 3** is diagnostic data about the owner's site that Anglesite's relay publishes. It comes
  from the owner's Cloudflare account, not from the app, but the app enables it.

**Decision (proposed; owner sign-off pending):** declare this conservatively. Over-declaring is
the safe direction, so `Resources/PrivacyInfo.xcprivacy` now lists:

- `NSPrivacyCollectedDataTypeOtherDiagnosticData`
- not linked to the user (`NSPrivacyCollectedDataTypeLinked = false`)
- not used for tracking (`NSPrivacyCollectedDataTypeTracking = false`)
- purpose `NSPrivacyCollectedDataTypePurposeAppFunctionality`. Apple's App Functionality purpose
  includes minimizing crashes and improving performance.

App Store Connect's privacy answers must match: Diagnostics ▸ Other Diagnostic Data, not linked,
not tracking, App Functionality. `docs/release.md` records this.

## 6. Conclusion and rollout gate

The data flows are acceptable for a wider rollout under the consent above.

**Widening beyond `*.dwk.io` is still gated.** The only blocker is design §8 Q1: Cloudflare
documents no API for creating Issues automations, so every owner would have to follow a guided
dashboard step, which conflicts with decision D1. When that API exists, three things are needed:

1. Automation provisioning in `WorkerIssuesReconciler`.
2. Setting `ALLOWED_HOST_SUFFIXES` to `*` in `Workers/issues-relay/wrangler.jsonc`.
3. This review moving to `current`.

The domain proof (slice 5) already replaces the pre-shared token, so owners need no access code.
