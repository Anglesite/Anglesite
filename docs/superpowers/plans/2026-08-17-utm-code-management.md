# UTM Code Management UI Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a site owner define named UTM campaigns and assign them to RSS collections and/or the Fediverse outbox, so links that reach the site through those channels carry attribution parameters automatically.

**Architecture:** A new `UTMCodesStore` (AnglesiteCore) reads/writes `Source/utm-codes.json`, mirroring `RedirectsStore` exactly. The Astro build tags each collection's `FeedItem.link` at the single point it's constructed (`toFeedItem`/`mapCollection`); the Cloudflare Worker tags the Fediverse `Note.url` in `fanOutMicropubCreateToActivityPub` via a static JSON import, mirroring the existing `experiments.json` pattern. A new "Manage UTM Codes…" button in the Analytics tab of Website Settings opens a sheet that edits the registry, wired into `PlistEditorModel`'s existing dirty-facet save machinery exactly like Redirects.

**Tech Stack:** Swift 6.4 (AnglesiteCore, AnglesiteApp, Swift Testing), TypeScript (Astro template lib code + Cloudflare Worker), `node:test` via `tsx` for pure lib logic, Vitest (`@cloudflare/vitest-pool-workers`) for the Worker.

**Spec:** [`docs/superpowers/specs/2026-08-17-utm-code-management-design.md`](../specs/2026-08-17-utm-code-management-design.md)

## Global Constraints

- Conventional commits, subject line ≤72 characters, reference `#1092`.
- PR body must use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan) and a `Closes #1092` line.
- No paired sidecar PR — this is app + `Resources/Template/` only, no MCP schema change.
- `Target` raw string values (`blog`, `notes`, `articles`, `photos`, `albums`, `bookmarks`, `replies`, `likes`, `fediverse`) must match verbatim between the Swift enum and the TypeScript string literals — they round-trip through the same `utm-codes.json`.
- Because this touches `Resources/Template/`, run `swift test --package-path .` locally (some Swift tests couple to template markup), plus the template's own `npm test` / `npm run test:worker`.
- `Tests/AnglesiteAppTests` (`PlistEditorModel*Tests`) is not executed by CI (Xcode-27-only coverage per CONTRIBUTING.md) — run it locally before opening the PR.

---

### Task 1: `UTMCodesStore` (AnglesiteCore)

**Files:**
- Create: `Sources/AnglesiteCore/UTMCodesStore.swift`
- Test: `Tests/AnglesiteCoreTests/UTMCodesStoreTests.swift`

**Interfaces:**
- Produces: `UTMCodesStore` struct with `init(sourceDirectory: URL, fileManager: FileManager = .default)`, `func load() throws -> [Campaign]`, `func save(_ campaigns: [Campaign]) throws`, `static func validate(_ campaigns: [Campaign]) throws`.
- Produces: `UTMCodesStore.Campaign` — `Sendable, Equatable, Codable, Identifiable` — fields `id: UUID`, `source: String`, `medium: String`, `campaign: String`, `term: String?`, `content: String?`, `appliesTo: [Target]`; `init(id: UUID = UUID(), source: String = "", medium: String = "", campaign: String = "", term: String? = nil, content: String? = nil, appliesTo: [Target] = [])`.
- Produces: `UTMCodesStore.Target` — `String, Sendable, Codable, CaseIterable, Hashable` enum: `blog, notes, articles, photos, albums, bookmarks, replies, likes, fediverse`, plus `var displayName: String`.
- Produces: `UTMCodesStore.ValidationError` — `Error, Equatable` — `case duplicateTarget(Target)`, `case missingRequiredField(UUID, field: String)`.

- [ ] **Step 1: Write the failing test file**

Create `Tests/AnglesiteCoreTests/UTMCodesStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("UTMCodesStore")
struct UTMCodesStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UTMCodesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns an empty array, not a throw")
    func loadMissingReturnsEmpty() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        #expect(try store.load() == [])
    }

    @Test("save then load round-trips campaigns through utm-codes.json")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "affiliate-2026", appliesTo: [.blog, .notes]),
        ]
        try store.save(campaigns)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("utm-codes.json").path))
        #expect(try store.load() == campaigns)
    }

    @Test("save omits nil term/content from the written JSON")
    func omitsNilOptionalFields() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        try store.save([UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "x")])
        let raw = try String(contentsOf: dir.appendingPathComponent("utm-codes.json"), encoding: .utf8)
        #expect(!raw.contains("term"))
        #expect(!raw.contains("content"))
    }

    @Test("save normalizes appliesTo to canonical Target order regardless of input order")
    func normalizesTargetOrder() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "x", appliesTo: [.notes, .blog])
        try store.save([campaign])
        let loaded = try store.load()
        #expect(loaded.first?.appliesTo == [.blog, .notes])
    }

    @Test("save rejects two campaigns claiming the same target")
    func rejectsDuplicateTarget() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        #expect(throws: UTMCodesStore.ValidationError.duplicateTarget(.blog)) {
            try store.save(campaigns)
        }
    }

    @Test("save rejects an assigned campaign with an empty source")
    func rejectsMissingSourceOnAssignedCampaign() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "", medium: "feed", campaign: "a", appliesTo: [.blog])
        #expect(throws: UTMCodesStore.ValidationError.missingRequiredField(campaign.id, field: "source")) {
            try store.save([campaign])
        }
    }

    @Test("save accepts an incomplete draft campaign with no targets")
    func acceptsIncompleteDraftWithNoTargets() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let campaign = UTMCodesStore.Campaign(source: "", medium: "", campaign: "")
        try store.save([campaign])
        #expect(try store.load() == [campaign])
    }

    @Test("a rejected save leaves the previously-saved file untouched")
    func rejectedSaveDoesNotOverwrite() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UTMCodesStore(sourceDirectory: dir)
        let good = [UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog])]
        try store.save(good)
        let bad = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        #expect(throws: (any Error).self) { try store.save(bad) }
        #expect(try store.load() == good)
    }

    @Test("Target.displayName covers every case with a non-empty label")
    func displayNameCoversEveryCase() {
        for target in UTMCodesStore.Target.allCases {
            #expect(!target.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile (the type doesn't exist yet)**

Run: `swift test --package-path . --filter UTMCodesStoreTests`
Expected: FAIL — `cannot find type 'UTMCodesStore' in scope`

- [ ] **Step 3: Implement `UTMCodesStore`**

Create `Sources/AnglesiteCore/UTMCodesStore.swift`:

```swift
import Foundation

