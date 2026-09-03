# Hosted Community Provisioning + Moderation — Design

**Date:** 2026-08-10
**Status:** Decided (DWK, 2026-08-10)
**Part of:** #907 (V-5.1b), #370 (V-5.3), #339 (V-5), #334 (pivot epic)
**Builds on:** `docs/superpowers/specs/2026-07-22-v5-communities-design.md` (the
V-5 Communities spike — D1–D5, §4), PR #1258 (the buildable slice of #907
already merged), workers#473 (owner-admin Accept/Remove endpoints, shipped in
`dwk-server-v1.0.0-beta.3`)

---

## 1. Where this picks up

PR #1258 (merged 2026-08-04) landed a real slice of #907: `CommunityMember`
snapshot sync, the Astro community timeline/members/about pages (shipping
inert on every site), and `Group` actor-type/moderators fields threaded
through `WorkerComposition.generateWranglerToml`. Its commit message flagged
three deliberately deferred follow-ups, which this design covers together
since they form one coherent arc — you can't moderate a community that can't
be created, and you can't create one that can't deploy:

1. A "Community" site-creation entry point.
2. Wiring the already-modeled `SiteSettings.moderators`/actor-type fields
   through `SocialWorkerProvisionCommand` into an actual deploy.
3. A moderator-list settings UI plus remove-post/ban-member actions — the
   part of #370 (V-5.3 Moderation tooling) that's now reachable, since
   workers#473 shipped the owner-admin `Accept`/`Remove` endpoints this
   needs.

