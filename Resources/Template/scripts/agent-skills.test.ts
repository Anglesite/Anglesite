import test from "node:test";
import assert from "node:assert/strict";
import {
  AGENT_SKILLS,
  AGENT_SKILLS_MARKER,
  activeSkillNames,
  buildIndexJson,
  buildSkillMarkdown,
  isAgentSkillsDocOwned,
  isAgentSkillsIndexOwned,
  isValidSkillName,
  sha256Digest,
  planAgentSkills,
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

test("AGENT_SKILLS bodies: usable HTTPS siteUrl renders absolute URLs", () => {
  const httpsCtx: AgentSkillsContext = {
    siteUrl: "https://example.com",
    webmentionEnabled: true,
    contactPageExists: true,
    bookingPageExists: true,
  };

  const subscribeFeed = AGENT_SKILLS.find((s) => s.name === "subscribe-feed")!;
  const feedBody = subscribeFeed.body(httpsCtx);
  assert.match(feedBody, /https:\/\/example\.com\/rss\.xml/);
  assert.match(feedBody, /https:\/\/example\.com\/atom\.xml/);
  assert.match(feedBody, /https:\/\/example\.com\/feed\.json/);

  const sendWebmention = AGENT_SKILLS.find((s) => s.name === "send-webmention")!;
  const webmentionBody = sendWebmention.body(httpsCtx);
  assert.match(webmentionBody, /POST https:\/\/example\.com\/webmention/);

  const contactOwner = AGENT_SKILLS.find((s) => s.name === "contact-site-owner")!;
  const contactBody = contactOwner.body(httpsCtx);
  assert.match(contactBody, /https:\/\/example\.com\/contact/);

  const bookTime = AGENT_SKILLS.find((s) => s.name === "book-a-time")!;
  const bookBody = bookTime.body(httpsCtx);
  assert.match(bookBody, /https:\/\/example\.com\/book/);
});

test("AGENT_SKILLS bodies: undefined siteUrl renders root-relative paths", () => {
  const noUrlCtx: AgentSkillsContext = {
    siteUrl: undefined,
    webmentionEnabled: true,
    contactPageExists: true,
    bookingPageExists: true,
  };

  const subscribeFeed = AGENT_SKILLS.find((s) => s.name === "subscribe-feed")!;
  const feedBody = subscribeFeed.body(noUrlCtx);
  assert.match(feedBody, /\/rss\.xml/);
  assert.match(feedBody, /\/atom\.xml/);
  assert.match(feedBody, /\/feed\.json/);
  assert.doesNotMatch(feedBody, /https?:\/\//);

  const sendWebmention = AGENT_SKILLS.find((s) => s.name === "send-webmention")!;
  const webmentionBody = sendWebmention.body(noUrlCtx);
  assert.match(webmentionBody, /POST \/webmention/);
  assert.doesNotMatch(webmentionBody, /https?:\/\//);

  const contactOwner = AGENT_SKILLS.find((s) => s.name === "contact-site-owner")!;
  const contactBody = contactOwner.body(noUrlCtx);
  assert.match(contactBody, /\/contact/);
  assert.doesNotMatch(contactBody, /https?:\/\//);

  const bookTime = AGENT_SKILLS.find((s) => s.name === "book-a-time")!;
  const bookBody = bookTime.body(noUrlCtx);
  assert.match(bookBody, /\/book/);
  assert.doesNotMatch(bookBody, /https?:\/\//);
});

test("AGENT_SKILLS bodies: non-HTTPS siteUrl falls back to relative paths", () => {
  const httpCtx: AgentSkillsContext = {
    siteUrl: "http://example.com",
    webmentionEnabled: true,
    contactPageExists: true,
    bookingPageExists: true,
  };

  const subscribeFeed = AGENT_SKILLS.find((s) => s.name === "subscribe-feed")!;
  const feedBody = subscribeFeed.body(httpCtx);
  assert.match(feedBody, /\/rss\.xml/);
  assert.doesNotMatch(feedBody, /http:\/\/example\.com/);

  const sendWebmention = AGENT_SKILLS.find((s) => s.name === "send-webmention")!;
  const webmentionBody = sendWebmention.body(httpCtx);
  assert.match(webmentionBody, /POST \/webmention/);
  assert.doesNotMatch(webmentionBody, /http:\/\/example\.com/);

  const contactOwner = AGENT_SKILLS.find((s) => s.name === "contact-site-owner")!;
  const contactBody = contactOwner.body(httpCtx);
  assert.match(contactBody, /\/contact/);
  assert.doesNotMatch(contactBody, /http:\/\/example\.com/);

  const bookTime = AGENT_SKILLS.find((s) => s.name === "book-a-time")!;
  const bookBody = bookTime.body(httpCtx);
  assert.match(bookBody, /\/book/);
  assert.doesNotMatch(bookBody, /http:\/\/example\.com/);
});

test("AGENT_SKILLS bodies: invalid siteUrl falls back gracefully to relative paths", () => {
  const invalidCtx: AgentSkillsContext = {
    siteUrl: "not a url",
    webmentionEnabled: true,
    contactPageExists: true,
    bookingPageExists: true,
  };

  const subscribeFeed = AGENT_SKILLS.find((s) => s.name === "subscribe-feed")!;
  assert.doesNotThrow(() => {
    const feedBody = subscribeFeed.body(invalidCtx);
    assert.match(feedBody, /\/rss\.xml/);
    assert.doesNotMatch(feedBody, /not a url/);
  });

  const sendWebmention = AGENT_SKILLS.find((s) => s.name === "send-webmention")!;
  assert.doesNotThrow(() => {
    const webmentionBody = sendWebmention.body(invalidCtx);
    assert.match(webmentionBody, /POST \/webmention/);
    assert.doesNotMatch(webmentionBody, /not a url/);
  });

  const contactOwner = AGENT_SKILLS.find((s) => s.name === "contact-site-owner")!;
  assert.doesNotThrow(() => {
    const contactBody = contactOwner.body(invalidCtx);
    assert.match(contactBody, /\/contact/);
    assert.doesNotMatch(contactBody, /not a url/);
  });

  const bookTime = AGENT_SKILLS.find((s) => s.name === "book-a-time")!;
  assert.doesNotThrow(() => {
    const bookBody = bookTime.body(invalidCtx);
    assert.match(bookBody, /\/book/);
    assert.doesNotMatch(bookBody, /not a url/);
  });
});

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
