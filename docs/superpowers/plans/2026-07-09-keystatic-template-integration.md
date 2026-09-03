# Keystatic template integration (#462) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Keystatic into `Resources/Template` and ship `inbox` and `membership` — the last
two of #462's ~21 planned wizard integrations — as owner-curated, git-backed content collections.

**Architecture:** Keystatic (`@keystatic/core` + `@keystatic/astro`, local git-file storage) ships
in every scaffolded site's `package.json` from day one, dormant until an integration is toggled on.
`inbox` only needs a Keystatic collection (admin-only, no public page). `membership` needs both a
Keystatic collection and a public Astro content collection + page, so its Astro collection is
declared unconditionally in the base template (like `blog`/`events`/`reviews` already are) via a
new `ContentTypeRegistry` entry, not injected at wizard-toggle time.

**Tech Stack:** Swift 6.4 (`AnglesiteCore`), Astro 6 + TypeScript (`Resources/Template`), Keystatic
(`@keystatic/core`, `@keystatic/astro`), Swift Testing.

## Global Constraints

- Keystatic storage is `local` (writes directly to files in the repo) — no cloud account, no
  GitHub App. This is non-negotiable per "git is the source of truth everywhere."
- No new `Operation` case in `IntegrationDescriptor.swift` — every change must be expressible with
  the existing `copyFile` / `writeConfig` / `addCSPDomains` / `injectAtAnchor` / `appendLine` set.
- `membership` is a **public member directory**, not access-gated content — no auth backend.
- Runtime form-submission capture for `inbox` is explicitly out of scope (tracked as a follow-up
  issue, filed as part of Task 4).
- Every new `TemplateRef` path referenced by a descriptor must actually exist under
  `Resources/Template` (enforced by `IntegrationTemplateAssetsTests`).
- `pre-deploy-check.ts`'s existing `BLOCKED_ROUTES` check (`/keystatic`, `/api/keystatic`) is not
  modified — it's a pre-existing backstop, not something this work relies on as primary exclusion.

---

## File Structure

| File | Change |
|---|---|
| `Resources/Template/package.json` | add 5 deps |
| `Resources/Template/astro.config.ts` | add `keystatic()` + `react()` integrations |
| `Resources/Template/keystatic.config.ts` | **new** — base config, empty anchors |
| `Sources/AnglesiteCore/ContentTypeRegistry.swift` | add `member` descriptor |
| `Resources/Template/src/content.config.ts` | add `members` collection + export entry |
| `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift` | no code change — existing tests must pass against the new registry entry |
| `Sources/AnglesiteCore/IntegrationDescriptor.swift` | add `.inbox`, `.membership` to `IntegrationID` |
| `Sources/AnglesiteCore/IntegrationCatalog.swift` | add `inbox`, `membership` descriptors + register in `.all` |
| `Resources/Template/integrations/docs/inbox-setup.md` | **new** |
| `Resources/Template/integrations/pages/members.astro` | **new** |
| `Resources/Template/integrations/components/MemberCard.astro` | **new** |
| `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift` | add `hasAllIntegrations` entries + per-integration tests |
| `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift` | add new staged-asset paths |
| new GitHub issue | runtime submission-capture follow-up, filed in Task 4 |

---

### Task 1: Keystatic foundation — dependencies, Astro wiring, base config

**Files:**
- Modify: `Resources/Template/package.json`
- Modify: `Resources/Template/astro.config.ts`
- Create: `Resources/Template/keystatic.config.ts`

**Interfaces:**
- Produces: `Resources/Template/keystatic.config.ts` with anchor comments
  `// anglesite:keystatic-collections` (inside `collections: {}`) and
  `// anglesite:keystatic-singletons` (inside `singletons: {}`) — Task 4 and Task 5 inject into the
  collections anchor via `injectAtAnchor`.

- [ ] **Step 1: Confirm real package versions**

