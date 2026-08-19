import { describe, expect, it } from "vitest";
import {
  READER_SESSION_COOKIE,
  createPkcePair,
  createReaderSessionToken,
  createSigninState,
  readReaderSessionCookie,
  readerSessionClearCookie,
  readerSessionSetCookie,
  verifyReaderSessionToken,
  verifySigninState,
} from "./reader-session.ts";

describe("createPkcePair", () => {
  it("generates a verifier matching RFC 7636's length/alphabet and a matching S256 challenge", async () => {
    const { verifier, challenge } = await createPkcePair();
    expect(verifier).toMatch(/^[A-Za-z0-9._~-]{43,128}$/);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    const expected = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    expect(challenge).toBe(expected);
  });

  it("generates distinct pairs on each call", async () => {
    const a = await createPkcePair();
    const b = await createPkcePair();
    expect(a.verifier).not.toBe(b.verifier);
  });
});

const SIGNING_KEY = "test-signing-key";

describe("createSigninState / verifySigninState", () => {
  const fields = {
    me: "https://alice.example/",
    redirectTo: "/notes/hello",
    authorizationEndpoint: "https://alice.example/auth",
    verifier: "a-verifier",
  };

  it("round-trips a valid state token", async () => {
    const token = await createSigninState(fields, SIGNING_KEY, 1_000);
    expect(await verifySigninState(token, SIGNING_KEY, 1_000)).toEqual({ v: 1, exp: 1_600, ...fields });
  });

  it("rejects an expired token", async () => {
    const token = await createSigninState(fields, SIGNING_KEY, 1_000);
    expect(await verifySigninState(token, SIGNING_KEY, 1_601)).toBeNull();
  });

  it("rejects a token signed with a different key", async () => {
    const token = await createSigninState(fields, SIGNING_KEY, 1_000);
    expect(await verifySigninState(token, "other-key", 1_000)).toBeNull();
  });

  it("rejects garbage input", async () => {
    expect(await verifySigninState("not-a-token", SIGNING_KEY)).toBeNull();
  });

  it("is not accepted as a reader session token (independent purposes)", async () => {
    const token = await createSigninState(fields, SIGNING_KEY, 1_000);
    expect(await verifyReaderSessionToken(token, SIGNING_KEY, 1_000)).toBeNull();
  });
});

describe("createReaderSessionToken / verifyReaderSessionToken", () => {
  it("round-trips a valid session token", async () => {
    const token = await createReaderSessionToken("alice.example", SIGNING_KEY, 1_000);
    expect(await verifyReaderSessionToken(token, SIGNING_KEY, 1_000)).toEqual({
      v: 1,
      exp: 1_000 + 2_592_000,
      me: "alice.example",
    });
  });

  it("rejects an expired session token", async () => {
    const token = await createReaderSessionToken("alice.example", SIGNING_KEY, 1_000);
    expect(await verifyReaderSessionToken(token, SIGNING_KEY, 1_000 + 2_592_001)).toBeNull();
  });

  it("rejects a token signed with a different key", async () => {
    const token = await createReaderSessionToken("alice.example", SIGNING_KEY, 1_000);
    expect(await verifyReaderSessionToken(token, "other-key", 1_000)).toBeNull();
  });
});

describe("cookie helpers", () => {
  it("readerSessionSetCookie produces a __Host- cookie with the expected attributes", () => {
    const value = readerSessionSetCookie("the-token");
    expect(value).toContain(`${READER_SESSION_COOKIE}=the-token`);
    expect(value).toContain("Path=/");
    expect(value).toContain("Secure");
    expect(value).toContain("HttpOnly");
    expect(value).toContain("SameSite=Lax");
    expect(value).toContain("Max-Age=2592000");
  });

  it("readerSessionClearCookie expires the cookie immediately", () => {
    expect(readerSessionClearCookie()).toContain("Max-Age=0");
  });

  it("readReaderSessionCookie extracts the value among other cookies", () => {
    const request = new Request("https://example.com/", {
      headers: { Cookie: `foo=bar; ${READER_SESSION_COOKIE}=the-token; baz=qux` },
    });
    expect(readReaderSessionCookie(request)).toBe("the-token");
  });

  it("readReaderSessionCookie returns null when absent", () => {
    const request = new Request("https://example.com/", { headers: { Cookie: "foo=bar" } });
    expect(readReaderSessionCookie(request)).toBeNull();
  });

  it("readReaderSessionCookie returns null when there is no Cookie header at all", () => {
    const request = new Request("https://example.com/");
    expect(readReaderSessionCookie(request)).toBeNull();
  });
});
