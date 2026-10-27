import { test } from "node:test";
import assert from "node:assert/strict";
import { ARTICLE_CACHE_MAX_AGE_SECONDS, articleCacheOptions, workerCacheEnabled } from "./worker-cache.ts";

// The shape `EmDashWorkerConfig.toml(workerName:resources:cache:)` writes.
const config = (enabled: string) => `name = "news"
main = "./src/worker.ts"

[observability]
enabled = true

[cache]
enabled = ${enabled}

[triggers]
crons = ["* * * * *"]
`;

test("the cache is on only when the Worker config's [cache] table says so", () => {
  assert.equal(workerCacheEnabled(config("true")), true);
  assert.equal(workerCacheEnabled(config("false")), false);
});

test("no Worker config, or one without a [cache] table, leaves the cache off", () => {
  assert.equal(workerCacheEnabled(undefined), false);
  assert.equal(workerCacheEnabled(""), false);
  // `[observability] enabled = true` is not the cache.
  assert.equal(workerCacheEnabled('name = "news"\n\n[observability]\nenabled = true\n'), false);
});

test("a comment or an unexpected value doesn't turn the cache on", () => {
  assert.equal(workerCacheEnabled("[cache]\n# enabled = true\n"), false);
  assert.equal(workerCacheEnabled('[cache]\nenabled = "true"\n'), false);
  assert.equal(workerCacheEnabled("[cache]\nenabled = true # on\n"), true);
  assert.equal(workerCacheEnabled("[cache.exports]\nenabled = true\n"), false);
});

test("an article page keeps EmDash's tags and adds a max-age", () => {
  const lastModified = new Date("2026-10-01T00:00:00Z");
  assert.deepEqual(articleCacheOptions({ tags: ["01J"], lastModified }), {
    tags: ["01J"], lastModified, maxAge: ARTICLE_CACHE_MAX_AGE_SECONDS,
  });
  assert.deepEqual(articleCacheOptions(undefined), { maxAge: ARTICLE_CACHE_MAX_AGE_SECONDS });
});
