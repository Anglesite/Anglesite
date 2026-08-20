import test from "node:test";
import assert from "node:assert/strict";
import { assessIndieMark, type IndieMarkInputs } from "./indiemark.ts";

const baseInputs: IndieMarkInputs = {
  hasProfile: false,
  postTypeCounts: {},
  homeIndexable: false,
  webmentionReceiveEnabled: false,
  micropubEnabled: false,
  websubEnabled: false,
  hasSyndicatedPosts: false,
};

test("assessIndieMark: returns exactly 13 axes in a fixed order", () => {
  const results = assessIndieMark(baseInputs);
  assert.equal(results.length, 13);
  assert.deepEqual(
    results.map((r) => r.axis),
    [
      "Identity",
      "Posts",
      "Search discoverability",
      "Webmention (receiving)",
      "Micropub",
      "WebSub",
      "Syndication (POSSE)",
      "Authentication (IndieAuth)",
      "Aggregation (Microsub)",
      "Handling responses (ActivityPub)",
      "Security (HTTPS)",
      "Own-site search backend",
      "Microformats2 markup",
    ],
  );
});

test("assessIndieMark: identity — no profile.json", () => {
  const [identity] = assessIndieMark(baseInputs);
  assert.equal(identity.basis, "detected");
  assert.equal(identity.present, false);
  assert.equal(identity.label, "Not set up on this site yet");
  assert.match(identity.detail, /No src\/data\/profile\.json/);
});

test("assessIndieMark: identity — profile.json present", () => {
  const [identity] = assessIndieMark({ ...baseInputs, hasProfile: true });
  assert.equal(identity.present, true);
  assert.equal(identity.label, "Detected on this site");
  assert.match(identity.detail, /publishes an h-card/);
});

test("assessIndieMark: posts — no post-type collections have entries", () => {
  const [, posts] = assessIndieMark(baseInputs);
  assert.equal(posts.basis, "detected");
  assert.equal(posts.present, false);
  assert.match(posts.detail, /No posts yet/);
});

test("assessIndieMark: posts — lists each active post type by name, in collection order", () => {
  const [, posts] = assessIndieMark({
    ...baseInputs,
    postTypeCounts: { blog: 0, notes: 3, articles: 0, photos: 1, albums: 0, bookmarks: 0, replies: 0, likes: 0 },
  });
  assert.equal(posts.present, true);
  assert.equal(posts.detail, "Publishing 2 post types: notes, photos.");
});

test("assessIndieMark: posts — singular wording for exactly one active type", () => {
  const [, posts] = assessIndieMark({
    ...baseInputs,
    postTypeCounts: { blog: 1, notes: 0, articles: 0, photos: 0, albums: 0, bookmarks: 0, replies: 0, likes: 0 },
  });
  assert.equal(posts.detail, "Publishing 1 post type: blog posts.");
});

test("assessIndieMark: search discoverability — noindexed home page", () => {
  const [, , search] = assessIndieMark(baseInputs);
  assert.equal(search.present, false);
  assert.match(search.detail, /marked noindex/);
});

test("assessIndieMark: search discoverability — indexable home page", () => {
  const [, , search] = assessIndieMark({ ...baseInputs, homeIndexable: true });
  assert.equal(search.present, true);
  assert.match(search.detail, /is indexable/);
});

test("assessIndieMark: webmention receiving reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[3];
  const on = assessIndieMark({ ...baseInputs, webmentionReceiveEnabled: true })[3];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(off.detail, /WEBMENTION_RECEIVE_ENABLED/);
  assert.match(on.detail, /WEBMENTION_RECEIVE_ENABLED/);
});

test("assessIndieMark: micropub reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[4];
  const on = assessIndieMark({ ...baseInputs, micropubEnabled: true })[4];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(on.detail, /MICROPUB_ENABLED/);
});

test("assessIndieMark: websub reflects the input flag", () => {
  const off = assessIndieMark(baseInputs)[5];
  const on = assessIndieMark({ ...baseInputs, websubEnabled: true })[5];
  assert.equal(off.present, false);
  assert.equal(on.present, true);
  assert.match(on.detail, /WEBSUB_ENABLED/);
});

test("assessIndieMark: syndication (POSSE) reflects hasSyndicatedPosts", () => {
  const off = assessIndieMark(baseInputs)[6];
  const on = assessIndieMark({ ...baseInputs, hasSyndicatedPosts: true })[6];
  assert.equal(off.basis, "detected");
  assert.equal(off.present, false);
  assert.match(off.detail, /No posts have recorded POSSE/);
  assert.equal(on.present, true);
  assert.match(on.detail, /has been POSSEd/);
});

test("assessIndieMark: the six platform-supported axes are fixed regardless of inputs", () => {
  const withNothing = assessIndieMark(baseInputs).slice(7);
  const withEverything = assessIndieMark({
    hasProfile: true,
    postTypeCounts: { blog: 5, notes: 5, articles: 5, photos: 5, albums: 5, bookmarks: 5, replies: 5, likes: 5 },
    homeIndexable: true,
    webmentionReceiveEnabled: true,
    micropubEnabled: true,
    websubEnabled: true,
    hasSyndicatedPosts: true,
  }).slice(7);
  assert.deepEqual(withNothing, withEverything);
  for (const axis of withNothing) {
    assert.equal(axis.basis, "supported");
    assert.equal(axis.present, undefined);
  }
});

test("assessIndieMark: platform-supported axes name the gating mechanism", () => {
  const supported = assessIndieMark(baseInputs).slice(7);
  assert.match(supported[0].detail, /IndieAuth/);
  assert.match(supported[0].detail, /Worker secrets/);
  assert.match(supported[1].detail, /Microsub/);
  assert.match(supported[2].detail, /ActivityPub/);
  assert.match(supported[3].detail, /HTTPS/);
  assert.match(supported[4].detail, /Pagefind/);
  assert.match(supported[5].detail, /microformats2/i);
});
