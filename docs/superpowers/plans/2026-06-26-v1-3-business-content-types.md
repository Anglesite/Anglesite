# V-1.3 Business Content Types + Content-Config Drift Guard — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the three collection-backed business content types (`announcement`, `event`, `review`) end-to-end — config, render, scaffold, smoke test — and add a registry↔`content.config.ts` drift guard covering all ten collection-backed types.

**Architecture:** Mirror V-1.2's personal-type pattern. `announcement` reuses the existing `Hentry.astro` (h-entry); `event` and `review` get their own per-type layouts (`Hevent.astro`/`Hreview.astro`) because they use the `h-event`/`h-review` microformats2 vocabularies. The dynamic route `[collection]/[...slug].astro` gains the three collections and a per-entry layout selector. Scaffolding needs no Swift changes — `ContentScaffold.renderEntry`/`createTyped` are already descriptor-driven. A new pure-Swift test generates the canonical `defineCollection` block from each registry descriptor and asserts it appears verbatim in `content.config.ts`.

**Tech Stack:** Swift 6.4 (Swift Testing), Astro content collections + Zod, microformats2.

## Global Constraints

- **Toolchain:** run all SwiftPM commands with Xcode 27. Prefix every `swift test`:
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` then `xcrun swift test --package-path .`
- **Source of truth:** `ContentTypeRegistry.swift` is the single source for type vocabulary. Do not hand-invent schemas — project them from descriptors.
- **mf2 only this pass:** layouts emit microformats2; schema.org JSON-LD is V-1.8 (out of scope). No `schemaType` rendering.
- **Scope excludes** `businessProfile` (page singleton), per-type SwiftUI editors, business-collection feeds.
- **Kind → Zod contract** (the drift guard enforces this exact mapping):
  `.string`/`.text`/`.image` → `z.string()`; `.url` → `z.string().url()`; `.date`/`.datetime` → `z.coerce.date()`; `.number` → `z.number()`; `.bool` → `z.boolean()`; `.stringArray`/`.imageArray` → `z.array(z.string())`; `.markdown` → **excluded** (it is the entry body). Non-required fields append `.optional()`.
- **Additive edits only** to `content.config.ts`, `[collection]/[...slug].astro`, and the render-smoke suites — `feat/348-feeds` touches the same files; keep conflicts minimal and use a *separate* new smoke-test file rather than editing `PersonalTypeRenderSmokeTests.swift`.
- **Spec:** `docs/superpowers/specs/2026-06-26-v1-3-business-content-types-design.md`.

---

## File Structure

- `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift` — **new.** Pure-Swift drift guard: generate canonical block per registry descriptor, assert verbatim in the config file.
- `Resources/Template/src/content.config.ts` — **modify.** Append `announcements`, `events`, `reviews` collections; extend `collections` export.
- `Resources/Template/src/layouts/Hevent.astro` — **new.** `h-event` layout.
- `Resources/Template/src/layouts/Hreview.astro` — **new.** `h-review` layout.
- `Resources/Template/src/pages/[collection]/[...slug].astro` — **modify.** Add three collections + per-entry layout selector.
- `Resources/Template/src/content/announcements/hello-announcement.md` — **new.** Seed.
- `Resources/Template/src/content/events/hello-event.md` — **new.** Seed.
- `Resources/Template/src/content/reviews/hello-review.md` — **new.** Seed.
- `Tests/AnglesiteCoreTests/BusinessTypeRenderSmokeTests.swift` — **new.** Build + assert mf2 per business type.
- `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` — **modify.** Add a business-type `renderEntry` assertion.

---

## Task 1: Content-config drift guard + business collections

**Files:**
- Create: `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`
- Modify: `Resources/Template/src/content.config.ts`

**Interfaces:**
- Consumes: `ContentTypeRegistry()` (default builtins), `ContentTypeDescriptor.{collection, fields}`, `ContentTypeField.{name, kind, required}`, `ContentTypeField.Kind` cases.
- Produces: a passing pure-Swift test that fails if any collection-backed registry type lacks its verbatim canonical `defineCollection` block in `content.config.ts`. No production symbols.

- [ ] **Step 1: Write the failing drift-guard test**

Create `Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("content.config.ts drift guard")
struct ContentConfigDriftTests {

