import test from "node:test";
import assert from "node:assert/strict";
import { buildFeedPaths, buildMcpConfigArtifact } from "./mcp-artifact.ts";

test("buildFeedPaths: includes root-level and per-collection feed formats", () => {
  const paths = buildFeedPaths();
  assert.ok(paths.includes("/rss.xml"));
  assert.ok(paths.includes("/atom.xml"));
  assert.ok(paths.includes("/feed.json"));
  assert.ok(paths.includes("/blog/rss.xml"));
  assert.ok(paths.includes("/blog/atom.xml"));
  assert.ok(paths.includes("/blog/feed.json"));
  assert.ok(paths.includes("/likes/feed.json"));
});

test("buildFeedPaths: exactly 3 root paths plus 3 per FEED_COLLECTIONS entry", () => {
  const paths = buildFeedPaths();
  // FEED_COLLECTIONS has 10 entries (blog, notes, articles, photos, albums, bookmarks, replies, likes, rsvps, checkins).
  assert.equal(paths.length, 3 + 10 * 3);
});

test("buildMcpConfigArtifact: enabled is true only when experimental.mcp === true", () => {
  assert.equal(buildMcpConfigArtifact({ version: 1 }).enabled, false);
  assert.equal(buildMcpConfigArtifact({ version: 1, experimental: { mcp: false } }).enabled, false);
  assert.equal(buildMcpConfigArtifact({ version: 1, experimental: { mcp: true } }).enabled, true);
});

test("buildMcpConfigArtifact: feedPaths matches buildFeedPaths()", () => {
  assert.deepEqual(buildMcpConfigArtifact({ version: 1 }).feedPaths, buildFeedPaths());
});
