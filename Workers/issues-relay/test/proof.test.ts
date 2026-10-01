import { describe, it, expect } from "vitest";
import { PROOF_PATH, fetchableHostname, proofValue, verifyDomainProof } from "../src/proof.js";

const SITE = "0f8fad5b-d9cb-469f-a165-70867728950e";
const KEY = "a".repeat(64);

/** A fetch that serves `body` at the proof URL and records what was requested. */
function serving(body: string, init: ResponseInit = {}) {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const impl = (async (url: string, reqInit?: RequestInit) => {
    calls.push({ url, init: reqInit });
    return new Response(body, init);
  }) as unknown as typeof fetch;
  return { impl, calls };
}

describe("proofValue", () => {
  it("matches the pinned cross-language vector (WorkerIssuesRelayTests pins the same one in Swift)", async () => {
    expect(await proofValue(SITE, KEY)).toBe("112a82a7c4ce77b6f898cef66ab3c08c1fd73f010d256f609f59057595bd535b");
  });
});

describe("verifyDomainProof", () => {
  it("accepts the site-bound hash of the key, fetched over https without following redirects", async () => {
    const { impl, calls } = serving(`${await proofValue(SITE, KEY)}\n`);
    expect(await verifyDomainProof("blog.example.com", SITE, KEY, impl)).toBe("ok");
    expect(calls[0]!.url).toBe(`https://blog.example.com${PROOF_PATH}`);
    expect(calls[0]!.init?.redirect).toBe("manual");
  });

  it("rejects a hash for another site or another key", async () => {
    const other = serving(await proofValue("7c9e6679-7425-40de-944b-e07fc1f90ae7", KEY));
    expect(await verifyDomainProof("blog.example.com", SITE, KEY, other.impl)).toBe("mismatch");
    const wrongKey = serving(await proofValue(SITE, "b".repeat(64)));
    expect(await verifyDomainProof("blog.example.com", SITE, KEY, wrongKey.impl)).toBe("mismatch");
  });

  it("treats redirects, 404s and oversized bodies as a mismatch, and 5xx or network errors as unreachable", async () => {
    expect(await verifyDomainProof("a.example.com", SITE, KEY, serving("", { status: 301, headers: { location: "https://x" } }).impl)).toBe("mismatch");
    expect(await verifyDomainProof("a.example.com", SITE, KEY, serving("nope", { status: 404 }).impl)).toBe("mismatch");
    expect(await verifyDomainProof("a.example.com", SITE, KEY, serving("x", { headers: { "content-length": "5000" } }).impl)).toBe("mismatch");
    expect(await verifyDomainProof("a.example.com", SITE, KEY, serving("", { status: 503 }).impl)).toBe("unreachable");
    const throwing = (async () => {
      throw new TypeError("network");
    }) as unknown as typeof fetch;
    expect(await verifyDomainProof("a.example.com", SITE, KEY, throwing)).toBe("unreachable");
  });

  it("never fetches a non-DNS hostname or a malformed key", async () => {
    const { impl, calls } = serving(await proofValue(SITE, KEY));
    for (const host of ["127.0.0.1", "localhost", "intranet", "a.localhost", "10.0.0.1", "[::1]", "x.123"]) {
      expect(await verifyDomainProof(host, SITE, KEY, impl)).toBe("mismatch");
    }
    expect(await verifyDomainProof("a.example.com", SITE, "short", impl)).toBe("mismatch");
    expect(calls).toHaveLength(0);
  });

  it.each([
    ["blog.dwk.io", true],
    ["a.b.example.co.uk", true],
    ["-bad.example.com", false],
    ["a..b.com", false],
  ])("fetchableHostname(%s) = %s", (host, ok) => {
    expect(fetchableHostname(host)).toBe(ok);
  });
});