Run (network access required):
```bash
npm view @keystatic/core version
npm view @keystatic/astro version
npm view @astrojs/react version
```
Use the returned versions as `^<version>` ranges below. If `npm view` isn't reachable in this
environment, use these last-known-good ranges and flag them for a follow-up bump PR:
`@keystatic/core@^0.5.34`, `@keystatic/astro@^5.0.4`, `@astrojs/react@^4.2.0`, matching the
project's `react`/`react-dom` peer requirement (`^18.3.0` for `@astrojs/react@^4`).

- [ ] **Step 2: Add dependencies to `package.json`**

Edit `Resources/Template/package.json`'s `dependencies` object (insert alphabetically, matching the
existing style):

```json
  "dependencies": {
    "@astrojs/react": "^4.2.0",
    "@astrojs/rss": "^4.0.0",
    "@keystatic/astro": "^5.0.4",
    "@keystatic/core": "^0.5.34",
    "astro": "^6.4.8",
    "astro-embed": "^0.13.0",
    "astro-seo-schema": "^6.0.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
```

- [ ] **Step 3: Wire the integrations into `astro.config.ts`**

`Resources/Template/astro.config.ts` currently reads:

```ts
import { defineConfig } from "astro/config";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

export default defineConfig({ site, integrations: [anglesiteHarness()] });
```

Replace with:

```ts
import { defineConfig } from "astro/config";
import keystatic from "@keystatic/astro";
import react from "@astrojs/react";
import { readConfig } from "./scripts/config.ts";
import anglesiteHarness from "./scripts/anglesite-harness.ts";

// The deploy step writes the real domain into `.site-config` (SITE_URL=…) before build.
// Absent that, feeds carry a placeholder host — fine for a not-yet-deployed scaffold.
const site = readConfig("SITE_URL") ?? "https://example.com";

// Keystatic (`react`, `keystatic`) mounts the /keystatic admin UI in dev only — it does not
// register a route during `astro build`. `pre-deploy-check.ts`'s BLOCKED_ROUTES check is a
// defense-in-depth backstop, not the primary reason /keystatic never reaches production.
export default defineConfig({ site, integrations: [anglesiteHarness(), react(), keystatic()] });
```

- [ ] **Step 4: Create `Resources/Template/keystatic.config.ts`**

```ts
import { collection, config, fields } from "@keystatic/core";

// storage: "local" writes straight to files in the repo — no cloud account, no GitHub App.
// Git stays the source of truth. Toggled-on integrations (see IntegrationCatalog.swift) inject
// their collection() blocks at the anglesite:keystatic-collections anchor below.
export default config({
  storage: { kind: "local" },
  collections: {
    // anglesite:keystatic-collections
  },
  singletons: {
    // anglesite:keystatic-singletons
  },
});
```

- [ ] **Step 5: Verify the template still type-checks and builds**

```bash
cd Resources/Template
npm install
npx astro check
npm run build
```
Expected: both commands exit 0. `npm run build` also runs `npx tsx scripts/check-microformats.ts`
— unaffected by this task, should stay green.

- [ ] **Step 6: Manually verify the dev-only admin route**

```bash
cd Resources/Template
npx astro dev &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4321/keystatic
kill %1
```
Expected: `200` (empty collections/singletons — the admin shell still loads). This confirms
Keystatic's Astro integration is live in dev, matching the foundation's "dormant but present"
design.

- [ ] **Step 7: Commit**

```bash
cd /path/to/Anglesite-app  # repo root, not Resources/Template
git add Resources/Template/package.json Resources/Template/astro.config.ts Resources/Template/keystatic.config.ts Resources/Template/package-lock.json
git commit -m "feat(template): add Keystatic foundation (dormant, local storage)

Part of #462."
```

---

### Task 2: `member` content type + `members` Astro collection

