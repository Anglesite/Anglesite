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