    /// Repo-root-relative path to the committed template config. `swift test` runs with CWD = package root.
    static var configFile: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template/src/content.config.ts")
    }

    /// Canonical Zod expression for a field kind, or nil for the markdown body (excluded from frontmatter).
    static func zod(for kind: ContentTypeField.Kind) -> String? {
        switch kind {
        case .markdown: return nil
        case .string, .text, .image: return "z.string()"
        case .url: return "z.string().url()"
        case .date, .datetime: return "z.coerce.date()"
        case .number: return "z.number()"
        case .bool: return "z.boolean()"
        case .stringArray, .imageArray: return "z.array(z.string())"
        }
    }

    /// The single canonical `defineCollection` block for a collection-backed descriptor.
    static func canonicalBlock(_ d: ContentTypeDescriptor) -> String? {
        guard let collection = d.collection else { return nil }
        var schemaLines: [String] = []
        for field in d.fields {
            guard let zod = zod(for: field.kind) else { continue }
            let expr = field.required ? zod : "\(zod).optional()"
            schemaLines.append("    \(field.name): \(expr),")
        }
        return """
        const \(collection) = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/\(collection)" }),
          schema: z.object({
        \(schemaLines.joined(separator: "\n"))
          }),
        });
        """
    }

    @Test("every collection-backed registry type appears verbatim in content.config.ts")
    func configMatchesRegistry() throws {
        let source = try String(contentsOf: Self.configFile, encoding: .utf8)
        let exportLine = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("export const collections") }
            .map(String.init) ?? ""

        for descriptor in ContentTypeRegistry().all {
            guard let collection = descriptor.collection,
                  let block = Self.canonicalBlock(descriptor) else { continue }
            #expect(source.contains(block),
                    "content.config.ts is missing or has drifted from the canonical block for `\(collection)`:\n\(block)")
            #expect(exportLine.contains(collection),
                    "`\(collection)` is not listed in the `collections` export")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter ContentConfigDriftTests
```

Expected: FAIL. The seven personal blocks already match the canonical format, so the failures name the three missing business collections (`announcements`, `events`, `reviews`). (If a personal collection is also reported, its existing block has drifted from canonical formatting — reformat that block to match the printed canonical block before continuing; fields/types are unchanged, formatting only.)

- [ ] **Step 3: Add the three business collections to `content.config.ts`**

In `Resources/Template/src/content.config.ts`, after the `likes` collection block and before `export const collections`, add:

```ts
const announcements = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/announcements" }),
  schema: z.object({
    title: z.string(),
    publishDate: z.coerce.date(),
  }),
});

const events = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
  schema: z.object({
    name: z.string(),
    start: z.coerce.date(),
    end: z.coerce.date().optional(),
    location: z.string().optional(),
  }),
});

const reviews = defineCollection({
  loader: glob({ pattern: "**/*.md", base: "./src/content/reviews" }),
  schema: z.object({
    itemReviewed: z.string(),
    rating: z.number(),
    publishDate: z.coerce.date(),
  }),
});
```

Then replace the export line with:

```ts
export const collections = { blog, notes, articles, photos, albums, bookmarks, replies, likes, announcements, events, reviews };
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter ContentConfigDriftTests
```

Expected: PASS (all ten collection-backed types matched).

- [ ] **Step 5: Prove the guard bites (acceptance requirement)**

Temporarily delete the `location: z.string().optional(),` line from the `events` block, then run:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter ContentConfigDriftTests
```

Expected: FAIL naming `events`. Then restore the line and re-run to confirm PASS again. (This verifies the guard detects drift, not just absence.)

- [ ] **Step 6: Commit**

```bash
git add Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift Resources/Template/src/content.config.ts
git commit -m "feat(#345): content-config drift guard + business collections"
```

---

## Task 2: Render the business types (layouts, route, seeds, smoke)

