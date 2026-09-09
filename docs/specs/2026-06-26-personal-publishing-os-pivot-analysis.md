# Pivoting Anglesite to a "Personal Publishing Operating System"

**Date:** 2026-06-26
**Status:** Analysis / strategy review (no implementation)
**Amended 2026-09-08:** three "decided" items below were reversed by later owner decisions — §5.4 (import: now in scope), §5.5 (Cloudflare-only deploy: now a `DeployTarget` seam with GitHub Pages), and §5.8 (Windows/Linux: now a shared-code port). See [`2026-09-08-product-direction-review-decisions.md`](2026-09-08-product-direction-review-decisions.md) D2/D3.
**Input:** The "Anglesite Vision — A Personal Publishing Operating System" brief.
**Question answered:** What would actually have to change — in product scope,
architecture, and roadmap — to pivot the shipping app to this vision?

---

## 1. TL;DR

This is **less a pivot than a re-pointing of an already-aligned foundation, plus
one genuinely new product surface (the social/federation layer) that the app does
not have any of today.**

The vision's *principles* — ownership, local-first, static-by-default, open
standards, AI-as-assistant, beautiful defaults — are already the app's stated
invariants. The git-repo-as-source-of-truth rule (#72), the `.anglesite` package
model (#242), the Astro static pipeline, the optional Apple-Intelligence brain,
and the per-site container runtime (#69) are *exactly* the substrate this vision
needs. None of that gets torn down.

What's missing falls into four buckets, in rough order of difficulty:

1. **Typed content objects** (Note/Photo/Event/Reply/…) — today there are only
   Page, Post, Image. Medium lift, mostly additive.
2. **The IndieWeb protocol layer** (Webmention send+receive, Micropub, IndieAuth,
   ActivityPub, microformats, feeds, POSSE) — the engine that makes "every website
   social." **The app has none of it today — but it does not have to be built from
   scratch:** the [`@dwk/workers`](https://github.com/davidwkeith/workers) monorepo
   (first-party — same author as Anglesite) already implements this entire layer as
   composable Cloudflare Workers. So this bucket is **integration + deployment +
   config**, not greenfield protocol engineering. This is still the heart of the
   pivot, but the risk profile changes from "build a federation stack" to "adopt and
   wire one." (Maturity caveat: §5.2.)
3. **A per-site dynamic backend** to *receive* (webmentions, ActivityPub inbox,
   form posts). The app is static-deploy-only today; federation cannot be static.
   **`@dwk/workers` is exactly this backend** — a scale-to-zero Cloudflare Worker
   (self-hostable via `@dwk/server`), so the "make-or-break design spike" this
   document originally called for is largely *answered* by an existing component.
4. **Communities** — first-class groups with membership, discussion, moderation.
   Still a distinct product surface, but **substantially de-risked: the federation
   substrate already exists in `@dwk/workers`** (`@dwk/activitypub` Groups +
   `@dwk/atproto-pds`), so communities ride the same backend as personal sites
   rather than needing a new one (§5.6).

**Dropped from scope: migration/import from other social platforms** (Facebook/
Instagram/Mastodon/WordPress/…). Too complicated for V1; cut entirely for now
(§5.4).

The honest framing: **principles ✅, foundation ✅, protocol layer ✅ (exists as
`@dwk/workers`, unreleased), integration + social-product ❌.** The pivot is
achievable *because* the architecture was built for it and the federation stack
already exists as a first-party package; the remaining work is wiring that backend
into the app's deploy/identity/content flows, the typed-object UX, and (separately)
communities — which also ride `@dwk/workers`. The deferred *decisions* in §6 still
need answering, but several are now resolved by `@dwk/workers`' design.

---

## 2. What the app is today (grounded inventory)

So the gap analysis is concrete, here is what actually ships (verified against
the source, not the docs):

- **Shape:** native macOS app (macOS 27+, Apple Silicon only), four SPM targets
  (`AnglesiteApp` UI, `AnglesiteCore` engine ~180 files, `AnglesiteBridge`
  WKWebView, `AnglesiteIntents` Siri) + `AnglesiteContainer`.
- **Site = `.anglesite` package** (`AnglesitePackage.swift`): `Info.plist` (stable
  UUID), `Source/` (an Astro git repo — the canonical, clonable unit), `Config/`
  (app-owned, never in git). Discovered via a recents registry (`SiteStore`), not
  folder scans.
- **Content model:** `Page` (`src/pages/*.astro`), `Post` (markdown content
  collection), `Image` (`public/`), `Annotation` (sticky notes). Surfaced as a
  `SiteContentGraph` + lexical `SiteKnowledgeIndex`. **That's the entire object
  vocabulary** — three types, all generic.
- **Editing:** click-to-edit overlay in WKWebView → `apply_edit` MCP tool →
  selector patch + per-edit git commit. Plus Siri NL edit and an optional chat
  panel.
- **AI:** `ClaudeAgent` (DevID, being retired per the Claude-Code-removal roadmap)
  or on-device `FoundationModelAssistant` (both targets). Optional, tool-calling,
  no external LLM APIs by policy.
- **Runtime:** `SiteRuntime` protocol with `LocalSiteRuntime` (host subprocess) and
  `LocalContainerSiteRuntime` (Apple Containerization VM). HTTP/stdio MCP transport.
- **Deploy:** `DeployCommand` → `npm build` → `pre-deploy-check.ts` security gate →
  `wrangler deploy` to **Cloudflare only**. GitHub publish flow is half-built and
  in draft.
- **Social / IndieWeb / feeds / syndication / import-from-silos / communities:**
  **none.** Confirmed absent in code. The only "social" surfaces are third-party
  *embeds* (Giscus comments, booking, donations) — adding someone else's silo to
  your page, the opposite of owning the interaction.

---

## 3. The foundation that already aligns (keep, don't rebuild)

| Vision principle | Already satisfied by | Note |
|---|---|---|
| **Ownership first** — canonical copy on the user's site | `Source/` git repo is the source of truth (#72); app's working copy is non-canonical | This is *the* hardest cultural invariant to retrofit, and it's already load-bearing. |
| **Local first** — create offline | Local package, local git, local runtime | "Publish when connectivity returns" is a queue away (§5.3). |
| **Static by default** | Astro → `dist/` static output | Exactly the vision's stance. |
| **Open by default** | Astro/markdown/HTML, no proprietary store | The content *substrate* is open; the *protocols* are missing (that's §5.2). |
| **AI as assistant, never required** | FM chat is optional; Siri+GUI are primary | Already a "locked decision" in the Claude-removal roadmap. |
| **Beautiful by default** | `ThemeCatalog`/`ThemeApplier`, Astro themes | Partial — theme system is thin; vision's "rival the best platforms" bar is higher. |
| **Provider-agnostic hosting** | `SiteRuntime` protocol; deploy is a command, not a hard dependency | But deploy is *implemented* Cloudflare-only (§5.5). |
| **Per-site dynamic backend** *(needed for social)* | Cloudflare Workers + the container runtime investment | The single biggest architectural gift: the substrate for receiving webmentions / inbox already exists in-house. |

**Implication:** the "one capability → one implementation → three front-doors"
pattern (GUI / Siri / chat) from the Claude-removal roadmap extends cleanly to
social actions ("reply", "like", "follow", "syndicate"). The pivot rides existing
rails rather than laying new ones for the *interaction* model.

---

## 4. Re-prioritization, not contradiction

The current roadmap (Phase 10: MAS shipping, containerization, Siri, Claude-Code
removal) is **orthogonal** to the vision, not opposed to it — but it is optimized
for a *different product*: "an AI-assisted business-website builder for
non-technical owners." The vision is "own your social web." Almost everything
in-flight (package model, container runtime, deterministic Swift, Apple
Intelligence) is reusable. What changes is **what gets built next and why**:

- The Claude-Code-removal work continues (it's about substrate, not scope).
- The "integrations wizard" framework already lists `indieweb` as a to-port item
  (Bucket 3 of that roadmap) — but as a single vague placeholder. The pivot
  **promotes IndieWeb from one wizard to the spine of the product**, implemented by
  composing the first-party `@dwk/workers` stack (§5.2) rather than building
  protocols in-house.
- "Communities" is not on any current roadmap and would be a new epic on the scale
  of the whole containerization effort.

### 4.1 Audience: individuals *and* small businesses (both own their social web)

The vision's examples skew personal (Facebook profiles, travel journals, digital
gardens), but **the ownership thesis applies just as much to small businesses — and
this is where the pivot *re-converges* with the app's original identity** as a
business-website builder. A small business today rents its social presence from
Facebook Pages, Instagram, Google Business Profile, Yelp, and Nextdoor — the same
platform-dependence the vision rejects for individuals. "Own your social web" for a
small business means:

- Its **profile** (hours, location, contact, services) is canonical on its own site
  as `LocalBusiness` JSON-LD + an h-card — not a Google Business Profile entry.
- Its **posts/announcements/events** publish to its own site and **POSSE** out to
  where customers are; customers can **follow the business directly** (ActivityPub),
  not via an algorithmic Page feed.
- **Reviews/testimonials** arrive and are displayed/responded-to on the business's
  own site (Webmention in; `h-review`/schema.org `Review`/`AggregateRating` out) —
  the business owns its reputation surface instead of Yelp owning it.
- **Bookings, contact, commerce** are first-party (already covered by the existing
  integration-wizard framework: booking, contact, donations, stores).

Crucially this reuses investment the app *already has*: the roadmap's `business-info`
→ `LocalBusiness` JSON-LD (Bucket 4), `reputation` review-response drafts (Bucket 5),
`testimonials` collection/moderation (Bucket 3), and the booking/contact/commerce
integrations. So small-business social ownership is **not a separate product line** —
it's the same typed-objects + `@dwk/workers` stack with a business-flavored set of
object types (§5.1) and the existing business skills layered on. Treat "individual"
and "small business / org" as two audiences of *one* product, not a fork.

---

## 5. The gaps — what must be built

### 5.1 Typed content objects (medium lift, additive)

Vision wants ~20 first-class types (Note, Article, Photo, Album, Event, Bookmark,
Like, Reply, Repost, RSVP, Review, Recipe, Trip, Reading, Listening, …), each with
a purpose-built editor. Today: 3 generic types.

The registry should also carry **business-flavored types** (per §4.1) so the small-
business audience is first-class, not bolted on: **Business Profile** (hours +
location + contact → `LocalBusiness` JSON-LD / h-card), **Announcement/Offer**,
**Event**, **Review/Testimonial** (received + first-party, → `Review`/
`AggregateRating` + `h-review`), **Listing/Product**, and **Menu/Service**. Most are
the same shape as the personal types — a typed object with a schema that projects to
mf2 + schema.org — so they cost incrementally, not as a separate track.

**What it takes:**
- A content-type registry in `AnglesiteCore` (extend `SiteContentGraph` /
  `ContentScaffold`) where each type declares its frontmatter schema, its
  microformats2 mapping (`h-entry` + `u-*`/`p-*`/`dt-*` properties), its editor
  UI, and its template. This maps almost 1:1 onto **IndieWeb post types** — adopt
  that vocabulary rather than inventing one.
- Per-type SwiftUI editors (the vision's "feel like Notes/Photos" UX). The
  existing overlay/`FileEditorModel` handle freeform editing; typed objects need
  structured forms (a photo picker, a date+location picker for Events, a
  URL-of-the-thing-you're-replying-to field for Replies).
- Each type also needs an Astro template + content-collection schema in
  `Resources/Template/`, and App-Intent entities (the `ContentEntities` pattern
  already exists for Page/Post/Image — extend it).

**Astro leverage — the spine is native, with a few ecosystem pieces (no turnkey
kit).** There is *no* drop-in npm package that ships ready-made Note/Photo/Event/
Recipe components; that purpose-built layer is ours to build. But the *plumbing*
under each typed object is largely off-the-shelf:

- **Astro Content Collections + Zod schemas are the typed-object mechanism** — and
  the template already uses them (`src/content.config.ts`, the `blog` glob loader).
  Each typed object = a collection with its own Zod schema; this is exactly the
  per-type "frontmatter schema" the registry needs, and it gives compile-time types
  and validation for free. Astro 5's **Content Layer loaders** further let a
  collection pull from non-file sources (useful later for imported/syndicated data).
- **One schema, two projections.** Define the Zod schema once per type and emit
  *both* IndieWeb **microformats2** (h-entry/h-card classes in the `.astro`
  template — pure markup/CSS-class work, no package) *and* **schema.org JSON-LD**
  via [`astro-seo-schema`](https://www.npmjs.com/package/astro-seo-schema) (v6) with
  [`schema-dts`](https://www.npmjs.com/package/schema-dts) types. mf2 powers
  Webmention/federation; JSON-LD powers search rich-results. Recipe/Event/Review map
  cleanly to schema.org types here.
- **Feeds:** the official [`@astrojs/rss`](https://www.npmjs.com/package/@astrojs/rss)
  generates RSS straight from collections — directly satisfies §5.2's static feed
  pillar and feeds `@dwk/microsub`/`@dwk/websub`.
- **Media:** Astro's native `astro:assets` `<Image>`/`<Picture>` (backed by Sharp,
  which the app already bundles) covers Photo/Album.
- **Embeds/citations:** [`astro-embed`](https://www.npmjs.com/package/astro-embed)
  (Tweet/YouTube/etc.) is useful for rendering the *referenced* thing in Bookmark/
  Like/Repost/Reply objects.
- **Reference implementation:** the [Astro Cactus theme](https://github.com/chrismwilliams/astro-theme-cactus)
  is the best-documented example of webmention *display* + mf2 layout on Astro.
  (Note: it uses webmention.io to receive — we don't need that; `@dwk/webmention`
  is our receiver per §5.2. Cactus is a display/markup reference, not a backend.)

Net: the per-type **schema, structured-data, feed, and media** plumbing is mostly
Astro-native or a small dependency; what Anglesite genuinely builds is the
**Swift-side typed editors** and the **per-type templates** (with mf2 classes).

This is the most tractable pillar: it's additive, fits existing patterns, and is a
prerequisite for everything social (a "Reply" *is* a content object with a
`u-in-reply-to`).

### 5.2 The IndieWeb protocol layer — adopt `@dwk/workers`

"Every website is social" = the site implements the IndieWeb building blocks. The
app has none of them today, but **they are not greenfield work**: the first-party
[`@dwk/workers`](https://github.com/davidwkeith/workers) monorepo already
implements the full stack as composable Cloudflare Workers (handlers compose into
one Worker via path routing; bindings in `wrangler.toml`; D1 / R2 / KV / Durable
Objects for state). Each protocol the vision needs maps to an existing package:

| Capability the vision needs | `@dwk/workers` package | Static / dynamic |
|---|---|---|
| External posting clients (phone/3rd-party → site) | `@dwk/micropub` (create/update/delete; media → R2) | Dynamic |
| Inbound mentions (comments/likes on your page) | `@dwk/webmention` (receive + send; async verify queue; inbox store) | Dynamic |
| Sign-in / auth for the above | `@dwk/indieauth` (authz, tokens, metadata, PKCE) | Dynamic |
| Federation (Fediverse interop, followers) | `@dwk/activitypub` (per-actor inbox/outbox, HTTP Signatures, S2S delivery) | Dynamic |
| "Follow" / read others | `@dwk/microsub` (subscriptions, Atom/RSS/JSON polling, normalized timeline) | Dynamic |
| Notify subscribers on publish | `@dwk/websub` (W3C hub, D1 store, HMAC distribution) | Dynamic |
| Discovery / identity rooted at your domain | `@dwk/webfinger`, `@dwk/host-meta`, `@dwk/vc` (did:web), `@dwk/webauthn` (passkeys) | Dynamic |
| Marked-up content (microformats2 h-entry/h-card) | *App/template work* — emit mf2 from Astro templates | Static (build-time) |
| Feeds (RSS / Atom / JSON Feed) | *App/template work* — generate at build (also consumed by `microsub`/`websub`) | Static (build-time) |

So the only *protocol* pieces the app team writes are the **static, build-time**
ones (mf2 markup + feed generation in `Resources/Template/`). Everything dynamic is
**integration**: provision a per-site Worker that composes the needed `@dwk/*`
handlers, wire its bindings, deploy it, and surface its received interactions on
the site (build-time pull and/or client-side fetch).

**This resolves the document's original central question — "static hosting cannot
receive, so what's the backend?"** The backend is `@dwk/workers`. Its stated design
("the data and keys live only on infrastructure the user owns — serverless edge on
Cloudflare, or a single self-hosted process") matches the vision's ownership stance
exactly. Note: **v1's deploy/runtime target is Cloudflare Workers** (§5.5, the
generous free tier is the default host); `@dwk/server` self-hosting (Docker/Node +
SQLite) exists in the package and is the basis for the **planned post-v1
self-hostable container** (run on your own server or another cloud — §5.5/§6.1),
not a v1 deliverable.

**Integration work the app actually owns for this pillar:**
- A "provision social backend" flow: create the D1/R2/KV bindings + deploy the
  composed Worker for a site, reusing the existing Cloudflare token machinery
  (`KeychainStore`, `CloudflareTokenVerifier`, `wrangler`).
- Map typed content objects (§5.1) onto Micropub create/update/delete so editing in
  the app and posting via Micropub are the *same* operation on the canonical repo.
- Render received webmentions/replies/likes (from the Worker's inbox store) onto the
  static site — snapshotting them into git so they survive backend loss (§6.2).
- App-side UI for the reader/timeline (`microsub`) and follower management
  (`activitypub`).

**Maturity caveat (real risk):** `@dwk/workers` is version `0.0.0`, unreleased, with
spec conformance (micropub.rocks / webmention.rocks / Solid) tracked but *pending*.
Anglesite's social-layer readiness is therefore **gated on that package reaching a
stable, conformant release**. It's first-party (same author), which lowers
coordination risk and makes paired releases natural — but the dependency must be
planned as a co-evolving component, not an off-the-shelf given. Pin versions; track
its conformance milestones as explicit prerequisites for the V-2/V-3 phases (§7).

POSSE (Publish Own Site, Syndicate Elsewhere) sits on top: on publish, cross-post
to Mastodon/Bluesky/etc. and record the syndication URLs back onto the canonical
post (backfeed via Webmention, handled by `@dwk/webmention`). Note the current
Claude-removal roadmap's `syndicate` is *generative copy variants* (Bucket 5) —
**that is not POSSE**; real syndication is API posting + backfeed plumbing, a
deterministic capability layered over `@dwk/workers`, not an AI one.

> **Action item — naming collision (follow-up issue needed).** This document can't
> rename the existing roadmap bucket, but `Syndicate` in the integration-wizard
> roadmap (AI copy variants) collides head-on with POSSE *syndication* (the real
> protocol feature above). **File a follow-up issue to rename the Bucket 5
> `Syndicate` entry** (e.g. to `repurpose` or `variant`) so the two stop being
> conflated. Without the rename, the next reader of the integration-wizard docs will
> assume `Syndicate` means POSSE — it does not.

### 5.3 Invisible publishing + local-first queue

Vision: "there should rarely be a visible Publish button"; edits auto-regenerate,
update feeds, send webmentions, syndicate, deploy. Today publishing is an explicit
`DeployModel` button → full build → Cloudflare.

**What it takes:**
- A **publish pipeline / queue** that debounces edits, rebuilds incrementally,
  and on reconnect performs: deploy → feed regen → webmention send → POSSE →
  subscriber notify. Offline edits queue locally (git already gives durable local
  state); the queue drains when connectivity returns.
- This is a state-machine generalization of today's `DeployCommand`, plus
  background scheduling. The `pre-deploy-check` security gate stays in the path
  (it's an invariant) — which means "invisible" publishing still can't bypass it;
  surface blocks as notifications rather than a modal.

### 5.4 Migration / import — DROPPED for V1 (decided)

The vision wants importers for Facebook, Instagram, Mastodon, Bluesky, WordPress,
Blogger, Medium, etc. **This is cut from V1 entirely — too complicated.** Each silo
export is a different, often messy and huge, format; a credible importer set is a
large, low-leverage effort that would delay the core social pivot. Today
`PackageTransfer` only does Anglesite-dir ↔ package, and that's all V1 needs.

When it returns post-V1, the shape is unchanged from the original plan: per-source
archive parsers mapping exports → typed content objects (§5.1) + media + git
history, well-bounded and parallelizable (one parser per source) in the Node
sidecar, deterministic parse with optional AI cleanup. Start with the clean,
well-specified sources (Mastodon, RSS) before the messy ones (Facebook). **None of
this is V1 work.**

### 5.5 Deploy target: Cloudflare Workers only (v1 — decided)

The vision lists Cloudflare, GitHub Pages, Netlify, generic static, and
self-hosted. **For v1 this is deliberately narrowed to Cloudflare Workers only;
the other targets are dropped for now.** This is the right call and removes work
rather than adding it:

- Deploy stays on the existing `wrangler` path in `DeployCommand` — **no
  `DeployTarget` abstraction or per-provider adapters needed for v1.** (The
  half-built GitHub publish flow, `GitHubAuthFlow`/`PublishModel`, is not a deploy
  target; GitHub stays only as the `Source/` repo host.)
- It makes the static site and the dynamic social backend share one substrate:
  both the static assets *and* the `@dwk/workers` social Worker deploy to
  Cloudflare with the same account/token. There is no "static host can't receive"
  split to design around (the original §5.2 caveat) and no reduced "publish-only"
  tier to explain — **every published site can receive**, because every site is on
  Workers.
- Multi-target deploy becomes a post-v1 concern. When it returns, it reintroduces
  exactly the tension this narrowing avoids (pure-static targets can host the site
  but not the inbox), so it should come back as an explicit, well-scoped feature —
  not be half-supported now.

**Provider independence comes via a self-hostable container, not multi-target
deploy (decided direction).** Cloudflare is the *primary* host — a generous free
tier makes it the zero-friction default, and the v1 path. But the escape hatch from
provider lock-in is that **Anglesite can also produce a container** (the site +
the `@dwk/workers` backend, via `@dwk/server`'s Node/SQLite/filesystem emulation of
the Cloudflare primitives) that the user runs on **their own server or another
cloud provider**. So "interchangeable hosting" is delivered by *one portable
artifact that runs anywhere*, rather than N per-provider deploy adapters. This is
the stronger form of the vision's promise and it reuses existing investment: the
containerization epic (#59/#62) already builds an OCI image and runs the site in a
container (`LocalContainerSiteRuntime`, #69) — the self-host artifact is that image
extended to bundle the social backend. Sequencing: Cloudflare in v1; the
self-hostable container as a post-v1 capability (not a v1 deliverable, but the
reason the Cloudflare coupling below is a *default*, not a *lock-in*).

The honest trade-off to record: **v1's working path is Cloudflare**, so day-one
users do connect a Cloudflare account (free tier). That is a sequencing reality,
not an architectural lock-in — the self-hostable container (above) is the planned
answer to the vision's "hosting providers become interchangeable" and "self-hosted"
goals (§6.1/§6.3).

### 5.6 Communities — federation handled by `@dwk/workers` (ATProto + ActivityPub)

First-class groups (neighborhood, club, family, …) with announcements, threaded
discussion, events/calendars, member directories, galleries, and **moderation**.

**The hard part — the federated, multi-writer backend — is provided by
`@dwk/workers`.** Communities are supported through its `@dwk/activitypub` (Groups
actors: inbox/outbox, membership, S2S delivery) and `@dwk/atproto-pds` (AT Protocol
PDS) packages, on the same Cloudflare substrate personal sites use. So a community
is not a new server to design; it's another configuration of the existing backend —
which **dissolves the "communities are a second product needing new infrastructure"
risk this document originally flagged.** What's left for communities is genuinely
*product* work, not protocol/infra invention:

- The **moderation, membership, and directory UX** — multi-member roles, joining/
  leaving, abuse handling — surfaced in the app.
- Mapping community content (announcements, threads, events, galleries) onto the
  typed content objects (§5.1) and the ActivityPub/ATProto group model.
- Deciding the canonical-content story for *group* content vs. the single-author
  git-repo model (§6.2 applies here too, multiplied across members).
- Per-protocol nuance: `@dwk/atproto-pds` is marked *exploratory* in the package, so
  ActivityPub Groups is the more mature path of the two to lead with.

**Recommendation (unchanged in spirit, lower risk):** treat communities as a
*separate epic gated behind the personal IndieWeb layer landing first* — don't let
it block or define the personal-publishing pivot. But it is no longer the
"build-a-whole-backend" mountain it looked like: the federation primitives ship in
`@dwk/workers`, so the epic is UX + content-modeling over an existing substrate.

### 5.7 Discovery (net-new, and in tension with "no centralization")

"Discover nearby communities / shared interests / local events / independent
creators without centralized recommendation algorithms." This needs *some*
index — you cannot discover a network of static sites without a directory or
crawl. Likely an **opt-in directory / aggregator service** (which is a
centralized-ish component, however federated or open its data). Smallest viable
version: consume existing open networks (Fediverse discovery, IndieWeb webrings,
feeds you follow) before building anything new. Flag honestly: full discovery
contradicts "no centralized service" unless reframed as "opt-in, open-data,
self-hostable directory."

### 5.8 Platform strategy — one Apple app (macOS + iOS + iPadOS); Windows/Linux separate (decided)

**Decision:**
- **This codebase is the Apple app: macOS, iOS, and iPadOS share it** — one
  Apple-native SwiftUI codebase, with a **different feature set per device** (the
  Mac is the full editor; iPhone/iPad are leaner, capture-and-publish-oriented).
- **Windows and Linux are *separate* native apps**, rebuilt for those platforms —
  not a port of this one, sharing concepts and *standards* but not code.

This dissolves the cross-platform/AI contradiction an earlier draft flagged:

- The Apple app keeps its Apple-native stack (SwiftUI, FoundationModels, App
  Intents) and the "Apple Intelligence only, no external LLM APIs" decision
  **without compromise across all three Apple platforms** — FoundationModels and App
  Intents exist on iOS/iPadOS too, so the invariant holds device-to-device.
- iOS/iPadOS use the **remote Cloudflare runtime** (`RemoteSandboxSiteRuntime`,
  #66/#71) because phones can't run local containers — already the planned design;
  it dovetails with the Cloudflare-only v1 decision (§5.5). The Mac keeps its local
  container runtime. Same app, runtime chosen per device.
- The future **Windows/Linux** apps pick whatever AI substrate fits their OS,
  independently — no single decision spans Apple and non-Apple worlds.
- **What makes the non-Apple "separate apps" coherent rather than fragmenting is the
  open substrate**: every app — Apple or not — operates on the same two shared
  truths, the site's `Source/` **git repo** (canonical content) and the
  **`@dwk/workers` backend** (the social/identity layer over Micropub, IndieAuth,
  ActivityPub, Webmention). A separate Windows app is "just another IndieWeb client"
  against those, exactly as the vision intends ("interoperate instead of replace") —
  the apps are interchangeable clients; the user's site is the durable identity.

So the *platform-family direction* is decided (one Apple app; Windows/Linux
separate). But that is a direction, not a scoped plan.

**Scope caveat — iOS/iPadOS is a substantial, currently-unscoped epic, not "free"
because it shares the codebase.** Today this app is macOS-only, and an iOS/iPadOS
target is real work that is on *no* current roadmap or issue: it needs its own
scene/navigation model (`UIWindowScene`, no `NSOpenPanel`, no AppKit multi-window),
the remote Cloudflare runtime as the *only* runtime option (correct per above, but
`RemoteSandboxSiteRuntime` #66/#71 are still open), and a separate App Store
submission with different sandbox rules. **Treat iOS/iPadOS as its own future epic
that needs a dedicated design doc + issue before it enters a phase (no earlier than
the V-3/V-4 era), so it doesn't arrive as surprise scope.** The decision here is
"when we do other Apple devices, they're this codebase, not a rewrite" — not "iOS
is already planned work." The vision's "future: Windows, Linux" likewise becomes
downstream **native** apps, none gating the macOS pivot.

---

## 6. The hard tensions the vision must resolve (decide before building)

These are the places the vision is internally under-specified. They are decisions,
not tasks, and they gate the roadmap:

1. **"No cloud account required" vs. being social — reconciled by the hosting
   model (§5.5).** You can *author* with no account (local package + git, offline),
   but *receiving* followers/webmentions and *publishing* require an always-on host.
   The reconciliation: **Cloudflare is the primary host with a generous free tier**
   (the zero-friction default — practically "free," and the v1 path), **and** the
   user can instead run the **self-hostable container on their own server or another
   cloud**, owing no account to anyone. So the truthful product statement is: "no
   account to **create**; to **publish/receive**, use the free Cloudflare default or
   host the container yourself." That keeps the ownership promise real (you are never
   *forced* onto one provider) while staying honest that being social requires *a*
   host. Say exactly this in the product — don't imply zero hosting.

2. **Static-first vs. the inbox.** *Largely resolved* — the receiving backend is
   `@dwk/workers` (§5.2), and the v1 Cloudflare-only decision (§5.5) means static
   assets and the social Worker share one host, so there's no static-vs-dynamic
   hosting split to design around. What remains is a *data-canonicality* decision,
   not a hosting one: the canonical site is now static `dist/` **+** a dynamic
   backend, so #72 ("git is the source of truth") must say what is canonical about
   received interactions (a webmention you received is someone else's content,
   cached in the Worker's inbox store — is it in your git repo? IndieWeb practice:
   yes, snapshot it back into `Source/` so it survives backend loss).

3. **"No centralized" vs. discovery.** Mostly narrowed to one thing. Communities are
   *federated*, not centralized — they ride `@dwk/workers`' ActivityPub Groups /
   ATProto (§5.6), so they're no part of this tension. The hosting half is handled in
   §6.1/§5.5 (Cloudflare default + self-hostable container = provider independence).
   The genuinely unresolved centralization question is **discovery** — finding other
   sites/communities needs *some* index; keep it opt-in and open-data, or consume
   existing open networks (Fediverse discovery, webrings) rather than building a new
   directory.

4. **Apple-only AI vs. cross-platform reach — resolved by decision (§5.8).** One
   Apple app spans **macOS + iOS + iPadOS** (shared code, per-device feature set);
   **Windows/Linux** are **separate native apps**, not ports. The
   Apple-Intelligence-only invariant therefore holds without compromise across all
   Apple devices, and the non-Apple apps converge through the shared open substrate
   (the site's git repo + the `@dwk/workers` backend) rather than shared code. No
   longer an open tension — the residual work is keeping those interface contracts
   clean and documented so the future native apps can target them.

5. **"No templates / no publish button / understands intent" vs. power-user
   git ownership.** The vision's UX (Notes-like, invisible) and the #72 invariant
   (it's a real git repo anyone can clone) are compatible but in constant tension —
   every "magic" automation must leave clean, human-legible git history and files,
   or the ownership promise is hollow. The existing per-edit-commit discipline is
   the right precedent; extend it.

6. **Scope explosion / focus.** The vision lists ~10 products to replace now and
   ~8 more later. Attempting all is fatal. The leverage point is the **owned
   IndieWeb site** (notes, photos, articles, replies, feeds, webmention, POSSE) —
   that single slice replaces blogs, Linktree, basic social posting, and digital
   gardens, and *everything else builds on it*. The **same slice serves the small-
   business audience** (§4.1) once the business-flavored types (§5.1) ride along —
   profile, announcements, reviews, events — so individuals and small businesses are
   one focus, not two. Communities, commerce, and newsletters are later layers, not
   v1.

---

## 7. Suggested phasing

Each phase is independently shippable and ordered so the social layer rests on
solid content/protocol foundations.

Scope guards baked into the phases below: **one Apple app (macOS + iOS + iPadOS)**
with Windows/Linux as separate native apps (§5.8), **Cloudflare-only deploy** (§5.5),
and the social layer is **composed from `@dwk/workers`**, not built in-house (§5.2). The
`@dwk/workers` integration phases are gated on that package reaching a stable,
conformant release.

| Phase | Theme | Contents | Prerequisites | Vision products unlocked |
|---|---|---|---|---|
| **V-0** | *Finish the substrate* | Continue Claude-removal + MAS + container runtime (already in flight). No vision-specific work; just don't stall it. | — | — |
| **V-1** | *Typed content + feeds* | Content-type registry (§5.1) for Note/Article/Photo/Album/Bookmark **+ business types** (Profile/Announcement/Event/Review, §4.1); per-type editors; **RSS/Atom/JSON feeds** + **microformats2 / LocalBusiness JSON-LD** in templates (the only protocol pieces written in-app — both static). | None — Astro-native + small deps (§8). | Blog, digital garden, link collection, photo album, portfolio **+ small-business site (profile, hours, reviews)**. |
| **V-2** | *Make it social (outbound)* | Provision the per-site **Cloudflare Worker** composing `@dwk/webmention` (send) + `@dwk/indieauth`; POSSE syndication to Mastodon/Bluesky (API posting + backfeed via `@dwk/webmention`); the publish queue / "invisible publish" (§5.3). | **`@dwk/workers` stable release** (webmention/indieauth packages) + **passing webmention.rocks** (§5.2). | "Publish once, syndicate everywhere"; replaces basic social posting. |
| **V-3** | *Make it social (inbound)* | Add `@dwk/micropub` + `@dwk/webmention` (receive) + `@dwk/websub` to the Worker; received interactions rendered on the page + snapshotted to git; typed objects wired to Micropub create/update/delete. | **`@dwk/workers` stable** + **passing micropub.rocks / webmention.rocks** (§5.2); data-canonicality decision (§6.2). | Comments/likes/replies on your own site; posting from external/IndieWeb clients. |
| **V-4** | *Federation + reader* | Add `@dwk/activitypub` (actor/inbox/outbox/followers) + `@dwk/microsub` (follow/timeline) + `@dwk/webfinger`/identity. | `@dwk/workers` activitypub/microsub conformant; V-3 backend live. | Appear natively in the Fediverse; follow others; replaces Mastodon-class following. |
| **V-5** | *Communities + discovery* | Separate epic (§5.6/§5.7) — federation backend already in `@dwk/workers` (ActivityPub Groups + ATProto); this phase is the moderation/membership/directory **UX** + content modeling. Spike first. | V-3/V-4 backend live; own design + issue. | Groups, Meetup, neighborhood/club sites. |

**iOS/iPadOS** would ride this same Apple codebase with a leaner feature set (on the
remote Cloudflare runtime), but it is a **separate, currently-unscoped epic needing
its own design doc + issue before it enters a phase** — no earlier than the V-3/V-4
era (§5.8). It is *not* free-by-virtue-of-shared-code and is not on this critical
path. **Dropped for V1 (see §5.4): migration/import from other social platforms.** Also
out of v1 scope by decision (revisit later, none on the critical path):
multi-provider deploy (§5.5), self-hosting via `@dwk/server`, and the separate
native **Windows/Linux** apps (§5.8). Commerce, newsletters, and membership layer
onto V-1/V-3 via the existing integration-wizard framework.

---

## 8. Recommended near-term decisions

Three scope decisions are now locked and remove the biggest open questions an
earlier draft raised: **one Apple app — macOS + iOS + iPadOS** (Windows/Linux as
separate native apps, §5.8), **Cloudflare-only deploy for v1** (§5.5), and **the
protocol layer is `@dwk/workers`, not in-house** (§5.2). With those settled, the first concrete moves
are:

1. **Adopt IndieWeb as the explicit content + protocol model** (not a single
   wizard). Rewrite the content-graph and template story around h-entry post types,
   and treat `@dwk/workers` as the protocol backend. This is the keystone decision;
   most of §5 follows from it.
2. **Drive `@dwk/workers` to a stable, conformant release and stand up the
   integration seam** (§5.2). The make-or-break dependency is no longer "can we
   design a per-site backend" (it exists) but "is `@dwk/workers` released and
   passing micropub.rocks / webmention.rocks." Pin it, track its conformance as a
   prerequisite for V-2/V-3, and build the app-side "provision + deploy a per-site
   Worker" flow over the existing Cloudflare token machinery.
3. **Settle the residual data-canonicality question** (§6.2): how received
   interactions snapshot from the Worker's inbox store back into `Source/` git so
   #72 still holds. This is the one genuinely new architectural decision left.
4. **Ship feeds + microformats + Webmention-send first** (V-1 → start of V-2). The
   cheapest path to a credible "owns your social web" story; the in-app pieces are
   static/deterministic and the dynamic pieces are `@dwk/*` config. (No importers —
   migration is dropped for V1, §5.4.)
5. **Quarantine Communities** behind its own design effort — but note the hard part
   (the federated backend) is already in `@dwk/workers` (§5.6), so the epic is UX +
   content modeling, not infrastructure. Still gate it behind the personal layer.

### Recommended ecosystem pieces to adopt

The typed-object + feed work (V-1) leans on Astro-native primitives plus a short,
deliberately minimal dependency list (no framework beyond Astro; each earns its
place). Adopt:

| Piece | Role | Phase |
|---|---|---|
| **Astro Content Collections + Zod** (native) | The typed-object spine — one Zod schema per content type; compile-time types + validation. Template already uses it. | V-1 |
| **`@astrojs/rss`** (official) | RSS/Atom feed generation straight from collections; also feeds `@dwk/microsub`/`@dwk/websub`. | V-1 |
| **`astro-seo-schema` + `schema-dts`** | schema.org JSON-LD per type (Recipe/Event/Review rich-results), typed. The SEO projection of each object's one schema. | V-1 |
| **microformats2 classes** (in-template, no package) | h-entry/h-card markup — the IndieWeb projection of the same schema; what Webmention/federation consume. | V-1 |
| **`astro:assets` `<Image>`/`<Picture>`** (native, Sharp — already bundled) | Photo/Album media handling. | V-1 |
| **`astro-embed`** | Render the *referenced* item in Bookmark/Like/Repost/Reply objects. | V-1/V-2 |
| **[Astro Cactus](https://github.com/chrismwilliams/astro-theme-cactus)** (reference only) | Best-documented webmention-display + mf2 layout example. Use as a pattern, **not** a backend — receiving is `@dwk/webmention`, not webmention.io. | V-2/V-3 |

Design principle to hold: **define each content type's schema once** (Zod) and
project it three ways — Astro types (editing), microformats2 (federation),
schema.org JSON-LD (search). One source of truth per object, three consumers.

**Bottom line:** the architecture team has, perhaps inadvertently, built almost the
perfect foundation for this vision — ownership, git-canonical, static-first,
optional-AI, per-site Cloudflare runtime — and the two hardest-looking pieces are
already first-party: the federation/social protocol stack (`@dwk/workers`) *and*
the community backend within it (ActivityPub Groups + ATProto). With migration cut
for V1 and the Apple-app scope (macOS/iOS/iPadOS), Cloudflare-only deploy, and
`@dwk/workers` as settled constraints, the pivot is mostly *additive and
integrative* — wire in `@dwk/workers`, build typed objects on Astro-native
primitives, ship feeds. The residual hard problems shrink to two: **data
canonicality of received interactions** (§6.2, a decision) and **the communities
UX/content model** (§5.6 — now product work over an existing backend, not new
infrastructure). Sequence around those and the rest is disciplined, incremental
delivery on rails that already exist.
