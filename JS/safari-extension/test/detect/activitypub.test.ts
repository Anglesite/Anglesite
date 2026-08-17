// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectActivityPubLink } from "../../src/detect/activitypub";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectActivityPubLink", () => {
  it("finds an activity+json alternate link", () => {
    const doc = parse(
      `<html><head><link rel="alternate" type="application/activity+json" href="/actor"></head></html>`
    );
    expect(detectActivityPubLink(doc)).toBe("http://localhost:3000/actor");
  });

  it("returns null when absent", () => {
    const doc = parse(`<html><head></head></html>`);
    expect(detectActivityPubLink(doc)).toBeNull();
  });

  it("ignores activity+json links that aren't rel=alternate", () => {
    const doc = parse(`<html><head><link rel="me" type="application/activity+json" href="/x"></head></html>`);
    expect(detectActivityPubLink(doc)).toBeNull();
  });
});
