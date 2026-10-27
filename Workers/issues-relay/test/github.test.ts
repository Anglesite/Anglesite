import { describe, it, expect } from "vitest";
import { GitHubClient, appJWT } from "../src/github.js";

async function rsaKey() {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

function decode(part: string): Uint8Array {
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (c) => c.charCodeAt(0));
}

describe("appJWT", () => {
  it("is an RS256 JWT for the App, backdated for skew and valid under GitHub's 10-minute cap", async () => {
    const { pem, publicKey } = await rsaKey();
    const jwt = await appJWT("12345", pem, 1_000_000_000_000);
    const [header, payload, signature] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(decode(header!)))).toEqual({ alg: "RS256", typ: "JWT" });
    expect(JSON.parse(new TextDecoder().decode(decode(payload!)))).toEqual({
      iat: 1_000_000_000 - 60,
      exp: 1_000_000_000 + 540,
      iss: "12345",
    });
    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      decode(signature!),
      new TextEncoder().encode(`${header}.${payload}`),
    );
    expect(valid).toBe(true);
  });

  it("explains how to convert a PKCS#1 key instead of failing obscurely", async () => {
    await expect(appJWT("1", "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----", 0)).rejects.toThrow(
      /openssl pkcs8/,
    );
  });
});

describe("GitHubClient", () => {
  it("mints one installation token and reuses it across calls", async () => {
    const { pem } = await rsaKey();
    const calls: Array<{ url: string; method: string; auth: string | null }> = [];
    const fakeFetch = (async (url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      calls.push({ url, method: init.method ?? "GET", auth: headers.get("authorization") });
      if (url.endsWith("/access_tokens")) {
        return Response.json({ token: "inst-token", expires_at: new Date(2_000_000_000_000).toISOString() });
      }
      return Response.json({ number: 7, state: "open", html_url: "u", labels: [{ name: "pkg:webmention" }] });
    }) as unknown as typeof fetch;

    const client = new GitHubClient({ appId: "1", installationId: "99", privateKeyPem: pem, fetch: fakeFetch, now: () => 1_000_000_000_000 });
    expect(await client.getIssue("davidwkeith/workers", 7)).toEqual({ number: 7, state: "open", html_url: "u", labels: ["pkg:webmention"] });
    await client.comment("davidwkeith/workers", 7, "hi");

    expect(calls.map((c) => `${c.method} ${c.url}`)).toEqual([
      "POST https://api.github.com/app/installations/99/access_tokens",
      "GET https://api.github.com/repos/davidwkeith/workers/issues/7",
      "POST https://api.github.com/repos/davidwkeith/workers/issues/7/comments",
    ]);
    expect(calls[1]!.auth).toBe("Bearer inst-token");
    expect(calls[0]!.auth).toMatch(/^Bearer ey/);
  });

  it("surfaces a non-2xx response as an error", async () => {
    const { pem } = await rsaKey();
    const fakeFetch = (async (url: string) =>
      url.endsWith("/access_tokens")
        ? Response.json({ token: "t", expires_at: new Date(2_000_000_000_000).toISOString() })
        : new Response("nope", { status: 403 })) as unknown as typeof fetch;
    const client = new GitHubClient({ appId: "1", installationId: "9", privateKeyPem: pem, fetch: fakeFetch, now: () => 0 });
    await expect(client.getIssue("o/r", 1)).rejects.toThrow("403");
  });
});