**Files:**
- Modify: `Sources/AnglesiteCore/ContentTypeRegistry.swift`
- Modify: `Resources/Template/src/content.config.ts`
- Test: `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift` (existing suite, no code changes — this task's own verification)

**Interfaces:**
- Consumes: `ContentTypeField`, `ContentTypeDescriptor`, `ContentTypeProjections`, `ContentStorage`
  (all in `Sources/AnglesiteCore/ContentTypeRegistry.swift`, signatures already in the codebase).
- Produces: `ContentTypeRegistry.member` (new static let), included in `ContentTypeRegistry.builtIns`.
  Task 5 relies on the Astro collection name `members` existing in `content.config.ts` to write
  `src/pages/members.astro`'s `getCollection("members")` call.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift` (this file already parametrizes
over `ContentTypeRegistry.builtIns`, so no new test function is needed — but confirm the registry
change is visible first):

```swift
    @Test("member content type is registered")
    func memberIsRegistered() {
        #expect(ContentTypeRegistry.builtIns.contains { $0.id == "member" })
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift build --build-tests 2>&1 | tail -20
swift test --filter ContentConfigDriftTests 2>&1 | tail -30
```
Expected: FAIL (or build error) — `member` isn't registered yet. (Per this repo's known
environment issue #541, local `swift test` may crash at `dlopen` on Foundation Models symbol
skew — if so, use `swift build --build-tests` to confirm compile-clean and rely on CI for the
actual run, per existing project convention.)

- [ ] **Step 3: Add the `member` descriptor**

In `Sources/AnglesiteCore/ContentTypeRegistry.swift`, add a new category after `businessTypes`
(around line 425, following the `announcement`/`event`/`review` pattern):

```swift
    static let identityAndDirectoryTypes: [ContentTypeDescriptor] = [member]

    static let member = ContentTypeDescriptor(
        id: "member",
        displayName: "Member",
        storage: .collection("members"),
        fields: [
            ContentTypeField("name", .string, required: true),
            ContentTypeField("role", .string),
            ContentTypeField("joinedDate", .date, required: true),
            ContentTypeField("photo", .image),
            ContentTypeField("links", .stringArray),
            ContentTypeField("bio", .markdown),
        ],
        projections: ContentTypeProjections(
            microformat: "h-card",
            microformatProperties: [
                "name": "p-name",
                "role": "p-job-title",
                "photo": "u-photo",
                "links": "u-url",
                "bio": "p-note",
            ],
            schemaType: "Person"
        )
    )
```

Update the `builtIns` aggregate:

```swift
    public static let builtIns: [ContentTypeDescriptor] = personalTypes + identityTypes + businessTypes + identityAndDirectoryTypes
```

- [ ] **Step 4: Add the matching block to `content.config.ts`**

`ContentConfigDriftTests.canonicalBlock` requires this exact text (field order matches the
descriptor's `fields` array, `.markdown`-kind fields excluded from the schema). In
`Resources/Template/src/content.config.ts`, add after the `reviews` block (before the final
`export const collections` line):

```ts
const members = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/members" }),
  schema: z.object({
    name: z.string(),
    role: z.string().optional(),
    joinedDate: z.coerce.date(),
    photo: z.string().optional(),
    links: z.array(z.string()).optional(),
  }).strict(),
});
```

Update the export line:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews, members };
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -20
swift test --filter ContentConfigDriftTests 2>&1 | tail -30
```
Expected: PASS — `memberIsRegistered`, `noOrphanCollections`, and `configMatchesRegistry` all
green (the last two are pre-existing tests validating the block/export you just added).

- [ ] **Step 6: Verify the template still type-checks**

```bash
cd Resources/Template && npx astro check
```
Expected: exit 0 — confirms the new `members` collection's Zod schema is syntactically valid.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/ContentTypeRegistry.swift Resources/Template/src/content.config.ts Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift
git commit -m "feat(core): register member content type (h-card, Person)

Part of #462. Backs the membership integration's public directory."
```

---

### Task 3: Register `inbox`/`membership` as empty wizard integrations

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationDescriptor.swift`
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`

**Interfaces:**
- Produces: `IntegrationID.inbox`, `IntegrationID.membership` cases; `IntegrationCatalog.inbox`,
  `IntegrationCatalog.membership` (empty `operations: []` — Tasks 4/5 fill them in).

- [ ] **Step 1: Write the failing test**

