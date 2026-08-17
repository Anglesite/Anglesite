// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { detectWebmentionLinkTag } from "../../src/detect/webmention";

function parse(html: string): Document {
  return new DOMParser().parseFromString(html, "text/html");
}

describe("detectWebmentionLinkTag", () => {
  it("finds a link[rel=webmention]", () => {
    const doc = parse(`<html><head><link rel="webmention" href="/webmention"></head></html>`);
    expect(detectWebmentionLinkTag(doc)).toBe("http://localhost:3000/webmention");
  });

  it("finds an a[rel=webmention] in the body", () => {
    const doc = parse(`<html><body><a rel="webmention" href="/wm">webmention</a></body></html>`);
    expect(detectWebmentionLinkTag(doc)).toBe("http://localhost:3000/wm");
  });

  it("returns null when absent", () => {
    const doc = parse(`<html><head></head><body></body></html>`);
    expect(detectWebmentionLinkTag(doc)).toBeNull();
  });
});
