import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { decidePublish, MAX_REASON_LENGTH, publishIssues, scannableContent, writerReason, type PublishPolicyEvent } from "./policy";
import plugin from "./plugin";

const here = dirname(fileURLToPath(import.meta.url));

/** A Portable Text body the way EmDash stores one: blocks of spans, links in `markDefs`. */
function article(body: unknown[], extra: Record<string, unknown> = {}): PublishPolicyEvent {
  return {
    collection: "posts",
    content: { slug: "council-vote", data: { title: "Council approves budget", body, ...extra } },
  };
}

function paragraph(text: string, markDefs: unknown[] = []): unknown {
  return {
    _type: "block",
    _key: "b1",
    style: "normal",
    markDefs,
    children: [{ _type: "span", _key: "s1", text, marks: markDefs.map((m) => (m as { _key: string })._key) }],
  };
}

test("a clean article publishes", () => {
  const event = article([
    paragraph("The council voted 5–2 on Tuesday.", [{ _type: "link", _key: "l1", href: "https://example.gov/minutes" }]),
    { _type: "image", _key: "i1", url: "https://media.example-news.org/council.jpg", alt: "Council chamber" },
  ]);
  assert.equal(decidePublish(event), undefined);
});

test("an email address in body text blocks publishing", () => {
  const decision = decidePublish(article([paragraph("Tips to reporter@example-news.org")]));
  assert.ok(decision);
  assert.match(decision.reason, /email address/);
});

test("a mailto link whose text isn't the address still publishes", () => {
  // Same rule as the deploy scan: a mailto: target is published intent, not accidental exposure.
  const event = article([
    paragraph("Email the newsroom", [{ _type: "link", _key: "l1", href: "mailto:tips@example-news.org" }]),
  ]);
  assert.equal(decidePublish(event), undefined);
});

test("a secret in any field blocks publishing", () => {
  // Built at runtime and vendor-neutral, so it matches the gate's generic pattern without looking
  // like a real provider's key to secret scanners.
  const decision = decidePublish(article([paragraph("fine")], { notes: `api_key: ${"x".repeat(24)}` }));
  assert.ok(decision);
  assert.match(decision.reason, /API key/);
});

test("a phone number blocks publishing", () => {
  assert.match(decidePublish(article([paragraph("Call 555-867-5309")]))?.reason ?? "", /phone number/);
});

test("a social-network media hotlink blocks publishing; a permalink to the post does not", () => {
  const hotlinked = article([{ _type: "image", _key: "i1", url: "https://pbs.twimg.com/media/abc.jpg" }]);
  assert.match(decidePublish(hotlinked)?.reason ?? "", /upload the file instead/);

  const cited = article([
    paragraph("As posted", [{ _type: "link", _key: "l1", href: "https://pbs.twimg.com/media/abc.jpg" }]),
  ]);
  assert.equal(decidePublish(cited), undefined);
});

test("an http:// media URL blocks publishing (warnings block, as in build:ci --strict)", () => {
  const decision = decidePublish(article([{ _type: "image", _key: "i1", url: "http://media.example-news.org/a.jpg" }]));
  assert.match(decision?.reason ?? "", /https:\/\//);
});

test("markup typed into prose is text, not a resource reference", () => {
  // A rendered page entity-encodes this, so the deploy scan wouldn't flag it either.
  assert.equal(decidePublish(article([paragraph('Use src="http://example.com/x.png" in HTML')])), undefined);
});

test("a contacts-only entry is refused", () => {
  const decision = decidePublish(article([paragraph("Members only")], { visibility: "contacts" }));
  assert.match(decision?.reason ?? "", /contacts only/);
});

test("Portable Text bookkeeping keys are never scanned", () => {
  // Shaped to trip the phone and AWS-key patterns if these keys were scanned; built at runtime so
  // secret scanners don't mistake the fixture for a real key.
  const { text, html } = scannableContent({ _key: "5558675309", _ref: `image-${"AKIA"}${"A".repeat(16)}`, body: [] });
  assert.equal(text, "");
  assert.equal(html, "");
});

test("each problem is named once, and the reason fits EmDash's 500-character limit", () => {
  const issues = publishIssues(article([paragraph("a@b.co and c@d.co, 555-867-5309")]));
  const reason = writerReason(issues);
  assert.equal(reason.match(/email address/g)?.length, 1);

  const many = Array.from({ length: 40 }, (_, i) => ({ severity: "error" as const, category: `other-${i}`, message: "x".repeat(30) }));
  const long = writerReason(many);
  assert.ok(long.length <= MAX_REASON_LENGTH);
  assert.ok(long.length >= 1);
  assert.doesNotMatch(long, /[\n<>]/);
});

test("the plugin gates publish and schedule, and never unpublish", async () => {
  const hooks = plugin.hooks as Record<string, (event: PublishPolicyEvent) => Promise<unknown>>;
  const dirty = article([paragraph("reporter@example-news.org")]);
  assert.ok(await hooks["content:beforePublish"](dirty));
  assert.ok(await hooks["content:beforeSchedule"](dirty));
  assert.equal(await hooks["content:beforePublish"](article([paragraph("fine")])), undefined);
  // Corrections and takedowns must always be possible.
  assert.equal("content:beforeUnpublish" in hooks, false);
});

test("the plugin's files stay runtime-neutral for EmDash's sandbox", async () => {
  for (const name of ["policy.ts", "plugin.ts"]) {
    const source = await readFile(join(here, name), "utf-8");
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    assert.doesNotMatch(code, /["']node:/, name);
    assert.doesNotMatch(code, /\bprocess\./, name);
    assert.doesNotMatch(code, /\brequire\s*\(/, name);
    for (const [, specifier] of code.matchAll(/\bfrom\s+["']([^"']+)["']/g)) {
      assert.match(specifier, /^\.\.?\//, `${name} imports only local modules, got ${specifier}`);
    }
  }
});