Each phase lands as its own PR, in the order above (D1). #370 itself will
still show more than this closes — see §6.

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| D1 | Phasing | Three stacked PRs: creation flow → deploy wiring → moderator UI. Each independently mergeable/testable. |
| D2 | Creation entry point | A **separate `File ▸ New Community…` flow** (`NewCommunityWizardModel`/`NewCommunityWizard`), not a card in the existing single-question theme chooser (#1071). A hosted community is a different site kind (own Worker, own Group actor, moderators) — not a cosmetic theme pick. |
| D3 | Community wizard scope | **Name only.** No moderator field: per workers#473/PR#476, the owner is implicitly the top moderator of their own actor via the existing bearer `publishToken` — no `config.moderators` membership needed. `SiteSettings.moderators` is for *delegating* to additional actors beyond the owner, which belongs in the Phase 3 Moderators UI (§5), not the creation wizard. No theme step either — one consistent look for v1. |
| D4 | Approval-queue (pending joins) | **Deferred.** Listing pending followers is only reachable via the OAuth-gated Mastodon-API `follow_requests` surface (§3.3) — the app has no OAuth client against a site's own Mastodon-API today. File an upstream follow-up (§5) instead of building a new OAuth flow now. Remove/ban ship in this design; approve does not. **Update (2026-08-12):** the upstream follow-up shipped (`davidwkeith/workers` PR #488, closing workers#487) and approve now ships too — see `docs/superpowers/plans/2026-08-12-community-approval-queue.md`. |
| D5 | Report queue | **Inert placeholder section** in the Moderation UI. No `Flag`-activity handling exists anywhere upstream (confirmed via repo-wide + upstream search) — this needs a new upstream primitive from scratch, out of scope here. The UI ships the section now so the layout doesn't reshape when report-handling eventually lands. **Update (2026-09-02):** the upstream primitive shipped (`davidwkeith/workers` PR #500, closing workers#489 — bearer-gated `GET <actor>/reports` plus `Ignore(Flag)` resolve on `/outbox`) and report review now ships too, tracked as its own issue (#1438) since #370 had already auto-closed on the D4 PR's merge. |

## 3. Phase 1 — New Community creation flow

- **Entry point:** `File ▸ New Community…`, parallel to the existing
  `File ▸ New Site…` (`NewSiteWizard`, reduced to one theme-choice question
  by #1071/PR #1183). New `NewCommunityWizardModel` (mirrors
  `NewSiteWizardModel`'s `chooser`/`building` states) + `NewCommunityWizard`
  SwiftUI view.
- **Mechanics:** reuses `SiteScaffolder.scaffold(draft:)` directly — it's
  already generic over `NewSiteDraft` + injected
  `CommandRunner`/`GitInit`/`GitCommit`/`Register`
  (`Sources/AnglesiteCore/SiteScaffolder.swift:82-231`). No `scaffold.sh`
  changes needed: it does an unconditional `rsync` of the whole template
  tree, and the community pages
  (`Resources/Template/src/pages/community/{timeline,members}.astro`,
  `about.md`) already ship on every site, rendering inert until
  `SiteSettings.communityActorURL` is set.
- **New `SiteType.community` case** (`NewSiteDraft.swift`) so `.site-config`'s
  `SITE_TYPE` records the kind correctly, distinct from the existing
  `SiteType.organization` → theme id `"community"` mapping in
  `ThemeCatalog.defaultThemeID(for:)` — that's an unrelated cosmetic
  color-theme choice and stays as-is; the two "community" names refer to
  different concepts and don't collide in code, only in vocabulary. UI copy
  should avoid the word "theme" when talking about hosted communities to
  keep that distinction clear to users.
- **Post-scaffold:** `SiteSettings.moderators` stays unset (D3) — the owner
  needs no entry there for their own admin rights. `communityActorURL` also
  stays `nil` here — Phase 2 sets it once the Worker is actually deployed and
  the site's own actor IRI is known.
- **Not building for v1:** a distinct "rules" page. The existing `about.md`
  (already shipped, inert) covers that; no new template content needed.

## 4. Phase 2 — Deploy wiring

- **Gap being closed:** `SocialWorkerProvisionCommand.persistConfig`
  currently calls `generateWranglerToml` without `activityPubActorType` or
  `moderators` (confirmed: zero references to either in that 862-line file)
  — so the fields Phase 1 (and PR #1258 before it) writes into
  `SiteSettings` never reach a real deploy.
- **Change:** `persistConfig` passes `activityPubActorType: "Group"` and
  `moderators: settings.moderators` when `SiteType == .community`; `nil`
  otherwise. `generateWranglerToml` already branches correctly on this
  (`WorkerComposition.swift:512-528`, shipped in PR #1258) — this phase only
  wires the call site.
- **Activation step:** after a successful deploy, write the resulting site
  actor IRI back into `SiteSettings.communityActorURL`, derived the same way
  the activitypub Worker derives any site's own actor IRI from its domain.
  This is the single flag that flips `CommunityMembersSync` and the Phase 3
  Moderation section from inert to live — mirrors the existing "inert until
  configured" convention used throughout this feature.
- **Backward compatibility:** every existing non-community site has
  `moderators == nil` and `SiteType != .community`, so
  `generateWranglerToml` takes the same `activityPubActorType == nil` branch
  it already does today. No behavior change for existing sites.
- **Out of scope:** `WorkerCatalog.swift` — no catalog schema change needed;
  the `Group`-actor catalog fields already shipped and released
  (`dwk-server-v1.0.0-beta.3`). This phase is pure app-side wiring of fields
  that already exist.

## 5. Phase 3 — Moderator UI

- **`CommunityMembershipClient` addition:** one new method mirroring
  `follow`/`unfollow`'s shape (`Sources/AnglesiteCore/CommunityMembershipClient.swift`) —
  `remove(target:)` (POSTs `Remove`, used for both ban-member and
  un-announce-post — workers#473 documents this as one primitive with two
  moderation effects). Same bearer-`publishToken`-to-`/outbox` pattern, same
  `CommunityMembershipError` handling — no new auth surface. `acceptFollow`
  is deliberately not added here: D4 defers the entire approval queue, and
  an unused Accept method would be speculative against nothing that calls
  it. It belongs in whatever phase eventually builds the approval queue
  after §6's upstream follow-up lands. That phase landed 2026-08-12
  (`docs/superpowers/plans/2026-08-12-community-approval-queue.md`) —
  `acceptFollow(target:)` was added to `CommunityMembershipClient` and wired
  into `ModerationModel`/`ModerationView`'s new "Requests" section.
- **Gating:** new `case moderation` in `MainPaneMode`
  (`SiteWindowModel.swift`), `presentModeration()` mirroring
  `presentCommunities()` (lines 429-437), a `Button("Moderation…")` in
  `WebsiteCommands.swift` disabled unless `model?.canOpenModeration == true`
  — computed as `site.settings.communityActorURL != nil`. Unlike the
  always-available Communities button, this is gated: it only makes sense
  for a deployed hosted community (set by Phase 2).
- **`ModerationView`** — four sections:
  1. **Moderators** — list of actor IRIs from `SiteSettings.moderators`,
     add/remove. Owner-only config, no approval flow needed.
  2. **Members** — reuses the existing `CommunityMember` snapshot data
     (`CommunityMembersSync`). Each row gets a "Ban" action → confirm dialog
     phrased about consequences ("This member's posts will stop appearing.
     Existing posts stay unless you also remove them.") → `remove(target:)`.
  3. **Posts** — reuses `AnnouncedPost` snapshot data. Each row gets a
     "Remove" action → confirm dialog → `remove(target:)` + delete the
     snapshot file + commit (same C.3-style flow #908 already established
     for deletions).
  4. **Reports** — inert placeholder, "No report handling yet" empty state,
     no data source (D5).
- **Explicitly not in this phase:** approval-queue UI (D4, shipped 2026-08-12
  in a later phase — see
  `docs/superpowers/plans/2026-08-12-community-approval-queue.md`).

## 6. Upstream follow-up to file

A new `davidwkeith/workers` issue: extend the existing bearer-`publishToken`
owner surface (the same one `/outbox` POSTs already use for `Follow`,
`Undo(Follow)`, and — per workers#473 — `Accept`/`Remove`) with a way to
**list** pending followers, instead of requiring the OAuth-gated Mastodon-API
`follow_requests` surface. This mirrors how the original #370/#907
investigation found and closed the Accept/Remove gap (workers#473) — same
shape of ask, filed the same way. Unblocks a future approval-queue phase
without the app building a whole new OAuth client. Filed alongside this spec,
referenced from the #907 issue the way workers#473 was.

## 7. Testing strategy

- **Swift Testing**, stubbed `CommunityMembershipClient.Transport` for the
  new `acceptFollow`/`remove` methods (same pattern as the existing
  `follow`/`unfollow` tests).
- **`SocialWorkerProvisionCommand`** tests against a stubbed catalog/Worker
  seam verifying `activityPubActorType`/`moderators` reach
  `generateWranglerToml` only when `SiteType == .community`, and that
  existing non-community sites are byte-for-byte unaffected.
- **Container-gated e2e** (`ANGLESITE_CONTAINER_E2E=1`) for one full
  round-trip: create community → deploy → ban a member → member drops from
  the next `CommunityMembersSync`.
- **Error handling:** ban/remove failures surface via the existing
  `CommunityMembershipError` → debug-pane logging convention. No new
  error-presentation pattern needed.

## 8. What #370 still won't close after this

This design closes remove-post and ban-member — the two moderation actions
that were actually reachable once workers#473 shipped. #370's original scope
also included report review and the approval queue; the approval queue
shipped 2026-08-12 (`docs/superpowers/plans/2026-08-12-community-approval-queue.md`),
once the follow-up filed in §6 landed upstream. Only report review (D5)
remains blocked — report/Flag handling doesn't exist upstream at all. #370
should stay open, scoped down to that one remaining piece, rather than being
closed by this work.

**Update (2026-09-02):** #370 auto-closed anyway on the D4 PR's merge
(GitHub's linked-issue-on-merge behavior, not an explicit closing keyword),
so report review got its own tracking issue, #1438. It shipped once
`davidwkeith/workers` PR #500 (closing workers#489) landed the `Flag`
storage, `GET <actor>/reports` listing, and `Ignore(Flag)` resolve — see D5's
update above.