/// Reads/writes `Source/utm-codes.json` — a git-tracked, ordered list of named UTM campaigns a
/// site owner assigns to RSS collections and/or the Fediverse outbox (#1092). Mirrors
/// `RedirectsStore`'s shape and rationale exactly: rooted at `sourceDirectory` (the `Source/` git
/// repo), not `Config/`, because both the Astro build (RSS/Atom/JSON Feed generation) and the
/// Cloudflare Worker (Fediverse fan-out) need to read it — app-owned `Config/` state is invisible
/// to both.
///
/// A template-side lib (`src/lib/utm-codes.ts`) is the RSS/feed consumer at build time; a
/// worker-local `worker/utm-codes.ts` (paired with a static `../utm-codes.json` import) is the
/// Fediverse consumer at runtime. This type only owns the read/write/validate contract the app's
/// UTM Codes UI uses to produce that file.
public struct UTMCodesStore: Sendable {
    /// One named UTM campaign, as serialized in `utm-codes.json`.
    public struct Campaign: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// `utm_source` — e.g. "rss", "fediverse".
        public var source: String
        /// `utm_medium` — e.g. "feed", "social".
        public var medium: String
        /// `utm_campaign`.
        public var campaign: String
        /// `utm_term`, omitted from the tagged URL and from JSON when unset.
        public var term: String?
        /// `utm_content`, omitted from the tagged URL and from JSON when unset.
        public var content: String?
        /// Which RSS collections and/or the Fediverse outbox this campaign is currently applied
        /// to. A campaign with no targets is a draft — defined but not yet wired into any output.
        public var appliesTo: [Target]

        public init(
            id: UUID = UUID(),
            source: String = "",
            medium: String = "",
            campaign: String = "",
            term: String? = nil,
            content: String? = nil,
            appliesTo: [Target] = []
        ) {
            self.id = id
            self.source = source
            self.medium = medium
            self.campaign = campaign
            self.term = term
            self.content = content
            self.appliesTo = appliesTo
        }
    }

    /// One tagging target: an RSS collection (matching `FEED_COLLECTIONS`' keys in the template's
    /// `src/lib/feeds.ts`) or the Fediverse outbox. Raw values round-trip through
    /// `utm-codes.json` verbatim, so the Swift and TypeScript sides must agree on these strings.
    public enum Target: String, Sendable, Codable, CaseIterable, Hashable {
        case blog, notes, articles, photos, albums, bookmarks, replies, likes
        case fediverse

        /// User-facing label for the UTM Codes UI, matching `FEED_COLLECTIONS`'s `.title` strings
        /// in `feeds.ts` for the RSS cases.
        public var displayName: String {
            switch self {
            case .blog: return "Blog"
            case .notes: return "Notes"
            case .articles: return "Articles"
            case .photos: return "Photos"
            case .albums: return "Albums"
            case .bookmarks: return "Bookmarks"
            case .replies: return "Replies"
            case .likes: return "Likes"
            case .fediverse: return "Fediverse"
            }
        }
    }

    /// Invariants ``UTMCodesStore/validate(_:)`` enforces before anything reaches disk.
    public enum ValidationError: Error, Equatable {
        /// Two campaigns both claim the same target — at most one campaign can apply to a given
        /// RSS collection or Fediverse at a time.
        case duplicateTarget(Target)
        /// A campaign has at least one target but is missing the named required field.
        case missingRequiredField(UUID, field: String)
    }

    private let fileURL: URL
    private let fileManager: FileManager

    /// Roots the store at `<sourceDirectory>/utm-codes.json` — inside the `Source/` git repo, for
    /// the same reason `RedirectsStore` does: this is site content the build/deploy pipeline
    /// reads, not app-owned state. `fileManager` is injectable for tests.
    public init(sourceDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = sourceDirectory.appendingPathComponent("utm-codes.json")
        self.fileManager = fileManager
    }

    /// `[]` (not a throw) when the file is absent — the normal "no UTM codes yet" case for a
    /// freshly scaffolded site.
    public func load() throws -> [Campaign] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Campaign].self, from: data)
    }

    /// Validates, normalizes each campaign's `appliesTo` to a deterministic order, then writes the
    /// full list (pretty-printed, sorted keys, atomic — the file is git-tracked and hand-readable,
    /// so diffs should stay minimal). Validation runs here rather than only in the UI, so no code
    /// path can persist a file the template-side build/worker code would silently mis-tag from.
    ///
    /// - Throws: A ``ValidationError`` before touching disk, or the underlying encode/write error.
    public func save(_ campaigns: [Campaign]) throws {
        try Self.validate(campaigns)
        let normalized = campaigns.map { campaign -> Campaign in
            var campaign = campaign
            campaign.appliesTo = Target.allCases.filter { campaign.appliesTo.contains($0) }
            return campaign
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Checks every campaign's invariants: no two campaigns share a target, and any campaign with
    /// at least one target has non-empty source/medium/campaign (a draft with no targets can be
    /// left incomplete).
    ///
    /// - Throws: A ``ValidationError`` for the first violation found.
    public static func validate(_ campaigns: [Campaign]) throws {
        var seenTargets = Set<Target>()
        for campaign in campaigns {
            for target in campaign.appliesTo {
                guard !seenTargets.contains(target) else {
                    throw ValidationError.duplicateTarget(target)
                }
                seenTargets.insert(target)
            }
        }
        for campaign in campaigns where !campaign.appliesTo.isEmpty {
            if campaign.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "source")
            }
            if campaign.medium.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "medium")
            }
            if campaign.campaign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "campaign")
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter UTMCodesStoreTests`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/UTMCodesStore.swift Tests/AnglesiteCoreTests/UTMCodesStoreTests.swift
git commit -m "feat(#1092): add UTMCodesStore for utm-codes.json"
```

---

### Task 2: Template UTM reader/tagger (`src/lib/utm-codes.ts`)

