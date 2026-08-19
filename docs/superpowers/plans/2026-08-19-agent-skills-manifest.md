# Agent Skills Manifest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `/.well-known/agent-skills/` (Cloudflare's Agent Skills Discovery RFC shape) describing the visitor-facing tasks — subscribe to feeds, send a webmention, contact the owner, book a time — that are actually live for a given built site, and flip the Agent Readiness catalog's `agentSkills` check to "provided."

**Architecture:** A new pure plan/apply module (`Resources/Template/scripts/agent-skills.ts`) mirrors the existing `planSecurityTxt`/`planAtprotoDid` shape in `edge-artifacts.ts`: a pure `planAgentSkills()` decides which of four known skills are active and what to write/delete, an impure `applyAgentSkillsPlan()` carries it out, wired into `edge-artifacts.ts`'s existing `main()`. Two content-based ownership markers (an HTML comment in each `SKILL.md`, a `"generator": "anglesite"` field in `index.json`) let both the TypeScript build-verify seam (`well-known.ts`) and the Swift host-side inventory scan (`WellKnownInventory.swift`) recognize this generator's own output, exactly like `security.txt`/`mta-sts.txt`/`atproto-did` already do.

**Tech Stack:** TypeScript (`npx tsx --test`, this template's existing pure-module test convention), Swift Testing (`swift test`).

## Global Constraints

- Spec: [Agent Skills Discovery RFC](https://github.com/cloudflare/agent-skills-discovery-rfc) — skill names: 1–64 chars, lowercase alphanumeric + hyphens, no leading/trailing/doubled hyphen; digests: `sha256:<64 lowercase hex chars>` of the referenced file's raw bytes; `index.json` MUST have `$schema` + `skills[]`; clients MUST ignore unrecognized fields.
- Full design: [docs/superpowers/specs/2026-08-19-agent-skills-manifest-design.md](../specs/2026-08-19-agent-skills-manifest-design.md).
- Conventional commits, subject ≤72 chars, reference `#1579`. Commit after every task.
- Per `CONTRIBUTING.md`: touching `Resources/Template/` means `swift test` must be run before considering this done, not just the JS suite.

---

### Task 1: Core primitives — markers, digest, doc/index builders

**Files:**
- Create: `Resources/Template/scripts/agent-skills.ts`
- Create: `Resources/Template/scripts/agent-skills.test.ts`

**Interfaces:**
- Produces: `AGENT_SKILLS_MARKER: string`, `AGENT_SKILLS_SCHEMA: string`, `isValidSkillName(name: string): boolean`, `sha256Digest(content: string): string`, `AgentSkillsContext { siteUrl: string | undefined; webmentionEnabled: boolean; contactPageExists: boolean; bookingPageExists: boolean }`, `AgentSkillDefinition { name: string; description: string; body: (ctx: AgentSkillsContext) => string }`, `buildSkillMarkdown(skill: AgentSkillDefinition, ctx: AgentSkillsContext): string`, `isAgentSkillsDocOwned(content: string | null): boolean`, `AgentSkillsIndexEntry { name: string; description: string; url: string; digest: string }`, `buildIndexJson(entries: AgentSkillsIndexEntry[]): string`, `isAgentSkillsIndexOwned(content: string | null): boolean`.

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/scripts/agent-skills.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import {
  AGENT_SKILLS_MARKER,
  buildIndexJson,
  buildSkillMarkdown,
  isAgentSkillsDocOwned,
  isAgentSkillsIndexOwned,
  isValidSkillName,
  sha256Digest,
  type AgentSkillDefinition,
  type AgentSkillsContext,
} from "./agent-skills";

const CTX: AgentSkillsContext = {
  siteUrl: "https://example.com",
  webmentionEnabled: true,
  contactPageExists: true,
  bookingPageExists: true,
};

test("isValidSkillName: accepts the RFC's naming rule", () => {
  assert.equal(isValidSkillName("subscribe-feed"), true);
  assert.equal(isValidSkillName("a"), true);
  assert.equal(isValidSkillName("a".repeat(64)), true);
});

test("isValidSkillName: rejects leading, trailing, doubled hyphens, uppercase, and over-length", () => {
  assert.equal(isValidSkillName("-leading"), false);
  assert.equal(isValidSkillName("trailing-"), false);
  assert.equal(isValidSkillName("double--hyphen"), false);
  assert.equal(isValidSkillName("Upper"), false);
  assert.equal(isValidSkillName("a".repeat(65)), false);
  assert.equal(isValidSkillName(""), false);
});

test("sha256Digest: known content hashes to the known sha256, in RFC sha256:<hex> shape", () => {
  // echo -n "hello" | sha256sum
  assert.equal(
    sha256Digest("hello"),
    "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
  );
});

const SAMPLE_SKILL: AgentSkillDefinition = {
  name: "sample-skill",
  description: "A sample skill for testing.",
  body: (ctx) => `Visit ${ctx.siteUrl ?? ""}/sample for details.\n`,
};

test("buildSkillMarkdown: emits frontmatter, the marker, and the rendered body in order", () => {
  const out = buildSkillMarkdown(SAMPLE_SKILL, CTX);
  assert.match(out, /^---\nname: sample-skill\ndescription: A sample skill for testing\.\n---\n/);
  const markerIndex = out.indexOf(AGENT_SKILLS_MARKER);
  const bodyIndex = out.indexOf("Visit https://example.com/sample");
  assert.ok(markerIndex > -1 && bodyIndex > markerIndex, "marker precedes the body");
});

test("isAgentSkillsDocOwned: recognizes its own marker and rejects hand-authored/absent content", () => {
  assert.equal(isAgentSkillsDocOwned(buildSkillMarkdown(SAMPLE_SKILL, CTX)), true);
  assert.equal(isAgentSkillsDocOwned("---\nname: x\ndescription: y\n---\nhand-authored\n"), false);
  assert.equal(isAgentSkillsDocOwned(null), false);
});

test("buildIndexJson: emits $schema, the generator marker, and one entry per input in order", () => {
  const json = buildIndexJson([
    { name: "a", description: "A", url: "/.well-known/agent-skills/a/SKILL.md", digest: "sha256:aa" },
    { name: "b", description: "B", url: "/.well-known/agent-skills/b/SKILL.md", digest: "sha256:bb" },
  ]);
  const parsed = JSON.parse(json);
  assert.equal(parsed.generator, "anglesite");
  assert.match(parsed.$schema, /^https:\/\/schemas\.agentskills\.io\/discovery\//);
  assert.deepEqual(parsed.skills.map((s: { name: string }) => s.name), ["a", "b"]);
  assert.equal(parsed.skills[0].type, "skill-md");
  assert.ok(json.endsWith("\n"));
});

test("isAgentSkillsIndexOwned: recognizes its own marker and rejects hand-authored/malformed/absent content", () => {
  assert.equal(isAgentSkillsIndexOwned(buildIndexJson([])), true);
  assert.equal(isAgentSkillsIndexOwned(JSON.stringify({ $schema: "x", skills: [] })), false);
  assert.equal(isAgentSkillsIndexOwned("not json"), false);
  assert.equal(isAgentSkillsIndexOwned(null), false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: FAIL — `agent-skills.ts` doesn't exist yet (module not found).

- [ ] **Step 3: Write the minimal implementation**

Create `Resources/Template/scripts/agent-skills.ts`:

```ts
#!/usr/bin/env npx tsx
/**
 * Agent Skills manifest primitives (#1579, slice 4 of the #1326 Agent Readiness ladder).
 *
 * Publishes `/.well-known/agent-skills/index.json` plus one `SKILL.md` per active skill, per
 * Cloudflare's Agent Skills Discovery RFC (https://github.com/cloudflare/agent-skills-discovery-rfc)
 * — the mechanism its own Agent Readiness scan's `agentSkills` check looks for. See
 * docs/superpowers/specs/2026-08-19-agent-skills-manifest-design.md for the full design.
 *
 * Ownership markers (how a later build tells its own prior output apart from a hand-authored
 * file, mirroring `SECURITY_TXT_MARKER`/`MTA_STS_MARKER` in `edge-artifacts.ts`):
 * - Each `SKILL.md` carries `AGENT_SKILLS_MARKER` as one of its lines.
 * - `index.json` carries an extra `"generator": "anglesite"` top-level field — safe under the
 *   RFC's "clients MUST ignore unrecognized fields" rule.
 */
import { createHash } from "node:crypto";

/** Mirrors `GeneratedEndpoints.agentSkillsDocMarker` in `WellKnownInventory.swift`. */
export const AGENT_SKILLS_MARKER =
  "<!-- Generated by Anglesite — do not edit; this file is regenerated from site config each build -->";

/** Opaque per the RFC — identifies the index schema version; need not resolve. */
export const AGENT_SKILLS_SCHEMA = "https://schemas.agentskills.io/discovery/0.2.0/schema.json";

/** The RFC's skill-name rule: 1–64 chars, lowercase alphanumeric and hyphens, no leading/
 * trailing or doubled hyphen. */
const SKILL_NAME_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/;

export function isValidSkillName(name: string): boolean {
  return name.length >= 1 && name.length <= 64 && SKILL_NAME_PATTERN.test(name);
}

/** `sha256:<64 lowercase hex chars>` of `content`'s raw UTF-8 bytes — the RFC's digest format. */
export function sha256Digest(content: string): string {
  return `sha256:${createHash("sha256").update(content, "utf-8").digest("hex")}`;
}

/** Everything a skill's `body()` needs to render absolute-or-relative task URLs and know which
 * of the four possible skills are actually live for this build. */
export interface AgentSkillsContext {
  siteUrl: string | undefined;
  webmentionEnabled: boolean;
  contactPageExists: boolean;
  bookingPageExists: boolean;
}

export interface AgentSkillDefinition {
  name: string;
  description: string;
  body: (ctx: AgentSkillsContext) => string;
}

/** `${skill.name}/SKILL.md`'s full content: YAML frontmatter, then the ownership marker, then
 * the skill's rendered body. */
export function buildSkillMarkdown(skill: AgentSkillDefinition, ctx: AgentSkillsContext): string {
  return (
    `---\n` +
    `name: ${skill.name}\n` +
    `description: ${skill.description}\n` +
    `---\n` +
    `${AGENT_SKILLS_MARKER}\n\n` +
    `${skill.body(ctx)}`
  );
}

/** `content !== null` and it carries `AGENT_SKILLS_MARKER` as one of its lines — this generator's
 * own prior output, safe to overwrite or delete. */
export function isAgentSkillsDocOwned(content: string | null): boolean {
  return content !== null && content.split("\n").includes(AGENT_SKILLS_MARKER);
}

export interface AgentSkillsIndexEntry {
  name: string;
  description: string;
  url: string;
  digest: string;
}

/** `index.json`'s content for the given active entries, in RFC shape plus the `generator`
 * ownership marker. */
export function buildIndexJson(entries: AgentSkillsIndexEntry[]): string {
  const doc = {
    $schema: AGENT_SKILLS_SCHEMA,
    generator: "anglesite",
    skills: entries.map((entry) => ({
      name: entry.name,
      type: "skill-md",
      description: entry.description,
      url: entry.url,
      digest: entry.digest,
    })),
  };
  return `${JSON.stringify(doc, null, 2)}\n`;
}

/** `content` parses as JSON and its top-level `generator` field is `"anglesite"` — this
 * generator's own prior `index.json`, safe to overwrite. */
export function isAgentSkillsIndexOwned(content: string | null): boolean {
  if (content === null) return false;
  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return false;
  }
  return (
    typeof parsed === "object" &&
    parsed !== null &&
    (parsed as { generator?: unknown }).generator === "anglesite"
  );
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/agent-skills.ts Resources/Template/scripts/agent-skills.test.ts
git commit -m "feat(#1579): agent-skills manifest core primitives"
```

---

### Task 2: The skill catalog and activation matrix

**Files:**
- Modify: `Resources/Template/scripts/agent-skills.ts`
- Modify: `Resources/Template/scripts/agent-skills.test.ts`

**Interfaces:**
- Consumes: `AgentSkillDefinition`, `AgentSkillsContext` from Task 1.
- Produces: `AGENT_SKILLS: AgentSkillDefinition[]`, `activeSkillNames(ctx: AgentSkillsContext): Set<string>`.

- [ ] **Step 1: Write the failing tests**

In `Resources/Template/scripts/agent-skills.test.ts`, add `AGENT_SKILLS` and `activeSkillNames` to the existing top-of-file `import { ... } from "./agent-skills";` block from Task 1 (don't add a second `import ... from "./agent-skills"` line — extend the one that's there), then append these tests:

```ts
test("AGENT_SKILLS: every catalog name is RFC-valid and unique", () => {
  const names = AGENT_SKILLS.map((s) => s.name);
  for (const name of names) assert.equal(isValidSkillName(name), true, `${name} is RFC-valid`);
  assert.equal(new Set(names).size, names.length, "no duplicate names");
});

test("activeSkillNames: subscribe-feed is always active", () => {
  const names = activeSkillNames({
    siteUrl: undefined,
    webmentionEnabled: false,
    contactPageExists: false,
    bookingPageExists: false,
  });
  assert.deepEqual([...names], ["subscribe-feed"]);
});

test("activeSkillNames: each optional skill turns on independently", () => {
  const webmentionOnly = activeSkillNames({
    siteUrl: undefined,
    webmentionEnabled: true,
    contactPageExists: false,
    bookingPageExists: false,
  });
  assert.equal(webmentionOnly.has("send-webmention"), true);
  assert.equal(webmentionOnly.has("contact-site-owner"), false);
  assert.equal(webmentionOnly.has("book-a-time"), false);

  const contactAndBooking = activeSkillNames({
    siteUrl: undefined,
    webmentionEnabled: false,
    contactPageExists: true,
    bookingPageExists: true,
  });
  assert.equal(contactAndBooking.has("contact-site-owner"), true);
  assert.equal(contactAndBooking.has("book-a-time"), true);
  assert.equal(contactAndBooking.has("send-webmention"), false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: FAIL — `activeSkillNames`/`AGENT_SKILLS` not exported yet.

- [ ] **Step 3: Write the minimal implementation**

Append to `Resources/Template/scripts/agent-skills.ts` (after `isAgentSkillsIndexOwned`):

```ts
/** `path` rendered against `ctx.siteUrl` when it's a usable HTTPS origin, so an off-site agent
 * gets a URL it can actually fetch; falls back to the bare root-relative path otherwise (mirrors
 * `buildSecurityTxt`'s optional-`siteUrl` handling in `edge-artifacts.ts`). */
function absoluteOrRelative(ctx: AgentSkillsContext, path: string): string {
  if (!ctx.siteUrl) return path;
  try {
    const origin = new URL(ctx.siteUrl);
    return origin.protocol === "https:" ? `${origin.origin}${path}` : path;
  } catch {
    return path;
  }
}

/** The full catalog of visitor-facing tasks this generator knows how to describe. Order is
 * preserved in `index.json`'s `skills` array for stable build output. */
export const AGENT_SKILLS: AgentSkillDefinition[] = [
  {
    name: "subscribe-feed",
    description: "Subscribe to this site's posts via RSS, Atom, or JSON Feed.",
    body: (ctx) =>
      `# Subscribe to this site's feed\n\n` +
      `Fetch one of the feeds below and parse it as the matching format to follow new posts on ` +
      `the visitor's behalf.\n\n` +
      `- RSS: ${absoluteOrRelative(ctx, "/rss.xml")}\n` +
      `- Atom: ${absoluteOrRelative(ctx, "/atom.xml")}\n` +
      `- JSON Feed: ${absoluteOrRelative(ctx, "/feed.json")}\n`,
  },
  {
    name: "send-webmention",
    description:
      "Notify this site of a link to one of its pages — for example a reply or mention — via the Webmention protocol.",
    body: (ctx) =>
      `# Send a Webmention\n\n` +
      `To notify this site that one of its pages was linked to (a reply, like, or mention), send ` +
      `a form-encoded POST request:\n\n` +
      "```\n" +
      `POST ${absoluteOrRelative(ctx, "/webmention")}\n` +
      `Content-Type: application/x-www-form-urlencoded\n\n` +
      `source=<url-that-links-to-target>&target=<url-on-this-site-being-mentioned>\n` +
      "```\n\n" +
      `The \`source\` URL must actually contain a link to \`target\`. This site verifies the link ` +
      `asynchronously; a successful submission returns \`202 Accepted\` and the mention appears ` +
      `once verified.\n`,
  },
  {
    name: "contact-site-owner",
    description: "Send a message to the site owner.",
    body: (ctx) =>
      `# Contact the site owner\n\n` +
      `Visit ${absoluteOrRelative(ctx, "/contact")} and complete the contact form on the visitor's ` +
      `behalf. Confirm the message content and any personal details (name, email) with the ` +
      `visitor before submitting — do not invent or submit values the visitor hasn't provided.\n`,
  },
  {
    name: "book-a-time",
    description: "Book a time with the site owner.",
    body: (ctx) =>
      `# Book a time\n\n` +
      `Visit ${absoluteOrRelative(ctx, "/book")} to view availability and schedule a meeting on ` +
      `the visitor's behalf. Confirm the selected date and time with the visitor before ` +
      `finalizing the booking.\n`,
  },
];

/** Which of `AGENT_SKILLS`' names are actually live for this build. `subscribe-feed` is
 * unconditional — every site has RSS/Atom/JSON Feed routes regardless of content. */
export function activeSkillNames(ctx: AgentSkillsContext): Set<string> {
  const names = new Set<string>(["subscribe-feed"]);
  if (ctx.webmentionEnabled) names.add("send-webmention");
  if (ctx.contactPageExists) names.add("contact-site-owner");
  if (ctx.bookingPageExists) names.add("book-a-time");
  return names;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/agent-skills.ts Resources/Template/scripts/agent-skills.test.ts
git commit -m "feat(#1579): agent-skills catalog and activation matrix"
```

---

### Task 3: `planAgentSkills` — pure planner

**Files:**
- Modify: `Resources/Template/scripts/agent-skills.ts`
- Modify: `Resources/Template/scripts/agent-skills.test.ts`

**Interfaces:**
- Consumes: `AGENT_SKILLS`, `activeSkillNames`, `buildSkillMarkdown`, `isAgentSkillsDocOwned`, `buildIndexJson`, `sha256Digest`, `AgentSkillsContext` from Tasks 1–2.
- Produces: `AgentSkillsWriteEntry { path: string; content: string }`, `AgentSkillsPlan { toWrite: AgentSkillsWriteEntry[]; toDelete: string[] }`, `planAgentSkills(ctx: AgentSkillsContext, existingSkillMdByName: Record<string, string | null>): AgentSkillsPlan`.

- [ ] **Step 1: Write the failing tests**

In `Resources/Template/scripts/agent-skills.test.ts`, add `planAgentSkills` to the existing top-of-file `import { ... } from "./agent-skills";` block (don't add a second import line for the same module), then append these tests:

```ts
const NOTHING_EXISTING: Record<string, string | null> = {
  "subscribe-feed": null,
  "send-webmention": null,
  "contact-site-owner": null,
  "book-a-time": null,
};

test("planAgentSkills: only-subscribe-feed context writes exactly index.json + one SKILL.md", () => {
  const plan = planAgentSkills(
    { siteUrl: undefined, webmentionEnabled: false, contactPageExists: false, bookingPageExists: false },
    NOTHING_EXISTING,
  );
  assert.deepEqual(
    plan.toWrite.map((e) => e.path).sort(),
    ["agent-skills/index.json", "agent-skills/subscribe-feed/SKILL.md"],
  );
  assert.deepEqual(plan.toDelete, []);
  const index = JSON.parse(plan.toWrite.find((e) => e.path === "agent-skills/index.json")!.content);
  assert.deepEqual(index.skills.map((s: { name: string }) => s.name), ["subscribe-feed"]);
});

test("planAgentSkills: full activation writes all four SKILL.md files plus the index, digests matching content", () => {
  const plan = planAgentSkills(
    { siteUrl: "https://example.com", webmentionEnabled: true, contactPageExists: true, bookingPageExists: true },
    NOTHING_EXISTING,
  );
  const docPaths = plan.toWrite.filter((e) => e.path.endsWith("SKILL.md")).map((e) => e.path);
  assert.deepEqual(docPaths.sort(), [
    "agent-skills/book-a-time/SKILL.md",
    "agent-skills/contact-site-owner/SKILL.md",
    "agent-skills/send-webmention/SKILL.md",
    "agent-skills/subscribe-feed/SKILL.md",
  ]);
  const index = JSON.parse(plan.toWrite.find((e) => e.path === "agent-skills/index.json")!.content);
  assert.equal(index.skills.length, 4);
  for (const entry of index.skills) {
    const doc = plan.toWrite.find((e) => e.path === `agent-skills/${entry.name}/SKILL.md`)!;
    assert.equal(entry.digest, sha256Digest(doc.content), `${entry.name}'s digest matches its own content`);
    assert.equal(entry.url, `/.well-known/agent-skills/${entry.name}/SKILL.md`);
  }
});

test("planAgentSkills: a skill that turns off deletes its marker-owned prior SKILL.md, leaves hand-authored content alone", () => {
  const priorOwned = buildSkillMarkdown(
    { name: "send-webmention", description: "old", body: () => "old body\n" },
    { siteUrl: undefined, webmentionEnabled: true, contactPageExists: false, bookingPageExists: false },
  );
  const turnedOff = planAgentSkills(
    { siteUrl: undefined, webmentionEnabled: false, contactPageExists: false, bookingPageExists: false },
    { ...NOTHING_EXISTING, "send-webmention": priorOwned },
  );
  assert.deepEqual(turnedOff.toDelete, ["agent-skills/send-webmention/SKILL.md"]);

  const handAuthored = planAgentSkills(
    { siteUrl: undefined, webmentionEnabled: false, contactPageExists: false, bookingPageExists: false },
    { ...NOTHING_EXISTING, "send-webmention": "hand-authored, not ours\n" },
  );
  assert.deepEqual(handAuthored.toDelete, []);
});

test("planAgentSkills: index.json is always the last toWrite entry", () => {
  const plan = planAgentSkills(
    { siteUrl: undefined, webmentionEnabled: false, contactPageExists: false, bookingPageExists: false },
    NOTHING_EXISTING,
  );
  assert.equal(plan.toWrite[plan.toWrite.length - 1].path, "agent-skills/index.json");
});
```

Add `buildSkillMarkdown` and `sha256Digest` to the existing `import { ... } from "./agent-skills";` line at the top of the test file if not already present (they were added in Task 1's import list already — just confirm).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: FAIL — `planAgentSkills` not exported yet.

- [ ] **Step 3: Write the minimal implementation**

Append to `Resources/Template/scripts/agent-skills.ts`:

```ts
export interface AgentSkillsWriteEntry {
  /** Relative to `.well-known/` — e.g. `"agent-skills/subscribe-feed/SKILL.md"`. */
  path: string;
  content: string;
}

export interface AgentSkillsPlan {
  toWrite: AgentSkillsWriteEntry[];
  /** `.well-known/`-relative `SKILL.md` paths whose skill turned off since the last build and
   * whose on-disk content is still this generator's own — safe to remove. */
  toDelete: string[];
}

/**
 * Decides what `/.well-known/agent-skills/` should look like for one build. Pure — no filesystem
 * access — so the activation matrix, digesting, and stale-removal rules are unit-testable without
 * touching disk, mirroring `planSecurityTxt`/`planAtprotoDid` in `edge-artifacts.ts`.
 *
 * `existingSkillMdByName` is each of the four known skills' current `agent-skills/<name>/SKILL.md`
 * content (or `null` if absent) — the caller reads this off disk. A skill that's active this build
 * is always (re)written regardless of what's already there (the same "always regenerate" rule
 * every other config-derived generator in this template follows); the map only matters for the
 * inactive-but-still-present case, to decide whether removal is safe (only this generator's own
 * prior output).
 */
export function planAgentSkills(
  ctx: AgentSkillsContext,
  existingSkillMdByName: Record<string, string | null>,
): AgentSkillsPlan {
  const active = activeSkillNames(ctx);
  const toWrite: AgentSkillsWriteEntry[] = [];
  const toDelete: string[] = [];
  const indexEntries: AgentSkillsIndexEntry[] = [];

  for (const skill of AGENT_SKILLS) {
    const path = `agent-skills/${skill.name}/SKILL.md`;
    if (active.has(skill.name)) {
      const content = buildSkillMarkdown(skill, ctx);
      toWrite.push({ path, content });
      indexEntries.push({
        name: skill.name,
        description: skill.description,
        url: `/.well-known/${path}`,
        digest: sha256Digest(content),
      });
    } else if (isAgentSkillsDocOwned(existingSkillMdByName[skill.name] ?? null)) {
      toDelete.push(path);
    }
  }

  toWrite.push({ path: "agent-skills/index.json", content: buildIndexJson(indexEntries) });
  return { toWrite, toDelete };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/agent-skills.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/agent-skills.ts Resources/Template/scripts/agent-skills.test.ts
git commit -m "feat(#1579): pure planAgentSkills planner"
```

---

### Task 4: `applyAgentSkillsPlan` + wire into `edge-artifacts.ts`

**Files:**
- Modify: `Resources/Template/scripts/agent-skills.ts`
- Modify: `Resources/Template/scripts/edge-artifacts.ts`
- Modify: `Resources/Template/.gitignore`

**Interfaces:**
- Consumes: `planAgentSkills`, `AgentSkillsContext`, `AGENT_SKILLS` from Task 3; `readConfig` from `./config` (already imported in `edge-artifacts.ts`); `existsSync`, `resolve` (already imported in `edge-artifacts.ts`).
- Produces: `applyAgentSkillsPlan(publicDir: string, ctx: AgentSkillsContext): void`, called from `edge-artifacts.ts`'s `main()`.

This task's apply function is impure (filesystem) and, matching this template's existing convention, is not unit-tested directly — only the pure `planAgentSkills` it delegates to is (Task 3). It's exercised for real when the generator script runs (Step 4 below).

- [ ] **Step 1: Add `applyAgentSkillsPlan` to `agent-skills.ts`**

Add these imports to the top of `Resources/Template/scripts/agent-skills.ts` (alongside the existing `import { createHash } from "node:crypto";`):

```ts
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
```

Append to the end of `Resources/Template/scripts/agent-skills.ts`:

```ts
/** Carries out `planAgentSkills`' decision: reads each known skill's current on-disk content,
 * plans, then writes/removes accordingly. Impure — the fs boundary `main()` calls into, mirroring
 * `applySecurityTxtPlan`/`applyAtprotoDidPlan` in `edge-artifacts.ts`. */
export function applyAgentSkillsPlan(publicDir: string, ctx: AgentSkillsContext): void {
  const wellKnownDir = resolve(publicDir, ".well-known");
  const existingSkillMdByName: Record<string, string | null> = {};
  for (const skill of AGENT_SKILLS) {
    const filePath = resolve(wellKnownDir, "agent-skills", skill.name, "SKILL.md");
    existingSkillMdByName[skill.name] = existsSync(filePath) ? readFileSync(filePath, "utf-8") : null;
  }

  const plan = planAgentSkills(ctx, existingSkillMdByName);

  for (const path of plan.toDelete) {
    rmSync(dirname(resolve(wellKnownDir, path)), { recursive: true, force: true });
    console.log(`Removed stale .well-known/${path}`);
  }
  for (const entry of plan.toWrite) {
    const filePath = resolve(wellKnownDir, entry.path);
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, entry.content, "utf-8");
    console.log(`Wrote public/.well-known/${entry.path}`);
  }
}
```

- [ ] **Step 2: Wire it into `edge-artifacts.ts`'s `main()`**

In `Resources/Template/scripts/edge-artifacts.ts`, add an import near the top (right after `import { readConfig } from "./config";`):

```ts
import { applyAgentSkillsPlan } from "./agent-skills";
```

In `main()`, immediately after the existing `applyStandardSitePublicationPlan(publicDir);` line (the last line before the closing `}` of `main()`), add:

```ts
  applyAgentSkillsPlan(publicDir, {
    siteUrl,
    webmentionEnabled: readConfig("WEBMENTION_RECEIVE_ENABLED") === "true",
    contactPageExists: existsSync(resolve(process.cwd(), "src/pages/contact.astro")),
    bookingPageExists: existsSync(resolve(process.cwd(), "src/pages/book.astro")),
  });
```

(`siteUrl`, `existsSync`, and `resolve` are all already in scope in `main()` / already imported at the top of `edge-artifacts.ts`.)

- [ ] **Step 3: Gitignore the generated subdirectory**

In `Resources/Template/.gitignore`, add a line under the existing "Generated at build by scripts/edge-artifacts.ts" block (after `public/.well-known/atproto-did`):

```
public/.well-known/agent-skills/
```

Unlike the single-file entries above it, this is a whole subdirectory: the exact set of `SKILL.md` files varies per site (which skills are active), so there's no fixed filename list to enumerate.

- [ ] **Step 4: Run the full JS test suite and a real generator invocation**

Run: `cd Resources/Template && npm test`
Expected: PASS — every existing suite plus `agent-skills.test.ts` green, nothing else broken.

Then smoke-test the wiring for real:

```bash
cd Resources/Template
mkdir -p /tmp/agent-skills-smoke/src/pages
cp -r . /tmp/agent-skills-smoke 2>/dev/null || true
cd /tmp/agent-skills-smoke
npx tsx scripts/edge-artifacts.ts
cat public/.well-known/agent-skills/index.json
cat public/.well-known/agent-skills/subscribe-feed/SKILL.md
rm -rf /tmp/agent-skills-smoke
```

Expected: `index.json` contains exactly one skill (`subscribe-feed` — no `.site-config`, no `src/pages/contact.astro`/`book.astro` in this scratch copy), and `subscribe-feed/SKILL.md` renders with root-relative feed URLs (no `SITE_URL` configured).

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/agent-skills.ts Resources/Template/scripts/edge-artifacts.ts Resources/Template/.gitignore
git commit -m "feat(#1579): generate the agent-skills manifest at build"
```

---

### Task 5: Build-verify seam — `well-known.ts`

**Files:**
- Modify: `Resources/Template/scripts/well-known.ts`
- Modify: `Resources/Template/scripts/well-known.test.ts`

**Interfaces:**
- Consumes: `isAgentSkillsDocOwned`, `isAgentSkillsIndexOwned` from `./agent-skills` (Task 1).

- [ ] **Step 1: Write the failing test**

In `Resources/Template/scripts/well-known.test.ts`, add `AGENT_SKILLS_MARKER` to the existing marker import and extend the marker-owned-artifact test. Change:

```ts
import { MTA_STS_MARKER, SECURITY_TXT_MARKER } from "./edge-artifacts";
```

to:

```ts
import { MTA_STS_MARKER, SECURITY_TXT_MARKER } from "./edge-artifacts";
import { AGENT_SKILLS_MARKER } from "./agent-skills";
```

Change the existing test:

```ts
test("runVerify: reports a marker-owned artifact separately so the host doesn't read it as unclaimed", (t) => {
  const root = scratch();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeFile(root, "dist/.well-known/security.txt", `${SECURITY_TXT_MARKER}\nContact: mailto:x@example.com\n`);
  writeFile(root, "dist/.well-known/mta-sts.txt", `version: STSv1\n${MTA_STS_MARKER}\n`);
  writeFile(root, "dist/.well-known/hand-written.txt", "not generated\n");
  writeFile(root, "manifest.json", JSON.stringify({ entries: [] }));
  const resultPath = join(root, "result.json");

  runVerify(root, { [MANIFEST_ENV_VAR]: join(root, "manifest.json"), [RESULT_PATH_ENV_VAR]: resultPath });

  const result = readSeamResult(resultPath);
  assert.deepEqual(result.observedArtifacts, ["hand-written.txt", "mta-sts.txt", "security.txt"]);
  assert.deepEqual(result.generatedArtifacts, ["mta-sts.txt", "security.txt"]);
});
```

to:

```ts
test("runVerify: reports a marker-owned artifact separately so the host doesn't read it as unclaimed", (t) => {
  const root = scratch();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeFile(root, "dist/.well-known/security.txt", `${SECURITY_TXT_MARKER}\nContact: mailto:x@example.com\n`);
  writeFile(root, "dist/.well-known/mta-sts.txt", `version: STSv1\n${MTA_STS_MARKER}\n`);
  writeFile(root, "dist/.well-known/hand-written.txt", "not generated\n");
  writeFile(root, "dist/.well-known/agent-skills/index.json", JSON.stringify({ generator: "anglesite", skills: [] }));
  writeFile(
    root,
    "dist/.well-known/agent-skills/subscribe-feed/SKILL.md",
    `---\nname: subscribe-feed\n---\n${AGENT_SKILLS_MARKER}\n`,
  );
  writeFile(root, "manifest.json", JSON.stringify({ entries: [] }));
  const resultPath = join(root, "result.json");

  runVerify(root, { [MANIFEST_ENV_VAR]: join(root, "manifest.json"), [RESULT_PATH_ENV_VAR]: resultPath });

  const result = readSeamResult(resultPath);
  assert.deepEqual(result.observedArtifacts, [
    "agent-skills/index.json",
    "agent-skills/subscribe-feed/SKILL.md",
    "hand-written.txt",
    "mta-sts.txt",
    "security.txt",
  ]);
  assert.deepEqual(result.generatedArtifacts, [
    "agent-skills/index.json",
    "agent-skills/subscribe-feed/SKILL.md",
    "mta-sts.txt",
    "security.txt",
  ]);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/well-known.test.ts`
Expected: FAIL — `result.generatedArtifacts`/`observedArtifacts` don't include the new `agent-skills/*` paths yet.

- [ ] **Step 3: Extend `isGeneratedArtifact` in `well-known.ts`**

In `Resources/Template/scripts/well-known.ts`, change the import:

```ts
import { isAtprotoDidOwned, isMTAStsMarkerOwned, isSecurityTxtMarkerOwned } from "./edge-artifacts";
```

to:

```ts
import { isAtprotoDidOwned, isMTAStsMarkerOwned, isSecurityTxtMarkerOwned } from "./edge-artifacts";
import { isAgentSkillsDocOwned, isAgentSkillsIndexOwned } from "./agent-skills";
```

Change the function body:

```ts
function isGeneratedArtifact(fullPath: string): boolean {
  let content: string;
  try {
    content = readFileSync(fullPath, "utf-8");
  } catch {
    return false;
  }
  return isSecurityTxtMarkerOwned(content) || isMTAStsMarkerOwned(content) || isAtprotoDidOwned(content);
}
```

to:

```ts
function isGeneratedArtifact(fullPath: string): boolean {
  let content: string;
  try {
    content = readFileSync(fullPath, "utf-8");
  } catch {
    return false;
  }
  return (
    isSecurityTxtMarkerOwned(content) ||
    isMTAStsMarkerOwned(content) ||
    isAtprotoDidOwned(content) ||
    isAgentSkillsIndexOwned(content) ||
    isAgentSkillsDocOwned(content)
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Resources/Template && npx tsx --test scripts/well-known.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/well-known.ts Resources/Template/scripts/well-known.test.ts
git commit -m "feat(#1579): recognize agent-skills output in the build-verify seam"
```

---

### Task 6: Host-side inventory classification — `WellKnownInventory.swift`

**Files:**
- Modify: `Sources/AnglesiteCore/WellKnownInventory.swift`
- Modify: `Tests/AnglesiteCoreTests/WellKnownInventoryTests.swift`

**Interfaces:**
- Produces: `GeneratedEndpoints.agentSkillsDocMarker: String`, `GeneratedEndpoints.isAgentSkillsIndexOwned(_:) -> Bool` (internal, mirrors the private `isValidAtprotoDid`/`isStandardSitePublicationURI` helpers), extends `GeneratedEndpoints.matching(content:suffix:)`.

- [ ] **Step 1: Write the failing tests**

In `Tests/AnglesiteCoreTests/WellKnownInventoryTests.swift`, add these two tests right after `atprotoDidClassifiesAsGenerated` (after line 88, before the `@Test("non-DID content at atproto-did is preserved as hand-authored")` test):

```swift
    @Test("a file whose content carries the agent-skills generator marker is classified generated")
    func agentSkillsIndexMarkerClassifiesAsGenerated() throws {
        let wellKnown = try makeWellKnownDirectory()
        defer { try? FileManager.default.removeItem(at: wellKnown.deletingLastPathComponent()) }
        let agentSkillsDir = wellKnown.appendingPathComponent("agent-skills")
        try FileManager.default.createDirectory(at: agentSkillsDir, withIntermediateDirectories: true)
        let content = #"{"$schema":"https://schemas.agentskills.io/discovery/0.2.0/schema.json","generator":"anglesite","skills":[]}"#
        try content.write(to: agentSkillsDir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        let (rows, _) = WellKnownInventory.scanUserStatic(wellKnownDirectory: wellKnown)
        #expect(rows.count == 1)
        #expect(rows[0].suffix == "agent-skills/index.json")
        #expect(rows[0].delivery == .generated)
        #expect(rows[0].owner == "generator:agent-skills")
    }

    @Test("a hand-authored file at agent-skills/index.json is preserved as user-static")
    func agentSkillsIndexHandAuthoredIsUserStatic() throws {
        let wellKnown = try makeWellKnownDirectory()
        defer { try? FileManager.default.removeItem(at: wellKnown.deletingLastPathComponent()) }
        let agentSkillsDir = wellKnown.appendingPathComponent("agent-skills")
        try FileManager.default.createDirectory(at: agentSkillsDir, withIntermediateDirectories: true)
        try #"{"schema":"other","skills":[]}"#.write(
            to: agentSkillsDir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)

        let (rows, _) = WellKnownInventory.scanUserStatic(wellKnownDirectory: wellKnown)
        #expect(rows.count == 1)
        #expect(rows[0].delivery == .userStatic)
    }

    @Test("a file whose content carries the agent-skills doc marker is classified generated")
    func agentSkillsDocMarkerClassifiesAsGenerated() throws {
        let wellKnown = try makeWellKnownDirectory()
        defer { try? FileManager.default.removeItem(at: wellKnown.deletingLastPathComponent()) }
        let skillDir = wellKnown.appendingPathComponent("agent-skills/subscribe-feed")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = "---\nname: subscribe-feed\ndescription: x\n---\n\(GeneratedEndpoints.agentSkillsDocMarker)\n\nBody.\n"
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let (rows, _) = WellKnownInventory.scanUserStatic(wellKnownDirectory: wellKnown)
        #expect(rows.count == 1)
        #expect(rows[0].suffix == "agent-skills/subscribe-feed/SKILL.md")
        #expect(rows[0].delivery == .generated)
        #expect(rows[0].owner == "generator:agent-skills")
    }
```

Then extend the drift-guard test `markersMatchTemplateSource` (around line 456–467) from:

```swift
    @Test("GeneratedEndpoints markers match the real edge-artifacts.ts source")
    func markersMatchTemplateSource() throws {
        // Tests/AnglesiteCoreTests/WellKnownInventoryTests.swift -> repo root -> Resources/Template/scripts
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/scripts/edge-artifacts.ts", isDirectory: false)
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(source.contains(GeneratedEndpoints.securityTxtMarker))
        #expect(source.contains(GeneratedEndpoints.mtaStsMarker))
    }
```

to add a sibling test right after it:

```swift
    @Test("GeneratedEndpoints markers match the real edge-artifacts.ts source")
    func markersMatchTemplateSource() throws {
        // Tests/AnglesiteCoreTests/WellKnownInventoryTests.swift -> repo root -> Resources/Template/scripts
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/scripts/edge-artifacts.ts", isDirectory: false)
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(source.contains(GeneratedEndpoints.securityTxtMarker))
        #expect(source.contains(GeneratedEndpoints.mtaStsMarker))
    }

    /// Same drift guard, for `agent-skills.ts`'s two ownership markers (#1579): the literal
    /// `AGENT_SKILLS_MARKER` string, and the `"generator": "anglesite"` field name/value pair
    /// `isAgentSkillsIndexOwned` on both sides checks for.
    @Test("GeneratedEndpoints' agent-skills markers match the real agent-skills.ts source")
    func agentSkillsMarkersMatchTemplateSource() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Template/scripts/agent-skills.ts", isDirectory: false)
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(source.contains(GeneratedEndpoints.agentSkillsDocMarker))
        #expect(source.contains("generator: \"anglesite\""))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WellKnownInventoryTests`
Expected: FAIL — `GeneratedEndpoints.agentSkillsDocMarker` doesn't exist yet; `agent-skills/index.json` and `agent-skills/.../SKILL.md` currently scan as `.userStatic`, not `.generated`.

- [ ] **Step 3: Extend `GeneratedEndpoints` in `WellKnownInventory.swift`**

In `Sources/AnglesiteCore/WellKnownInventory.swift`, add the marker constant and ownership check right after the existing `atprotoDidPattern`/`isValidAtprotoDid` block (after the closing `}` of `isValidAtprotoDid`, before `/// One Anglesite generator's identity...`):

```swift
    /// Mirrors `AGENT_SKILLS_MARKER` in `Resources/Template/scripts/agent-skills.ts`.
    /// `WellKnownInventoryTests` guards against the two drifting apart.
    public static let agentSkillsDocMarker =
        "<!-- Generated by Anglesite — do not edit; this file is regenerated from site config each build -->"

    /// True when `content` parses as JSON and its top-level `generator` field is `"anglesite"` —
    /// mirrors `isAgentSkillsIndexOwned` in `agent-skills.ts`. Safe under the Agent Skills
    /// Discovery RFC's "clients MUST ignore unrecognized fields" rule, the same way a literal
    /// first-line marker is safe for a plain-text format like `security.txt`.
    static func isAgentSkillsIndexOwned(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["generator"] as? String == "anglesite"
    }
```

Add the two descriptors right after `standardSitePublication`'s declaration:

```swift
    private static let standardSitePublication = Descriptor(
        owner: "generator:standard-site-publication", validatorID: nil,
        specificationURL: URL(string: "https://standard.site/docs/lexicons/publication")!,
        registration: .custom("community"))
    /// Both the index and each `SKILL.md` share one owner id — unlike security.txt/mta-sts.txt,
    /// which are genuinely separate protocols, these are two files from the same generator (#1579).
    private static let agentSkillsIndex = Descriptor(
        owner: "generator:agent-skills", validatorID: "agent-skills-discovery-rfc",
        specificationURL: URL(string: "https://github.com/cloudflare/agent-skills-discovery-rfc")!,
        registration: .custom("vendor-defined"))
    private static let agentSkillsDoc = Descriptor(
        owner: "generator:agent-skills", validatorID: "agent-skills-discovery-rfc",
        specificationURL: URL(string: "https://github.com/cloudflare/agent-skills-discovery-rfc")!,
        registration: .custom("vendor-defined"))
```

(Leave the original `standardSitePublication` declaration where it is — only add the two new ones after it.)

Extend `matching(content:suffix:)` — change:

```swift
    static func matching(content: String?, suffix: String) -> Descriptor? {
        guard let content else { return nil }
        if content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first == securityTxtMarker[...] {
            return securityTxt
        }
        if content.split(separator: "\n").contains(where: { $0 == mtaStsMarker[...] }) {
            return mtaSts
        }
        if suffix == "atproto-did", isValidAtprotoDid(content) {
            return atprotoDid
        }
        if isStandardSitePublicationURI(content) {
            return standardSitePublication
        }
        return nil
    }
```

to:

```swift
    static func matching(content: String?, suffix: String) -> Descriptor? {
        guard let content else { return nil }
        if content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first == securityTxtMarker[...] {
            return securityTxt
        }
        if content.split(separator: "\n").contains(where: { $0 == mtaStsMarker[...] }) {
            return mtaSts
        }
        if suffix == "atproto-did", isValidAtprotoDid(content) {
            return atprotoDid
        }
        if isStandardSitePublicationURI(content) {
            return standardSitePublication
        }
        if suffix == "agent-skills/index.json", isAgentSkillsIndexOwned(content) {
            return agentSkillsIndex
        }
        if suffix.hasPrefix("agent-skills/"), suffix.hasSuffix("/SKILL.md"),
           content.split(separator: "\n").contains(where: { $0 == agentSkillsDocMarker[...] }) {
            return agentSkillsDoc
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WellKnownInventoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WellKnownInventory.swift Tests/AnglesiteCoreTests/WellKnownInventoryTests.swift
git commit -m "feat(#1579): classify agent-skills in host-side inventory scan"
```

---

### Task 7: Flip the Agent Readiness catalog

**Files:**
- Modify: `Sources/AnglesiteCore/AgentReadinessReport.swift`
- Modify: `Tests/AnglesiteCoreTests/AgentReadinessScanningTests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/AnglesiteCoreTests/AgentReadinessScanningTests.swift`, add this test right after `linkHeadersMarkedProvided` (around line 130–133):

```swift
    @Test("catalog marks agentSkills as provided by the template (#1579 well-known agent-skills manifest)")
    func agentSkillsMarkedProvided() {
        #expect(AgentReadinessCatalog.checkInfo(for: "agentSkills").anglesiteProvides == true)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter AgentReadinessScanningTests`
Expected: FAIL — `agentSkills.anglesiteProvides` is still `false`.

- [ ] **Step 3: Flip the catalog entry**

In `Sources/AnglesiteCore/AgentReadinessReport.swift`, change:

```swift
        "agentSkills": .init(
            displayName: "Agent Skills manifest",
            passHint: "Your site publishes a manifest of tasks AI agents can perform for visitors.",
            failHint: "Your site doesn't publish a manifest of tasks AI agents can perform for visitors.",
            anglesiteProvides: false),
```

to:

```swift
        "agentSkills": .init(
            displayName: "Agent Skills manifest",
            passHint: "Your site publishes a manifest of tasks AI agents can perform for visitors.",
            failHint: "Your site doesn't publish a manifest of tasks AI agents can perform for visitors.",
            anglesiteProvides: true),
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter AgentReadinessScanningTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AgentReadinessReport.swift Tests/AnglesiteCoreTests/AgentReadinessScanningTests.swift
git commit -m "feat(#1579): flip agentSkills to anglesiteProvides"
```

---

### Task 8: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Run the full JS suite**

`Resources/Template/package.json` has no `lint`/`typecheck` scripts (that trio is `JS/edit-overlay/`'s recipe, a different subproject — `astro check` is folded into its own `build` script instead). For the template, run:

Run: `cd Resources/Template && npm test`
Expected: PASS, all tests green (includes the `agent-skills.test.ts`/`well-known.test.ts` suites from Tasks 1-5).

- [ ] **Step 2: Run the full Swift suite**

Run: `swift test --package-path .`
Expected: PASS (`AnglesiteCoreTests` at minimum; note the repo's known constraint that `AnglesiteAppTests`/`AnglesiteIntentsTests` only get real coverage under Xcode 27 locally, per `CONTRIBUTING.md`).

- [ ] **Step 3: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: PASS (confirms `AgentReadinessReport.swift`'s catalog change compiles cleanly into the app target that renders it).

- [ ] **Step 4: Re-read the diff against `CONTRIBUTING.md` before opening the PR**

Confirm: commit subjects ≤72 chars and conventional; PR body will use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan); PR body includes `Closes #1579`; no MCP schema change occurred so no paired `anglesite-skills` PR is needed (template-only, per `AGENTS.md` "Two-repo coordination").
