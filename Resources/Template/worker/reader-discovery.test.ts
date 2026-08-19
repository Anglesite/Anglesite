import { describe, expect, it } from "vitest";
import { discoverAuthorizationEndpoint } from "./reader-discovery.ts";

function htmlFetch(html: string, headers: Record<string, string> = {}): typeof fetch {
  return (async () =>
    new Response(html, {
      status: 200,
      headers: { "content-type": "text/html; charset=utf-8", ...headers },
    })) as unknown as typeof fetch;
}

describe("discoverAuthorizationEndpoint", () => {
  it("discovers via the Link header", async () => {
    const doFetch = htmlFetch("<html></html>", {
      link: '<https://alice.example/auth>; rel="authorization_endpoint"',
    });
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBe(
      "https://alice.example/auth",
    );
  });

  it("discovers via a <link rel> element when there is no Link header", async () => {
    const doFetch = htmlFetch(
      '<html><head><link rel="authorization_endpoint" href="https://alice.example/auth"></head></html>',
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBe(
      "https://alice.example/auth",
    );
  });

  it("discovers via an <a rel> element", async () => {
    const doFetch = htmlFetch(
      '<html><body><a rel="authorization_endpoint" href="/auth">sign in</a></body></html>',
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBe(
      "https://alice.example/auth",
    );
  });

  it("resolves a relative href against the document URL", async () => {
    const doFetch = htmlFetch(
      '<html><head><link rel="authorization_endpoint" href="/indieauth/authorize"></head></html>',
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/page", { fetch: doFetch })).toBe(
      "https://alice.example/indieauth/authorize",
    );
  });

  it("resolves against a <base href> when present", async () => {
    const doFetch = htmlFetch(
      '<html><head><base href="https://cdn.alice.example/"><link rel="authorization_endpoint" href="auth"></head></html>',
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBe(
      "https://cdn.alice.example/auth",
    );
  });

  it("prefers the Link header over an HTML link even when both are present", async () => {
    const doFetch = htmlFetch(
      '<html><head><link rel="authorization_endpoint" href="https://alice.example/from-html"></head></html>',
      { link: '<https://alice.example/from-header>; rel="authorization_endpoint"' },
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBe(
      "https://alice.example/from-header",
    );
  });

  it("returns null when no endpoint is declared anywhere", async () => {
    const doFetch = htmlFetch("<html><head></head><body>hello</body></html>");
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBeNull();
  });

  it("returns null for a non-HTML response with no Link header", async () => {
    const doFetch = (async () =>
      new Response("{}", { status: 200, headers: { "content-type": "application/json" } })) as unknown as typeof fetch;
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBeNull();
  });

  it("returns null (never throws) when the fetch itself fails", async () => {
    const doFetch = (async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBeNull();
  });

  it("returns null (never throws) when the target host is blocked on SSRF grounds", async () => {
    expect(await discoverAuthorizationEndpoint("http://127.0.0.1/", {})).toBeNull();
    expect(await discoverAuthorizationEndpoint("http://169.254.169.254/", {})).toBeNull();
  });

  it("ignores a rel value that only partially matches (e.g. a distinct token)", async () => {
    const doFetch = htmlFetch(
      '<html><head><link rel="not-authorization_endpoint" href="/nope"></head></html>',
    );
    expect(await discoverAuthorizationEndpoint("https://alice.example/", { fetch: doFetch })).toBeNull();
  });
});
