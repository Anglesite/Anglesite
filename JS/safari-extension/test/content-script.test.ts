// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { collectFindings } from "../src/content-script";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("collectFindings", () => {
  it("assembles feeds, webmention, ActivityPub, rel=me, and h-card into one Findings object", () => {
    const doc = parse(`
      <html><head>
        <title>Example</title>
        <link rel="alternate" type="application/rss+xml" href="/feed.rss">
        <link rel="webmention" href="/webmention">
        <link rel="alternate" type="application/activity+json" href="/actor">
      </head><body>
        <a rel="me" href="https://fosstodon.org/@example">Mastodon</a>
        <div class="h-card"><span class="p-name">Example Person</span></div>
      </body></html>
    `);
    const findings = collectFindings(doc);
    expect(findings.pageTitle).toBe("Example");
    expect(findings.feeds).toHaveLength(1);
    expect(findings.webmentionUrl).toBe("http://localhost:3000/webmention");
    expect(findings.activityPubUrl).toBe("http://localhost:3000/actor");
    expect(findings.relMeLinks).toEqual(["https://fosstodon.org/@example"]);
    expect(findings.hCard?.properties.name).toEqual(["Example Person"]);
    expect(findings.mf2TypeCounts["h-card"]).toBe(1);
  });

  it("returns empty/null fields for a page with nothing detectable", () => {
    const doc = parse(`<html><head><title>Blank</title></head><body></body></html>`);
    const findings = collectFindings(doc);
    expect(findings.feeds).toEqual([]);
    expect(findings.webmentionUrl).toBeNull();
    expect(findings.activityPubUrl).toBeNull();
    expect(findings.relMeLinks).toEqual([]);
    expect(findings.hCard).toBeNull();
  });
});