**Files:**
- Create: `Resources/Template/src/layouts/Hevent.astro`
- Create: `Resources/Template/src/layouts/Hreview.astro`
- Create: `Resources/Template/src/content/announcements/hello-announcement.md`
- Create: `Resources/Template/src/content/events/hello-event.md`
- Create: `Resources/Template/src/content/reviews/hello-review.md`
- Modify: `Resources/Template/src/pages/[collection]/[...slug].astro`
- Create: `Tests/AnglesiteCoreTests/BusinessTypeRenderSmokeTests.swift`

**Interfaces:**
- Consumes: `AnglesiteTestSupport.E2EPrerequisites.locateNode()`, `TemplateBuildSerializer.shared.serialize { }`, `ProcessSupervisor.shared.run(executable:arguments:currentDirectoryURL:)`, the `Hentry.astro`/`BaseLayout.astro` layout convention.
- Produces: built HTML where `events/*` carries `h-event`+`dt-start`, `reviews/*` carries `h-review`+`p-rating`, `announcements/*` carries `h-entry`.

- [ ] **Step 1: Write the failing render-smoke test**

Create `Tests/AnglesiteCoreTests/BusinessTypeRenderSmokeTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("Business type render smoke")
struct BusinessTypeRenderSmokeTests {

    static var templateDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// True when the template can actually be built: a Node binary plus an installed Astro.
    static var buildable: Bool {
        guard E2EPrerequisites.locateNode() != nil else { return false }
        return FileManager.default.isReadableFile(
            atPath: templateDir.appendingPathComponent("node_modules/astro/astro.js").path)
    }

    @Test("seeded business types build and render their mf2 classes",
          .enabled(if: BusinessTypeRenderSmokeTests.buildable))
    func rendersMicroformats() async throws {
        let node = try #require(E2EPrerequisites.locateNode())
        let dist = Self.templateDir.appendingPathComponent("dist", isDirectory: true)

        func html(_ rel: String) throws -> String {
            try String(contentsOf: dist.appendingPathComponent(rel), encoding: .utf8)
        }

        // Hold the shared template-build lock across build + assertions: other render-smoke
        // suites rm -rf dist around their own build and would race on the shared template tree.
        try await TemplateBuildSerializer.shared.serialize {
            try? FileManager.default.removeItem(at: dist)
            defer { try? FileManager.default.removeItem(at: dist) }

            let result = try await ProcessSupervisor.shared.run(
                executable: node,
                arguments: ["node_modules/astro/astro.js", "build"],
                currentDirectoryURL: Self.templateDir)
            try #require(result.exitCode == 0, "astro build failed: \(result.stdout)\n\(result.stderr)")

            #expect(try html("announcements/hello-announcement/index.html").contains("h-entry"))
            let event = try html("events/hello-event/index.html")
            #expect(event.contains("h-event"))
            #expect(event.contains("dt-start"))
            let review = try html("reviews/hello-review/index.html")
            #expect(review.contains("h-review"))
            #expect(review.contains("p-rating"))
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter BusinessTypeRenderSmokeTests
```

Expected: FAIL — `astro build` errors (the three collections have no content dirs / the route does not emit their pages), or the asserted HTML files are missing. (If Node/Astro are not installed the test is skipped via `.enabled(if:)`; install with `cd Resources/Template && npm ci` to actually exercise it.)

- [ ] **Step 3: Create the `Hevent.astro` layout**

Create `Resources/Template/src/layouts/Hevent.astro`:

```astro
---
import BaseLayout from "./BaseLayout.astro";

interface Props {
  entry: { data: Record<string, any> };
}

const { entry } = Astro.props;
const d = entry.data;
const startISO = d.start ? new Date(d.start).toISOString() : undefined;
const startHuman = d.start ? new Date(d.start).toLocaleString() : undefined;
const endISO = d.end ? new Date(d.end).toISOString() : undefined;
const endHuman = d.end ? new Date(d.end).toLocaleString() : undefined;
---

<BaseLayout title={d.name ?? "Event"} description={d.location}>
  <article class="h-event">
    <h1 class="p-name">{d.name}</h1>
    {startISO && <time class="dt-start" datetime={startISO}>{startHuman}</time>}
    {endISO && <time class="dt-end" datetime={endISO}>{endHuman}</time>}
    {d.location && <p class="p-location">{d.location}</p>}
    <div class="e-content"><slot /></div>
  </article>
</BaseLayout>
```