In `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`, update `hasAllIntegrations`:

```swift
    @Test func hasAllIntegrations() {
        #expect(Set(IntegrationCatalog.all.map(\.id)) == Set([
            .booking, .contact, .donations, .giscus, .newsletter, .consent, .pwa, .redirects,
            .tracking, .share, .podcast,
            .indieweb, .menu,
            .buyButton, .lemonSqueezy, .paddle, .snipcart, .shopifyBuyButton,
            .inbox, .membership,
        ]))
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift build --build-tests 2>&1 | tail -30
```
Expected: compile error — `.inbox`/`.membership` don't exist on `IntegrationID` yet.

- [ ] **Step 3: Add the enum cases**

In `Sources/AnglesiteCore/IntegrationDescriptor.swift`:

```swift
public enum IntegrationID: String, Sendable, CaseIterable {
    case booking, contact, donations, giscus, newsletter, consent, pwa, redirects
    case tracking, share, podcast
    case indieweb, menu
    case buyButton, lemonSqueezy, paddle, snipcart, shopifyBuyButton
    case inbox, membership
}
```

- [ ] **Step 4: Add empty descriptors to `IntegrationCatalog.swift`**

Append after `shopifyBuyButton` (around line 623, before the closing of the type):

```swift
    // MARK: inbox
    static let inbox = IntegrationDescriptor(
        id: .inbox,
        displayName: "Inbox",
        summary: "Review and curate visitor messages through a built-in admin UI (Keystatic).",
        providers: [],
        fields: [],
        operations: [])

    // MARK: membership
    static let membership = IntegrationDescriptor(
        id: .membership,
        displayName: "Member Directory",
        summary: "A public list of members you curate through a built-in admin UI (Keystatic).",
        providers: [],
        fields: [],
        operations: [])
```

Register both in `IntegrationCatalog.all`:

```swift
    public static let all: [IntegrationDescriptor] = [
        booking, contact, donations, giscus, newsletter, consent, pwa, redirects,
        tracking, share, podcast,
        indieweb, menu,
        buyButton, lemonSqueezy, paddle, snipcart, shopifyBuyButton,
        inbox, membership,
    ]
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -30
swift test --filter IntegrationCatalogTests 2>&1 | tail -40
```
Expected: PASS — `hasAllIntegrations` and `eachDescriptorIsStructurallyValid` (both new
descriptors vacuously valid with no fields/operations) are green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationDescriptor.swift Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
git commit -m "feat(core): register inbox and membership integration IDs (no-op)

Part of #462. Operations land in follow-up commits."
```

---

### Task 4: `inbox` integration operations

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift`
- Create: `Resources/Template/integrations/docs/inbox-setup.md`
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`

**Interfaces:**
- Consumes: `// anglesite:keystatic-collections` anchor in `keystatic.config.ts` (Task 1).
- Produces: nothing consumed by later tasks — `inbox` and `membership` are independent.

- [ ] **Step 1: File the runtime-capture follow-up issue**

```bash
gh issue create \
  --title "Runtime inbox capture: Worker submission endpoint + git commit-back pipeline" \
  --body "Follow-up from #462. \`inbox\` (this issue's parent) ships as an owner-curated Keystatic collection only — no live visitor-facing form yet.

Full runtime capture needs:
- A Worker endpoint (\`Resources/Template/worker/worker.ts\`) that receives the POST and stages the submission — currently that file is a placeholder built to compose \`@dwk/*\` packages (\`@dwk/indieauth\`, \`@dwk/webmention\`, …) that don't exist yet (issue #353 only shipped D1/KV/R2 provisioning, not the endpoint composition layer).
- A staging store (KV or D1) — the Worker can't safely hold long-lived git-write credentials.
- App-side logic to pull staged submissions and commit them into the site's local git working copy the next time it opens, reusing the existing hydrate-from-repo/push-back-to-repo flow (#66/#69).
- Spam/abuse handling for what would be a public, unauthenticated write endpoint.

Blocked on \`@dwk/workers\` (or an equivalent bespoke endpoint) existing. See \`docs/superpowers/specs/2026-07-09-keystatic-template-integration-design.md\` for the design context." \
  --label enhancement
```
Note the returned issue number — it's referenced in Step 3 below.