**Files:**
- Create: `Resources/Template/src/lib/utm-codes.ts`
- Test: `Resources/Template/src/lib/utm-codes.test.ts`
- Create: `Resources/Template/utm-codes.json` (checked-in default, matches `redirects.json`'s pattern)

**Interfaces:**
- Consumes: nothing new (pure Node `fs`/`path`/`URL`).
- Produces: `UTMCampaign` interface (`source: string; medium: string; campaign: string; term?: string; content?: string; appliesTo: string[]`), `readUTMCodes(siteRoot?: string): UTMCampaign[]`, `activeCampaignFor(campaigns: UTMCampaign[], target: string): UTMCampaign | undefined`, `tagUrl(url: string, campaign: UTMCampaign | undefined): string`.

- [ ] **Step 1: Install template dependencies (first time only)**

Run: `cd Resources/Template && npm install`

- [ ] **Step 2: Add the checked-in default registry**

Create `Resources/Template/utm-codes.json`:

```json
[]
```

- [ ] **Step 3: Write the failing test file**

Create `Resources/Template/src/lib/utm-codes.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readUTMCodes, activeCampaignFor, tagUrl } from "./utm-codes.ts";
import type { UTMCampaign } from "./utm-codes.ts";

function withWarnSpy<T>(fn: (calls: unknown[][]) => T): T {
  const calls: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    calls.push(args);
  };
  try {
    return fn(calls);
  } finally {
    console.warn = original;
  }
}

function makeTempSiteRoot(): string {
  return mkdtempSync(join(tmpdir(), "anglesite-utm-codes-test-"));
}

test("readUTMCodes: missing file returns [] quietly, without warning", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const calls = withWarnSpy((calls) => {
      const result = readUTMCodes(siteRoot);
      assert.deepEqual(result, []);
      return calls;
    });
    assert.equal(calls.length, 0);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readUTMCodes: valid entries round-trip", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const campaigns: UTMCampaign[] = [
      { source: "rss", medium: "feed", campaign: "affiliate-2026", appliesTo: ["blog"] },
    ];
    writeFileSync(join(siteRoot, "utm-codes.json"), JSON.stringify(campaigns));
    assert.deepEqual(readUTMCodes(siteRoot), campaigns);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readUTMCodes: malformed JSON warns and returns []", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    writeFileSync(join(siteRoot, "utm-codes.json"), "{not json");
    const calls = withWarnSpy((calls) => {
      assert.deepEqual(readUTMCodes(siteRoot), []);
      return calls;
    });
    assert.equal(calls.length, 1);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readUTMCodes: a non-array JSON value warns and returns []", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    writeFileSync(join(siteRoot, "utm-codes.json"), JSON.stringify({ not: "an array" }));
    const calls = withWarnSpy((calls) => {
      assert.deepEqual(readUTMCodes(siteRoot), []);
      return calls;
    });
    assert.equal(calls.length, 1);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readUTMCodes: malformed individual entries are dropped, valid ones kept", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    writeFileSync(
      join(siteRoot, "utm-codes.json"),
      JSON.stringify([
        { source: "rss", medium: "feed", campaign: "ok", appliesTo: ["blog"] },
        { source: "rss" }, // missing medium/campaign/appliesTo
      ]),
    );
    const calls = withWarnSpy((calls) => {
      const result = readUTMCodes(siteRoot);
      assert.deepEqual(result, [{ source: "rss", medium: "feed", campaign: "ok", appliesTo: ["blog"] }]);
      return calls;
    });
    assert.equal(calls.length, 1);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("activeCampaignFor: finds the campaign whose appliesTo includes the target", () => {
  const campaigns: UTMCampaign[] = [
    { source: "rss", medium: "feed", campaign: "a", appliesTo: ["notes"] },
    { source: "rss", medium: "feed", campaign: "b", appliesTo: ["blog"] },
  ];
  assert.equal(activeCampaignFor(campaigns, "blog")?.campaign, "b");
});

test("activeCampaignFor: undefined when no campaign targets it", () => {
  const campaigns: UTMCampaign[] = [{ source: "rss", medium: "feed", campaign: "a", appliesTo: ["notes"] }];
  assert.equal(activeCampaignFor(campaigns, "blog"), undefined);
});

test("tagUrl: appends utm_source/medium/campaign", () => {
  const campaign: UTMCampaign = { source: "rss", medium: "feed", campaign: "affiliate-2026", appliesTo: ["blog"] };
  const tagged = tagUrl("https://example.com/blog/hello/", campaign);
  const u = new URL(tagged);
  assert.equal(u.searchParams.get("utm_source"), "rss");
  assert.equal(u.searchParams.get("utm_medium"), "feed");
  assert.equal(u.searchParams.get("utm_campaign"), "affiliate-2026");
  assert.equal(u.searchParams.get("utm_term"), null);
  assert.equal(u.searchParams.get("utm_content"), null);
});

test("tagUrl: includes utm_term/utm_content only when set", () => {
  const campaign: UTMCampaign = {
    source: "rss",
    medium: "feed",
    campaign: "affiliate-2026",
    term: "reviews",
    content: "sidebar",
    appliesTo: ["blog"],
  };
  const u = new URL(tagUrl("https://example.com/blog/hello/", campaign));
  assert.equal(u.searchParams.get("utm_term"), "reviews");
  assert.equal(u.searchParams.get("utm_content"), "sidebar");
});

test("tagUrl: returns the url unchanged when campaign is undefined", () => {
  assert.equal(tagUrl("https://example.com/blog/hello/", undefined), "https://example.com/blog/hello/");
});

test("tagUrl: preserves an existing query string", () => {
  const campaign: UTMCampaign = { source: "rss", medium: "feed", campaign: "a", appliesTo: ["blog"] };
  const u = new URL(tagUrl("https://example.com/blog/hello/?ref=x", campaign));
  assert.equal(u.searchParams.get("ref"), "x");
  assert.equal(u.searchParams.get("utm_source"), "rss");
});
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/utm-codes.test.ts`
Expected: FAIL — cannot find module `./utm-codes.ts`

- [ ] **Step 5: Implement `utm-codes.ts`**

Create `Resources/Template/src/lib/utm-codes.ts`:

```ts
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface UTMCampaign {
  source: string;
  medium: string;
  campaign: string;
  term?: string;
  content?: string;
  appliesTo: string[];
}

/// Returns `true` if `entry` has the shape `readUTMCodes` requires: `source`/`medium`/`campaign`
/// are strings, `term`/`content` are absent or strings, and `appliesTo` is an array of strings.
export function isValidUTMCampaign(entry: unknown): entry is UTMCampaign {
  if (typeof entry !== "object" || entry === null) return false;
  const e = entry as Record<string, unknown>;
  return (
    typeof e.source === "string" &&
    typeof e.medium === "string" &&
    typeof e.campaign === "string" &&
    (e.term === undefined || typeof e.term === "string") &&
    (e.content === undefined || typeof e.content === "string") &&
    Array.isArray(e.appliesTo) &&
    e.appliesTo.every((t) => typeof t === "string")
  );
}

/// Reads `utm-codes.json` from the site root. Returns `[]` if the file is missing entirely — a
/// site with no UTM codes yet is the normal, silent case. If the file is present but fails to
/// parse, or parses but individual entries are malformed, this warns via `console.warn`
/// (surfaced in Astro's build/dev logs) and drops the bad parts, mirroring `readRedirects` in
/// `scripts/redirects.ts` — a build must never fail because `utm-codes.json` was hand-edited into
/// a bad state.
export function readUTMCodes(siteRoot: string = process.cwd()): UTMCampaign[] {
  const path = resolve(siteRoot, "utm-codes.json");
  if (!existsSync(path)) return [];

  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`[anglesite-utm] utm-codes.json exists but is not valid JSON: ${err}`);
    return [];
  }

  if (!Array.isArray(parsed)) {
    console.warn("[anglesite-utm] utm-codes.json must contain a JSON array; ignoring its contents.");
    return [];
  }

  const valid = parsed.filter(isValidUTMCampaign);
  const droppedCount = parsed.length - valid.length;
  if (droppedCount > 0) {
    console.warn(
      `[anglesite-utm] dropped ${droppedCount} malformed UTM ${droppedCount === 1 ? "entry" : "entries"} from utm-codes.json.`,
    );
  }
  return valid;
}

/// The campaign (if any) whose `appliesTo` names `target` — an RSS collection key or
/// `"fediverse"`. At most one campaign should claim a given target (`UTMCodesStore.validate`
/// enforces this on the Swift side before it ever reaches disk); the first match wins if that
/// invariant is ever violated by a hand-edited file.
export function activeCampaignFor(campaigns: UTMCampaign[], target: string): UTMCampaign | undefined {
  return campaigns.find((c) => c.appliesTo.includes(target));
}

/// Appends `utm_source`/`utm_medium`/`utm_campaign` (plus `utm_term`/`utm_content` when set) to
/// `url` via `URLSearchParams`, safe against an existing query string. Returns `url` unchanged
/// when `campaign` is `undefined` — the "no active campaign for this target" case.
export function tagUrl(url: string, campaign: UTMCampaign | undefined): string {
  if (!campaign) return url;
  const u = new URL(url);
  u.searchParams.set("utm_source", campaign.source);
  u.searchParams.set("utm_medium", campaign.medium);
  u.searchParams.set("utm_campaign", campaign.campaign);
  if (campaign.term) u.searchParams.set("utm_term", campaign.term);
  if (campaign.content) u.searchParams.set("utm_content", campaign.content);
  return u.href;
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/lib/utm-codes.test.ts`
Expected: PASS (11 tests)

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/src/lib/utm-codes.ts Resources/Template/src/lib/utm-codes.test.ts Resources/Template/utm-codes.json
git commit -m "feat(#1092): add UTM registry reader/tagger to template"
```

---

### Task 3: Wire UTM tagging into RSS/Atom/JSON Feed generation

**Files:**
- Modify: `Resources/Template/src/lib/feeds.ts` (`toFeedItem`)
- Modify: `Resources/Template/src/lib/feed-data.ts` (`mapCollection`)
- Modify: `Resources/Template/src/lib/feeds.test.ts` (new cases)

**Interfaces:**
- Consumes: `tagUrl`, `activeCampaignFor`, `readUTMCodes`, `type UTMCampaign` from `./utm-codes.ts` (Task 2).
- Produces: `toFeedItem(collection, entry, site, contentHtml, licenseInfo?, utmCampaign?)` — same return shape (`FeedItem`) as before, with `link` now tagged when `utmCampaign` is passed.

- [ ] **Step 1: Write the failing test cases**

Add to `Resources/Template/src/lib/feeds.test.ts` (near the existing `toFeedItem` tests, after the imports add `tagUrl` isn't needed here — only `toFeedItem` is under test):

```ts
test("toFeedItem tags the link with the given UTM campaign", () => {
  const item = toFeedItem(
    "blog",
    entry("blog", { title: "Hi", pubDate: "2026-01-02" }),
    SITE,
    "<p>Hi</p>",
    undefined,
    { source: "rss", medium: "feed", campaign: "affiliate-2026", appliesTo: ["blog"] },
  );
  const u = new URL(item.link);
  assert.equal(u.pathname, "/blog/hello/");
  assert.equal(u.searchParams.get("utm_source"), "rss");
  assert.equal(u.searchParams.get("utm_medium"), "feed");
  assert.equal(u.searchParams.get("utm_campaign"), "affiliate-2026");
});

test("toFeedItem leaves the link untagged when no UTM campaign is passed", () => {
  const item = toFeedItem("blog", entry("blog", { title: "Hi", pubDate: "2026-01-02" }), SITE, "<p>Hi</p>");
  assert.equal(item.link, "https://example.com/blog/hello/");
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/feeds.test.ts`
Expected: FAIL — `toFeedItem` doesn't accept a 6th argument yet (TypeScript compile error under `tsx`, or the extra arg is silently ignored and the tagged-link assertion fails)

- [ ] **Step 3: Update `toFeedItem` in `feeds.ts`**

In `Resources/Template/src/lib/feeds.ts`, add the import and extend the function. Add near the top with the other local imports:

```ts
import { tagUrl, type UTMCampaign } from "./utm-codes.ts";
```

Change the `toFeedItem` signature and its `link` line:

```ts
export function toFeedItem(
  collection: string,
  entry: FeedEntry,
  site: string,
  contentHtml: string,
  licenseInfo: { license: LicenseRef | null; assertsNothingExplicitly: boolean } = {
    license: null,
    assertsNothingExplicitly: false,
  },
  utmCampaign?: UTMCampaign,
): FeedItem {
  const cfg = FEED_COLLECTIONS[collection];
  if (!cfg) throw new Error(`No feed config for collection "${collection}"`);
  const rawDate = entry.data[cfg.dateField];
  const date = rawDate instanceof Date ? rawDate : new Date(rawDate);
  if (Number.isNaN(date.getTime())) {
    throw new Error(`[feeds] entry "${entry.id}" has a missing or invalid ${cfg.dateField}`);
  }
  const summary = (entry.data.summary ?? entry.data.caption ?? excerpt(entry.body, 280)) || "";
  const tags = Array.isArray(entry.data.tags) && entry.data.tags.length > 0 ? entry.data.tags : undefined;
  const absolutized = contentHtml ? absolutizeHtmlUrls(contentHtml, site) : contentHtml;
  const body = absolutized || interactionContentFallback(collection, entry.data);
  const withImage = collection === "photos" ? photoImageHtml(entry.data, site) + body : body;
  return {
    title: cfg.deriveTitle(entry) || undefined,
    link: tagUrl(new URL(`/${collection}/${entry.id}/`, site).href, utmCampaign),
    date,
    summary: String(summary),
    license: licenseInfo.license,
    assertsNothingExplicitly: licenseInfo.assertsNothingExplicitly,
    contentHtml: withImage,
    tags,
  };
}
```

(Only the signature line and the `link:` line change; the body between them is unchanged — shown in full above so the diff is unambiguous.)

- [ ] **Step 4: Run the `feeds.test.ts` tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/lib/feeds.test.ts`
Expected: PASS (all existing + 2 new cases)

- [ ] **Step 5: Wire `mapCollection` in `feed-data.ts` to look up and pass the active campaign**

In `Resources/Template/src/lib/feed-data.ts`, add the import near the other local imports:

```ts
import { readUTMCodes, activeCampaignFor } from "./utm-codes.ts";
```

Change `mapCollection`:

```ts
async function mapCollection(collection: string, site: string): Promise<FeedItem[]> {
  const entries = await getCollection(collection as any, (entry: any) => !entry.data.draft);
  const policy = licensingPolicy();
  const licensable = collection as LicensableCollection;
  const licenseInfo = {
    license: licenseFor(licensable),
    assertsNothingExplicitly: assertsNothingExplicitly(policy, licensable),
  };
  const utmCampaign = activeCampaignFor(readUTMCodes(), collection);
  return Promise.all(
    entries.map(async (e: any) => {
      const entry: FeedEntry = { id: e.id, collection, data: e.data, body: e.body };
      const contentHtml = await renderContentHtml(entry);
      return toFeedItem(collection, entry, site, contentHtml, licenseInfo, utmCampaign);
    }),
  );
}
```

- [ ] **Step 6: Run the full template lib test suite**

Run: `cd Resources/Template && npm run test:scripts`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/src/lib/feeds.ts Resources/Template/src/lib/feed-data.ts Resources/Template/src/lib/feeds.test.ts
git commit -m "feat(#1092): tag RSS/Atom/JSON Feed links with active UTM campaigns"
```

---

### Task 4: Wire UTM tagging into the Fediverse fan-out

**Files:**
- Create: `Resources/Template/worker/utm-codes.ts`
- Modify: `Resources/Template/worker/worker.ts` (`fanOutMicropubCreateToActivityPub`)
- Modify: `Resources/Template/worker/worker.test.ts` (new tests)

**Interfaces:**
- Produces: `tagFediverseUrl(url: string, campaignsArtifact: unknown): string` — the sole export `worker.ts` calls.

`worker/utm-codes.ts` deliberately duplicates the small `UTMCampaign` shape check and tag-building logic from `src/lib/utm-codes.ts` rather than importing across the `worker/` ↔ `src/lib/` boundary: `worker.ts` has no existing precedent for importing from `src/lib` or `scripts/` (it only imports from its own directory and npm packages), and the duplicated logic is ~15 lines. `campaignsArtifact` is typed `unknown` because it comes from a static JSON import (`../utm-codes.json`) whose shape isn't guaranteed at the type level — the function validates defensively at runtime, the same tolerance principle `readUTMCodes` uses.

- [ ] **Step 1: Write the failing test cases**

Add to `Resources/Template/worker/worker.test.ts`. First add the import near the top with the other local imports:

```ts
import { tagFediverseUrl } from "./utm-codes.ts";
```

Then add these test cases (near the existing `micropub-to-activitypub fan-out` tests):

```ts
test("tagFediverseUrl: appends utm params when a campaign targets fediverse", () => {
  const campaigns = [
    { source: "fediverse", medium: "social", campaign: "affiliate-2026", appliesTo: ["fediverse"] },
  ];
  const tagged = tagFediverseUrl("https://owner.example/notes/abc/", campaigns);
  const u = new URL(tagged);
  expect(u.searchParams.get("utm_source")).toBe("fediverse");
  expect(u.searchParams.get("utm_medium")).toBe("social");
  expect(u.searchParams.get("utm_campaign")).toBe("affiliate-2026");
});

test("tagFediverseUrl: returns the url unchanged when no campaign targets fediverse", () => {
  const campaigns = [{ source: "rss", medium: "feed", campaign: "x", appliesTo: ["blog"] }];
  expect(tagFediverseUrl("https://owner.example/notes/abc/", campaigns)).toBe("https://owner.example/notes/abc/");
});

test("tagFediverseUrl: a malformed artifact (not an array) is treated as no campaigns", () => {
  expect(tagFediverseUrl("https://owner.example/notes/abc/", { bad: true })).toBe(
    "https://owner.example/notes/abc/",
  );
});

test("tagFediverseUrl: malformed individual entries in the artifact are ignored", () => {
  const campaigns = [{ source: "fediverse" }, { source: "fediverse", medium: "social", campaign: "x", appliesTo: ["fediverse"] }];
  const tagged = tagFediverseUrl("https://owner.example/notes/abc/", campaigns);
  expect(new URL(tagged).searchParams.get("utm_campaign")).toBe("x");
});

test("micropub-to-activitypub fan-out: outbox Note.url matches the created post's Location when the default utm-codes.json has no active Fediverse campaign", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["UTM url wiring check"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  const location = createResponse.headers.get("location");
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as {
    orderedItems?: Array<{ object?: { url?: string; content?: string } }>;
  };
  const item = outboxPage.orderedItems?.find((i) => i.object?.content?.includes("UTM url wiring check"));
  expect(item?.object?.url).toBe(location);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npm run test:worker -- -t "tagFediverseUrl"`
Expected: FAIL — cannot find module `./utm-codes.ts` under `worker/`

- [ ] **Step 3: Implement `worker/utm-codes.ts`**

Create `Resources/Template/worker/utm-codes.ts`:

```ts
/// Worker-local UTM tagging (#1092). Deliberately self-contained rather than importing from
/// `src/lib/utm-codes.ts`: `worker.ts` has no existing precedent for importing across the
/// `worker/` <-> `src/lib/`/`scripts/` boundary, and this logic is small enough that duplicating
/// it is the lower-risk choice. `campaignsArtifact` comes from a static `../utm-codes.json`
/// import (see `worker.ts`), so its shape is `unknown` at the type level — validated defensively
/// here, the same tolerance principle `readUTMCodes` uses on the Astro side.
interface UTMCampaign {
  source: string;
  medium: string;
  campaign: string;
  term?: string;
  content?: string;
  appliesTo: string[];
}

function isValidUTMCampaign(entry: unknown): entry is UTMCampaign {
  if (typeof entry !== "object" || entry === null) return false;
  const e = entry as Record<string, unknown>;
  return (
    typeof e.source === "string" &&
    typeof e.medium === "string" &&
    typeof e.campaign === "string" &&
    (e.term === undefined || typeof e.term === "string") &&
    (e.content === undefined || typeof e.content === "string") &&
    Array.isArray(e.appliesTo) &&
    e.appliesTo.every((t) => typeof t === "string")
  );
}

/// Tags `url` with the campaign (if any) whose `appliesTo` includes `"fediverse"`, found within
/// `campaignsArtifact` (the raw `utm-codes.json` module). Returns `url` unchanged when the
/// artifact is malformed or no campaign targets Fediverse.
export function tagFediverseUrl(url: string, campaignsArtifact: unknown): string {
  const campaigns = Array.isArray(campaignsArtifact) ? campaignsArtifact.filter(isValidUTMCampaign) : [];
  const campaign = campaigns.find((c) => c.appliesTo.includes("fediverse"));
  if (!campaign) return url;
  const u = new URL(url);
  u.searchParams.set("utm_source", campaign.source);
  u.searchParams.set("utm_medium", campaign.medium);
  u.searchParams.set("utm_campaign", campaign.campaign);
  if (campaign.term) u.searchParams.set("utm_term", campaign.term);
  if (campaign.content) u.searchParams.set("utm_content", campaign.content);
  return u.href;
}
```

- [ ] **Step 4: Wire it into `worker.ts`**

In `Resources/Template/worker/worker.ts`, add the import next to the existing `experiments.json` import:

```ts
import experimentsArtifact from "./experiments.json";
import utmCodesArtifact from "../utm-codes.json";
import { tagFediverseUrl } from "./utm-codes.ts";
```

In `fanOutMicropubCreateToActivityPub`, change the `note` object's `url` field from:

```ts
    url: location,
```

to:

```ts
    url: tagFediverseUrl(location, utmCodesArtifact),
```

- [ ] **Step 5: Run the full worker test suite**

Run: `cd Resources/Template && npm run test:worker`
Expected: PASS (existing tests unaffected — the default checked-in `utm-codes.json` is `[]`, so `tagFediverseUrl` is a no-op for all of them; new tests pass)

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/worker/utm-codes.ts Resources/Template/worker/worker.ts Resources/Template/worker/worker.test.ts
git commit -m "feat(#1092): tag Fediverse outbox links with the active UTM campaign"
```

---

### Task 5: `PlistEditorModel` — load/save/dirty-tracking for UTM campaigns

**Files:**
- Modify: `Sources/AnglesiteApp/PlistEditorModel.swift`
- Test: `Tests/AnglesiteAppTests/PlistEditorModelUTMCodesTests.swift` (new)
- Modify: `Tests/AnglesiteAppTests/PlistEditorModelDirtyFacetsTests.swift` (one new case)

**Interfaces:**
- Consumes: `UTMCodesStore`, `UTMCodesStore.Campaign` (Task 1).
- Produces on `PlistEditorModel`: `var utmCampaigns: [UTMCodesStore.Campaign]`, `var isUTMCodesDirty: Bool`, `private(set) var isSavingUTMCodes: Bool`, `private(set) var utmCodesError: String?`, `@discardableResult func saveUTMCodes() async -> Bool`.

- [ ] **Step 1: Write the failing test file**

Create `Tests/AnglesiteAppTests/PlistEditorModelUTMCodesTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel UTM codes (#1092)")
@MainActor
struct PlistEditorModelUTMCodesTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeModel() throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelUTMCodesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir)
    }

    @Test("load() populates utmCampaigns from utm-codes.json, empty when absent")
    func loadPopulatesEmpty() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.utmCampaigns.isEmpty)
        #expect(model.isUTMCodesDirty == false)
    }

    @Test("isUTMCodesDirty flips true after appending a campaign, false after saveUTMCodes")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns.append(
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]))
        #expect(model.isUTMCodesDirty == true)
        let saved = await model.saveUTMCodes()
        #expect(saved == true)
        #expect(model.isUTMCodesDirty == false)
        #expect(try UTMCodesStore(sourceDirectory: model.sourceDirectory).load() == model.utmCampaigns)
    }

    @Test("saveUTMCodes surfaces a validation failure via utmCodesError and leaves isUTMCodesDirty true")
    func saveValidationFailureSurfacesError() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns = [
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]),
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "b", appliesTo: [.blog]),
        ]
        let saved = await model.saveUTMCodes()
        #expect(saved == false)
        #expect(model.utmCodesError != nil)
        #expect(model.isUTMCodesDirty == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --package-path . --filter PlistEditorModelUTMCodesTests`
Expected: FAIL — `value of type 'PlistEditorModel' has no member 'utmCampaigns'`

- [ ] **Step 3: Add the state and load-time population**

In `Sources/AnglesiteApp/PlistEditorModel.swift`, add new stored properties near `redirectEntries` (after line 52, `private(set) var redirectsLoadFailed = false`):

```swift
    var utmCampaigns: [UTMCodesStore.Campaign] = []
    private(set) var savedUTMCampaigns: [UTMCodesStore.Campaign] = []
    private(set) var utmCodesError: String?
    private(set) var isSavingUTMCodes = false
    private(set) var utmCodesLoadFailed = false
```

Add the dirty computed property next to `isRedirectsDirty` (line 199):

```swift
    var isUTMCodesDirty: Bool { utmCampaigns != savedUTMCampaigns && loadError == nil && !isLoading }
```

In `load()`, immediately after the existing redirects-loading `do`/`catch` block (after line 318's closing brace):

```swift
            do {
                let campaigns = try UTMCodesStore(sourceDirectory: sourceDirectory).load()
                utmCampaigns = campaigns
                savedUTMCampaigns = campaigns
                utmCodesError = nil
                utmCodesLoadFailed = false
            } catch {
                utmCampaigns = []
                savedUTMCampaigns = []
                utmCodesError = "Couldn't load existing utm-codes.json — it may be corrupted or hand-edited with invalid entries. Fix it externally or your next save will discard it. (\(error.localizedDescription))"
                utmCodesLoadFailed = true
            }
```

- [ ] **Step 4: Add `saveUTMCodes()`**

Immediately after `saveRedirects()` (after line 511's closing brace), add:

```swift
    @discardableResult
    func saveUTMCodes() async -> Bool {
        guard isUTMCodesDirty else { return true }
        guard !isSavingUTMCodes else { return false }
        guard !utmCodesLoadFailed else {
            utmCodesError = "Refusing to save: the existing utm-codes.json failed to load and may contain campaigns this save would discard. Fix or back up the file, then reload this site's settings."
            return false
        }
        isSavingUTMCodes = true
        utmCodesError = nil
        defer { isSavingUTMCodes = false }
        let sourceDirectory = sourceDirectory
        let campaigns = utmCampaigns
        do {
            try await Task.detached(priority: .userInitiated) {
                try UTMCodesStore(sourceDirectory: sourceDirectory).save(campaigns)
            }.value
            savedUTMCampaigns = campaigns
            return true
        } catch {
            utmCodesError = "Couldn't save UTM codes: \(error.localizedDescription)"
            return false
        }
    }
```

- [ ] **Step 5: Register the facet in `flushBeforeLeaving()` and `dirtyFacets`**

In `flushBeforeLeaving()`, immediately after the `isRedirectsDirty` block (after line 402's closing brace):

```swift
        if isUTMCodesDirty {
            guard await saveUTMCodes() else { return false }
        }
```

In `dirtyFacets` (around line 1312), add a line right after the Redirects facet:

```swift
            DirtyFacet(isDirty: isRedirectsDirty, isSaving: isSavingRedirects) { await self.saveRedirects() },
            DirtyFacet(isDirty: isUTMCodesDirty, isSaving: isSavingUTMCodes) { await self.saveUTMCodes() },
```

- [ ] **Step 6: Run the new tests, then the dirty-facets suite**

Run: `swift test --package-path . --filter PlistEditorModelUTMCodesTests`
Expected: PASS (3 tests)

Run: `swift test --package-path . --filter PlistEditorModelDirtyFacetsTests`
Expected: PASS (existing tests still pass — the aggregation is generic per its own doc comment)

- [ ] **Step 7: Add one dirty-facet aggregation case for completeness**

In `Tests/AnglesiteAppTests/PlistEditorModelDirtyFacetsTests.swift`, add after `hasAnyUnsavedEditsReflectsLicensingAlone` (after line 117's closing brace), mirroring its shape:

```swift
    @Test("hasAnyUnsavedEdits reflects UTM-codes dirty state alone")
    func hasAnyUnsavedEditsReflectsUTMCodesAlone() async throws {
        let model = try makeModel()
        await model.load()
        model.utmCampaigns.append(
            UTMCodesStore.Campaign(source: "rss", medium: "feed", campaign: "a", appliesTo: [.blog]))
        #expect(model.isDirty == false)
        #expect(model.isRedirectsDirty == false)
        #expect(model.hasAnyUnsavedEdits == true)
    }
```

- [ ] **Step 8: Run the dirty-facets suite again**

Run: `swift test --package-path . --filter PlistEditorModelDirtyFacetsTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/PlistEditorModel.swift Tests/AnglesiteAppTests/PlistEditorModelUTMCodesTests.swift Tests/AnglesiteAppTests/PlistEditorModelDirtyFacetsTests.swift
git commit -m "feat(#1092): load/save UTM campaigns in PlistEditorModel"
```

---

### Task 6: UTM Codes management sheet (SwiftUI)

**Files:**
- Create: `Sources/AnglesiteApp/UTMCodesSheet.swift`
- Modify: `Sources/AnglesiteApp/PlistEditorView.swift`

**Interfaces:**
- Consumes: `PlistEditorModel.utmCampaigns` (`@Bindable`), `UTMCodesStore.Campaign`, `UTMCodesStore.Target` (Task 1), `SettingsBox` (existing).
- Produces: `struct UTMCodesSheet: View` with `init(model: PlistEditorModel)`.

This task has no new automated test (SwiftUI view layout isn't unit-tested elsewhere in this codebase either — `PlistEditorView` itself has no test file). Verify by building the app and exercising the sheet manually per Step 4.

- [ ] **Step 1: Create the sheet view**

Create `Sources/AnglesiteApp/UTMCodesSheet.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// "Manage UTM Codes…" popup (#1092), opened from the Analytics tab of Website Settings. A live
/// list bound directly to `model.utmCampaigns` — the same array `PlistEditorModel`'s existing
/// dirty-facet machinery already tracks, so leaving the Analytics tab or closing the site window
/// persists edits exactly like Redirects. "Done" additionally attempts an explicit save so a
/// validation failure (e.g. two campaigns claiming the same target) is caught with the sheet
/// still open, rather than silently deferred until the owner leaves the whole Analytics tab.
struct UTMCodesSheet: View {
    @Bindable var model: PlistEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UTM Codes").font(.headline)
                Spacer()
                if model.isSavingUTMCodes {
                    ProgressView().controlSize(.small)
                }
                Button("Done") {
                    Task {
                        if await model.saveUTMCodes() {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            if model.utmCampaigns.isEmpty {
                Text("No UTM codes yet. Add one below.")
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach($model.utmCampaigns) { $campaign in
                    UTMCampaignRow(campaign: $campaign)
                }
                .onDelete { model.utmCampaigns.remove(atOffsets: $0) }
            }
            .frame(minHeight: 240)

            Button {
                model.utmCampaigns.append(UTMCodesStore.Campaign())
            } label: {
                Label("Add UTM Code", systemImage: "plus")
            }

            if let utmCodesError = model.utmCodesError {
                Label(utmCodesError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
    }
}

private struct UTMCampaignRow: View {
    @Binding var campaign: UTMCodesStore.Campaign

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Source (e.g. rss)", text: $campaign.source)
                TextField("Medium (e.g. feed)", text: $campaign.medium)
                TextField("Campaign", text: $campaign.campaign)
                TextField("Term (optional)", text: optionalTextBinding($campaign.term))
                TextField("Content (optional)", text: optionalTextBinding($campaign.content))
                Text("Applies to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(UTMCodesStore.Target.allCases, id: \.self) { target in
                        Toggle(target.displayName, isOn: targetBinding(target))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                if !campaign.appliesTo.isEmpty {
                    Text(campaign.appliesTo.map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        let parts = [campaign.source, campaign.medium, campaign.campaign].filter { !$0.isEmpty }
        return parts.isEmpty ? "New UTM Code" : parts.joined(separator: " / ")
    }

    private func targetBinding(_ target: UTMCodesStore.Target) -> Binding<Bool> {
        Binding(
            get: { campaign.appliesTo.contains(target) },
            set: { isOn in
                if isOn {
                    if !campaign.appliesTo.contains(target) { campaign.appliesTo.append(target) }
                } else {
                    campaign.appliesTo.removeAll { $0 == target }
                }
            })
    }

    private func optionalTextBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
```

- [ ] **Step 2: Add the summary + button subsection to the Analytics tab**

In `Sources/AnglesiteApp/PlistEditorView.swift`, add sheet-presentation state next to `showingCustomAnalyticsHelp` (line 40):

```swift
    @State private var showingUTMCodesSheet = false
```

In `analyticsTab` (starting at line 298), add a new `SettingsBox` between the existing "Providers" box and the `HStack` that shows `isSavingAnalytics`/`customAnalyticsMessage` (i.e., right after the "Providers" `SettingsBox`'s closing brace, currently followed by the `HStack(spacing: 8) { ... }` block):

```swift
            SettingsBox(title: "UTM Codes") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(utmCodesSummary)
                        .foregroundStyle(.secondary)
                    Button("Manage UTM Codes…") {
                        showingUTMCodesSheet = true
                    }
                }
            }
```

Add the computed summary property near `customAnalyticsMessage` (around line 1119-1120):

```swift
    private var utmCodesSummary: String {
        let count = model.utmCampaigns.count
        if count == 0 { return "No UTM codes configured." }
        let appliedTargets = Set(model.utmCampaigns.flatMap(\.appliesTo))
        let noun = count == 1 ? "UTM code" : "UTM codes"
        guard !appliedTargets.isEmpty else {
            return "\(count) \(noun) configured, none applied yet."
        }
        let names = UTMCodesStore.Target.allCases.filter(appliedTargets.contains).map(\.displayName)
        return "\(count) \(noun) configured, applied to \(names.joined(separator: ", "))."
    }
```

Add the sheet modifier to `analyticsTab`'s view chain, after the existing `.popover(isPresented: $showingCustomAnalyticsHelp, ...)` block:

```swift
        .sheet(isPresented: $showingUTMCodesSheet) {
            UTMCodesSheet(model: model)
        }
```

- [ ] **Step 3: Save UTM codes when leaving the Analytics tab**

In `PlistEditorView`'s `.onChange(of: selectedTab)` block (around line 78-90), extend the `.analytics` branch:

```swift
        .onChange(of: selectedTab) { oldValue, _ in
            if oldValue == .analytics {
                Task {
                    await model.saveAnalytics()
                    await model.saveUTMCodes()
                }
            } else if oldValue == .redirects {
```

(Only the `.analytics` branch's body changes — the rest of the `if`/`else if` chain is unchanged.)

- [ ] **Step 4: Build and manually verify**

Run:
```bash
xcodegen generate
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: build succeeds.

Then open the app against a test site, go to **Website Settings → Analytics**, confirm:
- The "UTM Codes" box shows "No UTM codes configured." on a fresh site.
- "Manage UTM Codes…" opens the sheet.
- "Add UTM Code" appends a row; filling in source/medium/campaign and checking "Blog" updates the row's summary and target chip.
- "Done" persists — reopening the sheet (or reopening Website Settings) shows the saved campaign.
- Assigning "Blog" to two different campaigns and clicking "Done" shows an inline validation error and does not dismiss the sheet.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/UTMCodesSheet.swift Sources/AnglesiteApp/PlistEditorView.swift
git commit -m "feat(#1092): add UTM Codes management sheet to Analytics settings"
```

---

### Task 7: Full verification and PR

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS (including `AnglesiteAppTests` locally — CI does not execute it, per CONTRIBUTING.md)

- [ ] **Step 2: Run the full template test suite**

Run:
```bash
cd Resources/Template
npm test
npm run test:worker
```
Expected: PASS

- [ ] **Step 3: Run the app build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS

- [ ] **Step 4: Check for any user-visible text added without an interactive Xcode session**

This plan adds new `Text`/`Button`/`Label` literals in `UTMCodesSheet.swift` and `PlistEditorView.swift`. Per CONTRIBUTING.md, if the build in Step 3 was CLI-only (not run inside Xcode's IDE), run the `.xcstrings` sync recipe from CONTRIBUTING.md's "Development setup" section, scoped to this worktree's own `BUILD_DIR`, and review the diff before committing it.

- [ ] **Step 5: Re-check against CONTRIBUTING.md's "Commits and pull requests" section, then open the PR**

Confirm: conventional-commit subjects ≤72 chars (already satisfied per-task above); PR body built from `.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (Summary, Paired PR check, Test plan); `Closes #1092` line; Paired PR check states "no paired sidecar PR — app + template only, no MCP schema change."

```bash
git push -u origin claude/issue-1092-7d761f
gh pr create --title "feat(#1092): UTM code management for RSS and Fediverse" --body "$(cat <<'EOF'
## Summary
- Adds a per-site UTM campaign registry (`Source/utm-codes.json`), managed from Website Settings → Analytics → "Manage UTM Codes…".
- RSS/Atom/JSON Feed permalinks are tagged with a collection's active campaign at build time.
- The Fediverse outbox's Note.url is tagged with the active campaign at fan-out time.

## Paired PR check
No paired sidecar PR needed — this touches only the app and `Resources/Template/`, no MCP message schema change.

## Test plan
- [ ] `swift test --package-path .` passes
- [ ] `cd Resources/Template && npm test && npm run test:worker` passes
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` succeeds
- [ ] Manually verified the UTM Codes sheet in Website Settings → Analytics (add/edit/delete, validation error on duplicate target, persistence across reopen)

Closes #1092
EOF
)"
```

- [ ] **Step 6: Report the PR URL to the user**