- [ ] **Step 4: Create the `Hreview.astro` layout**

Create `Resources/Template/src/layouts/Hreview.astro`:

```astro
---
import BaseLayout from "./BaseLayout.astro";

interface Props {
  entry: { data: Record<string, any> };
}

const { entry } = Astro.props;
const d = entry.data;
const iso = d.publishDate ? new Date(d.publishDate).toISOString() : undefined;
const human = d.publishDate ? new Date(d.publishDate).toLocaleDateString() : undefined;
---

<BaseLayout title={d.itemReviewed ?? "Review"}>
  <article class="h-review">
    <h1 class="p-item">{d.itemReviewed}</h1>
    <data class="p-rating" value={d.rating}>{d.rating}</data>
    <div class="e-content"><slot /></div>
    {iso && <time class="dt-published" datetime={iso}>{human}</time>}
  </article>
</BaseLayout>
```

- [ ] **Step 5: Wire the three collections into the dynamic route**

Replace the entire contents of `Resources/Template/src/pages/[collection]/[...slug].astro` with:

```astro
---
import { getCollection, render } from "astro:content";
import Hentry from "../../layouts/Hentry.astro";
import Hevent from "../../layouts/Hevent.astro";
import Hreview from "../../layouts/Hreview.astro";

type EntryCollection =
  | "notes" | "articles" | "photos" | "albums" | "bookmarks" | "replies" | "likes"
  | "announcements" | "events" | "reviews";

export async function getStaticPaths() {
  const collections: EntryCollection[] = [
    "notes", "articles", "photos", "albums", "bookmarks", "replies", "likes",
    "announcements", "events", "reviews",
  ];
  const paths = [];
  for (const collection of collections) {
    const entries = await getCollection(collection);
    for (const entry of entries) {
      paths.push({ params: { collection, slug: entry.id }, props: { entry } });
    }
  }
  return paths;
}

const { entry } = Astro.props;
const { Content } = await render(entry);
const Layout = entry.collection === "events" ? Hevent : entry.collection === "reviews" ? Hreview : Hentry;
---

<Layout entry={entry}><Content /></Layout>
```

- [ ] **Step 6: Create the three seed entries**

Create `Resources/Template/src/content/announcements/hello-announcement.md`:

```markdown
---
title: "Hello, announcement"
publishDate: 2026-01-01T00:00:00.000Z
---

This is a sample announcement.
```

Create `Resources/Template/src/content/events/hello-event.md`:

```markdown
---
name: "Hello, event"
start: 2026-01-01T18:00:00.000Z
end: 2026-01-01T20:00:00.000Z
location: "Main Street"
---

This is a sample event.
```

Create `Resources/Template/src/content/reviews/hello-review.md`:

```markdown
---
itemReviewed: "Hello, product"
rating: 5
publishDate: 2026-01-01T00:00:00.000Z
---

This is a sample review.
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter BusinessTypeRenderSmokeTests
```

Expected: PASS (or SKIPPED if Node/Astro absent — in that case run `cd Resources/Template && npm ci` first, then re-run, and confirm PASS before committing).

- [ ] **Step 8: Commit**

```bash
git add Resources/Template/src/layouts/Hevent.astro Resources/Template/src/layouts/Hreview.astro \
  "Resources/Template/src/pages/[collection]/[...slug].astro" \
  Resources/Template/src/content/announcements Resources/Template/src/content/events Resources/Template/src/content/reviews \
  Tests/AnglesiteCoreTests/BusinessTypeRenderSmokeTests.swift
git commit -m "feat(#345): render business types (h-event, h-review, announcement)"
```

---

## Task 3: Scaffold-path coverage + acceptance gate