- [ ] **Step 2: Write the failing tests**

In `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`, add:

```swift
    @Test func inboxHasNoProvidersAndInjectsKeystaticCollection() {
        let inbox = IntegrationCatalog.descriptor(for: .inbox)
        #expect(inbox.providers.isEmpty)
        let hasKeystaticInject = inbox.operations.contains {
            if case .injectAtAnchor(let file, let anchor, let snippet, _, let style) = $0 {
                return file.raw == "keystatic.config.ts"
                    && anchor == "// anglesite:keystatic-collections"
                    && style == .line
                    && snippet.raw.contains("path: \"src/content/inbox/*\"")
            }
            return false
        }
        #expect(hasKeystaticInject)
    }

    @Test func inboxCopiesSetupDocs() {
        let inbox = IntegrationCatalog.descriptor(for: .inbox)
        let copiesDocs = inbox.operations.contains {
            if case .copyFile(let from, let to, let when) = $0 {
                return from.path == "integrations/docs/inbox-setup.md" && to.raw == "docs/inbox-setup.md" && when == .always
            }
            return false
        }
        #expect(copiesDocs)
    }
```

In `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`, add
`"integrations/docs/inbox-setup.md"` to the `onDemandAssetsAreStagedNotInSrc` test's first loop
array (the "staged" list) and `"docs/inbox-setup.md"` to its second loop array (the "must be
absent from base scaffold" list) — same file, two array literals, matching the existing
`docs/newsletter-setup.md` / `docs/pwa-setup.md` entries already there.

- [ ] **Step 3: Run tests to verify they fail**

```bash
swift build --build-tests 2>&1 | tail -30
```
Expected: `inboxHasNoProvidersAndInjectsKeystaticCollection` and `inboxCopiesSetupDocs` fail
(empty `operations: []`); `IntegrationTemplateAssetsTests` fails (file doesn't exist yet).

- [ ] **Step 4: Write `Resources/Template/integrations/docs/inbox-setup.md`**

Replace `<ISSUE_NUMBER>` with the number from Step 1:

```markdown
# Inbox

The Inbox integration adds a **Keystatic-managed collection** for messages you want to keep track
of on your own site instead of (or alongside) email.

## Adding a message

1. Open your site in Anglesite and start the dev server (or run `npx astro dev` inside `Source/`).
2. Visit `/keystatic` in the preview.
3. Under **Inbox**, click **Create**, and fill in the subject, sender, received date, and message.
4. Save — the entry is written to `src/content/inbox/` as a Markdown file in your site's git repo.

Use it for anything you'd otherwise handle by copying an email into a note: a message forwarded
from your contact form provider, a question someone asked in person, a reminder to follow up.

## What this doesn't do yet

There's no visitor-facing form that writes directly into this Inbox — visitor messages today go
through the [Contact Form integration](../pages/contact.astro) (Formspree or a mailto: link).
Wiring a live submission pipeline into this Inbox is tracked in
[#<ISSUE_NUMBER>](https://github.com/Anglesite/Anglesite-app/issues/<ISSUE_NUMBER>).
```

- [ ] **Step 5: Add the `inbox` operations**

In `Sources/AnglesiteCore/IntegrationCatalog.swift`, replace the `inbox` descriptor's
`operations: []` (from Task 3):

```swift
    // MARK: inbox
    static let inbox = IntegrationDescriptor(
        id: .inbox,
        displayName: "Inbox",
        summary: "Review and curate visitor messages through a built-in admin UI (Keystatic).",
        providers: [],
        fields: [],
        operations: [
            .injectAtAnchor(file: "keystatic.config.ts", anchor: "// anglesite:keystatic-collections",
                            snippet: "inbox: collection({\n  label: \"Inbox\",\n  path: \"src/content/inbox/*\",\n  format: { contentField: \"message\" },\n  schema: {\n    subject: fields.text({ label: \"Subject\" }),\n    from: fields.text({ label: \"From\" }),\n    receivedDate: fields.date({ label: \"Received\" }),\n    status: fields.select({\n      label: \"Status\",\n      options: [\n        { label: \"New\", value: \"new\" },\n        { label: \"Reviewed\", value: \"reviewed\" },\n        { label: \"Archived\", value: \"archived\" },\n      ],\n      defaultValue: \"new\",\n    }),\n    message: fields.markdoc({ label: \"Message\" }),\n  },\n}),",
                            when: .always, style: .line),
            .copyFile(from: TemplateRef("integrations/docs/inbox-setup.md"),
                      to: "docs/inbox-setup.md", when: .always),
        ])
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -30
swift test --filter IntegrationCatalogTests 2>&1 | tail -40
swift test --filter IntegrationTemplateAssetsTests 2>&1 | tail -40
```
Expected: PASS, including the pre-existing `eachDescriptorIsStructurallyValid` and
`noDescriptorHasCollidingInjectAtAnchorOperations` parametrized tests (`inbox` now has one
`injectAtAnchor` op — no collision, nothing else touches that anchor+file+style in this
descriptor).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationCatalog.swift Resources/Template/integrations/docs/inbox-setup.md Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(core): wire up the inbox integration (Keystatic collection)

Part of #462. Runtime submission capture tracked separately in #<ISSUE_NUMBER>."
```

---

### Task 5: `membership` integration operations

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift`
- Create: `Resources/Template/integrations/pages/members.astro`
- Create: `Resources/Template/integrations/components/MemberCard.astro`
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`

**Interfaces:**
- Consumes: `members` Astro collection (Task 2) via `getCollection("members")`; `// anglesite:keystatic-collections`
  anchor (Task 1).

- [ ] **Step 1: Write the failing tests**

In `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`:

```swift
    @Test func membershipHasNoProvidersAndInjectsKeystaticCollection() {
        let membership = IntegrationCatalog.descriptor(for: .membership)
        #expect(membership.providers.isEmpty)
        let hasKeystaticInject = membership.operations.contains {
            if case .injectAtAnchor(let file, let anchor, let snippet, _, let style) = $0 {
                return file.raw == "keystatic.config.ts"
                    && anchor == "// anglesite:keystatic-collections"
                    && style == .line
                    && snippet.raw.contains("path: \"src/content/members/*\"")
            }
            return false
        }
        #expect(hasKeystaticInject)
    }

    @Test func membershipCopiesDirectoryPageAndCard() {
        let membership = IntegrationCatalog.descriptor(for: .membership)
        let copiesPage = membership.operations.contains {
            if case .copyFile(let from, let to, let when) = $0 {
                return from.path == "integrations/pages/members.astro" && to.raw == "src/pages/members.astro" && when == .always
            }
            return false
        }
        let copiesCard = membership.operations.contains {
            if case .copyFile(let from, let to, let when) = $0 {
                return from.path == "integrations/components/MemberCard.astro" && to.raw == "src/components/MemberCard.astro" && when == .always
            }
            return false
        }
        #expect(copiesPage)
        #expect(copiesCard)
    }

    @Test func membershipWritesDirectoryTitle() {
        let keys = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .membership))
        #expect(keys.contains("MEMBERSHIP_DIRECTORY_TITLE"))
    }
```

In `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`, add
`"integrations/pages/members.astro"` and `"integrations/components/MemberCard.astro"` to the
staged-list loop, and `"src/pages/members.astro"` / `"src/components/MemberCard.astro"` to the
must-be-absent loop.

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift build --build-tests 2>&1 | tail -30
```
Expected: all three new `IntegrationCatalogTests` fail (empty `operations: []`);
`IntegrationTemplateAssetsTests` fails (files don't exist).

- [ ] **Step 3: Write `Resources/Template/integrations/components/MemberCard.astro`**

```astro
---
interface Props {
  name: string;
  role?: string;
  photo?: string;
  links?: string[];
}
const { name, role, photo, links } = Astro.props;
---
<article class="member-card">
  {photo && <img src={photo} alt={name} width="96" height="96" />}
  <h3>{name}</h3>
  {role && <p class="role">{role}</p>}
  {links && links.length > 0 && (
    <ul class="links">
      {links.map((link) => <li><a href={link}>{link}</a></li>)}
    </ul>
  )}
</article>

<style>
  .member-card { display: flex; flex-direction: column; gap: 0.25rem; }
  .member-card img { border-radius: 50%; object-fit: cover; }
  .role { color: var(--color-text-muted, #666); margin: 0; }
  .links { list-style: none; padding: 0; margin: 0; display: flex; gap: 0.5rem; flex-wrap: wrap; }
</style>
```

- [ ] **Step 4: Write `Resources/Template/integrations/pages/members.astro`**

```astro
---
import { getCollection } from "astro:content";
import BaseLayout from "../../src/layouts/BaseLayout.astro";
import MemberCard from "../../src/components/MemberCard.astro";
import { readConfig } from "../../scripts/config";

const members = (await getCollection("members")).sort(
  (a, b) => a.data.joinedDate.valueOf() - b.data.joinedDate.valueOf()
);
const title = readConfig("MEMBERSHIP_DIRECTORY_TITLE") ?? "Our Members";
---
<BaseLayout title={title}>
  <h1>{title}</h1>
  <div class="member-grid">
    {members.map((member) => (
      <MemberCard
        name={member.data.name}
        role={member.data.role}
        photo={member.data.photo}
        links={member.data.links}
      />
    ))}
  </div>
</BaseLayout>

<style>
  .member-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 1.5rem;
  }
</style>
```

Note: this file lives under `integrations/pages/` (staged, copied on toggle only) — its relative
imports (`../../src/layouts/BaseLayout.astro`, `../../scripts/config`) are written for its
*destination* path (`src/pages/members.astro`), matching how `integrations/pages/contact.astro`
and siblings already do this (verify against `Resources/Template/integrations/pages/contact.astro`
if the relative depth looks off after copying).

- [ ] **Step 5: Add the `membership` operations**

In `Sources/AnglesiteCore/IntegrationCatalog.swift`, replace the `membership` descriptor:

```swift
    // MARK: membership
    static let membership = IntegrationDescriptor(
        id: .membership,
        displayName: "Member Directory",
        summary: "A public list of members you curate through a built-in admin UI (Keystatic).",
        providers: [],
        fields: [
            Field(key: "directoryTitle", label: "Directory title", kind: .text, isOptional: true, defaultValue: "Our Members"),
        ],
        operations: [
            .injectAtAnchor(file: "keystatic.config.ts", anchor: "// anglesite:keystatic-collections",
                            snippet: "members: collection({\n  label: \"Members\",\n  path: \"src/content/members/*\",\n  format: { contentField: \"bio\" },\n  schema: {\n    name: fields.text({ label: \"Name\" }),\n    role: fields.text({ label: \"Role\" }),\n    joinedDate: fields.date({ label: \"Joined\" }),\n    photo: fields.image({ label: \"Photo\", directory: \"src/content/members\" }),\n    links: fields.array(fields.url({ label: \"Link\" }), { label: \"Links\", itemLabel: (props) => props.value || \"Link\" }),\n    bio: fields.markdoc({ label: \"Bio\" }),\n  },\n}),",
                            when: .always, style: .line),
            .copyFile(from: TemplateRef("integrations/pages/members.astro"),
                      to: "src/pages/members.astro", when: .always),
            .copyFile(from: TemplateRef("integrations/components/MemberCard.astro"),
                      to: "src/components/MemberCard.astro", when: .always),
            .writeConfig([
                ConfigEntry(key: "MEMBERSHIP_DIRECTORY_TITLE", value: "{{directoryTitle}}"),
            ], when: .always),
        ])
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
swift build --build-tests 2>&1 | tail -30
swift test --filter IntegrationCatalogTests 2>&1 | tail -40
swift test --filter IntegrationTemplateAssetsTests 2>&1 | tail -40
```
Expected: PASS. Also re-run `injectedSnippetKeysAreWrittenByDescriptor` (parametrized over all of
`IntegrationCatalog.all`, runs automatically) — `members.astro` uses `readConfig("MEMBERSHIP_DIRECTORY_TITLE")`
outside an `injectAtAnchor` snippet (it's in a copied file), so this test doesn't need it, but the
`writeConfig` entry must still exist for `membershipWritesDirectoryTitle` above.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationCatalog.swift Resources/Template/integrations/pages/members.astro Resources/Template/integrations/components/MemberCard.astro Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(core): wire up the membership integration (public directory)

Part of #462."
```

---

### Task 6: Manual GUI smoke + Keystatic field-API verification

**Files:** none (verification only)

- [ ] **Step 1: Scaffold a throwaway test site**

```bash
Resources/Template/scripts/scaffold.sh --yes ~/Sites/keystatic-smoke
cd ~/Sites/keystatic-smoke
npm install
```

- [ ] **Step 2: Verify Keystatic's real `fields.*` API matches what was written**

```bash
grep -r "export declare" node_modules/@keystatic/core/dist/*.d.ts | grep -i "fields\." | head -20
```
Compare against the `fields.text` / `fields.date` / `fields.select` / `fields.markdoc` /
`fields.image` / `fields.array` / `fields.url` calls written in Tasks 4/5. If any signature has
drifted from what's used above (this plan was written without live access to Keystatic's
published API), fix the descriptor snippets in `IntegrationCatalog.swift` now and re-run
`swift test --filter IntegrationCatalogTests`.

- [ ] **Step 3: Apply both integrations via the app (or a direct `IntegrationOperations` call) and boot dev**

Toggle `inbox` and `membership` on for the smoke site (via the app's integration wizard UI, or by
hand-running the same `copyFile`/`injectAtAnchor` edits Tasks 4/5 describe), then:

```bash
npx astro dev &
sleep 3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4321/keystatic
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4321/members
kill %1
```
Expected: both `200`. In a browser, confirm `/keystatic` shows **Inbox** and **Members**
collections, and that creating a member entry there causes `/members` to render it after reload.

- [ ] **Step 4: Verify the production build excludes Keystatic and stays deploy-clean**

```bash
npm run build
npx tsx scripts/pre-deploy-check.ts
```
Expected: `npm run build`'s `dist/` has no `/keystatic` route; `pre-deploy-check.ts` exits 0
(confirms the Task 1 Step 3 assumption about Keystatic being dev-only held up in practice).

- [ ] **Step 5: Clean up the throwaway site**

```bash
rm -rf ~/Sites/keystatic-smoke
```
(`~/Sites/*` scratch sites are disposable — see project convention.)

No commit for this task — it's verification only. If Step 2 or Step 4 surfaced a fix, that fix was
already committed as part of Task 4/5's amended step.

---

## Self-Review Notes

- **Spec coverage:** foundation (Task 1) ✅, `content.config.ts` anchor discussion in the spec was
  superseded by the `ContentTypeRegistry`-driven approach for `membership` and dropped entirely for
  `inbox` — both are noted as deliberate deviations discovered during planning (the spec's own
  `ContentConfigDriftTests` would otherwise fail); `inbox` (Task 4) ✅; `membership` (Task 5) ✅;
  follow-up issue (Task 4 Step 1) ✅; testing section (Tasks 1–6 verification steps) ✅.
- **Placeholder scan:** the only forward-reference is `<ISSUE_NUMBER>` in Task 4, which is filled
  in from that same task's Step 1 output before the file is written — not a deferred TBD.
- **Type consistency:** `IntegrationID.inbox`/`.membership` (Task 3) match usage in Tasks 4–5;
  `ContentTypeRegistry.member`'s `storage: .collection("members")` matches the `members` collection
  name used in `content.config.ts` (Task 2) and `getCollection("members")` (Task 5).
