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