**Files:**
- Modify: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift`

**Interfaces:**
- Consumes: `ContentScaffold.renderEntry(descriptor:title:now:) -> String`, `ContentTypeRegistry().descriptor(id:)`.
- Produces: a test proving `renderEntry` emits correct business-type frontmatter (no production changes needed — `createTyped` is descriptor-driven).

- [ ] **Step 1: Write the scaffold test**

Add this test to `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` (inside the existing suite struct, or in a new `@Suite` if the file uses free-standing `@Test`s — match the file's existing style).

Behavior being locked in: `renderEntry` fills only the `title`/`name` field from the passed title; every other string field scaffolds empty; `.datetime` fields get the `now` ISO timestamp; `.number` gets `0`; the `.markdown` body becomes the placeholder line. `event.name` is the `name`-special-case (filled); `review.itemReviewed` is a plain `.string` (empty).

```swift
@Test("renderEntry emits business-type frontmatter from the registry descriptor")
func businessTypeFrontmatter() throws {
    let registry = ContentTypeRegistry()
    let now = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00.000Z

    let event = try #require(registry.descriptor(id: "event"))
    let eventOut = ContentScaffold.renderEntry(descriptor: event, title: "Launch", now: now)
    #expect(eventOut.contains("name: \"Launch\""))
    #expect(eventOut.contains("start: 1970-01-01T00:00:00.000Z"))
    #expect(eventOut.contains("end: 1970-01-01T00:00:00.000Z"))
    #expect(eventOut.contains("location: \"\""))
    #expect(eventOut.contains("Write your event here."))

    let review = try #require(registry.descriptor(id: "review"))
    let reviewOut = ContentScaffold.renderEntry(descriptor: review, title: "Widget", now: now)
    #expect(reviewOut.contains("itemReviewed: \"\"")) // plain .string, not the name/title special case
    #expect(reviewOut.contains("rating: 0"))
    #expect(reviewOut.contains("publishDate: 1970-01-01T00:00:00.000Z"))
}
```

- [ ] **Step 2: Run the scaffold test to verify it passes**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter ContentScaffoldTests
```

Expected: PASS.

- [ ] **Step 3: Run the full acceptance gate**

```bash
# Swift: drift guard + scaffold + render smoke
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift test --package-path . --filter "ContentConfigDriftTests|ContentScaffoldTests|BusinessTypeRenderSmokeTests"

# Template: full build + pre-deploy-check (requires deps: cd Resources/Template && npm ci, once)
cd Resources/Template && npm run build && npm run check
```

Expected: all Swift tests PASS; `astro build` succeeds; `pre-deploy-check` (`npm run check`) reports no errors. `blog` and the seven personal collections still build and render unchanged.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/ContentScaffoldTests.swift
git commit -m "test(#345): cover business-type scaffolding via renderEntry"
```

---

## Self-Review

**Spec coverage:**
- §1 config collections → Task 1 Step 3. ✓
- §2 per-type layouts + route selector → Task 2 Steps 3–5. ✓
- §3 scaffold (no Swift change) + seeds → Task 2 Step 6 (seeds), Task 3 (scaffold coverage). ✓
- §4 drift guard (exact canonical block, all ten types, proven to bite) → Task 1 Steps 1–5. ✓
- §5 render smoke (h-entry / h-event+dt-start / h-review+p-rating) → Task 2 Step 1. ✓
- §Acceptance (build + pre-deploy-check green; guard bites; mf2 asserted; blog+personal intact) → Task 1 Step 5, Task 3 Step 3. ✓
- §Coordination risk (additive, separate smoke file) → Global Constraints + new `BusinessTypeRenderSmokeTests.swift`. ✓
- businessProfile / editors / JSON-LD / business feeds → explicitly out of scope. ✓

**Placeholder scan:** none — every code/command step has concrete content.

**Type consistency:** `canonicalBlock`/`zod(for:)` defined and used in Task 1 only; `Hevent`/`Hreview` created in Task 2 Steps 3–4 and referenced in the route in Step 5; `entry.collection` selector matches the seed collection names and the config collection keys; smoke-test HTML paths (`events/hello-event/index.html`) match the seed filenames. Consistent.
