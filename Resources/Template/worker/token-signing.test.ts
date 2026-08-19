import { describe, expect, it } from "vitest";
import { base64url, decodeBase64url, deriveKey, signPayload, verifyPayload } from "./token-signing.ts";

describe("base64url / decodeBase64url", () => {
  it("round-trips arbitrary bytes without padding or unsafe characters", () => {
    const bytes = new Uint8Array([0, 1, 2, 251, 252, 253, 254, 255]);
    const encoded = base64url(bytes);
    expect(encoded).not.toMatch(/[+/=]/);
    expect(decodeBase64url(encoded)).toEqual(bytes);
  });

  it("returns null for an invalid encoding", () => {
    expect(decodeBase64url("not base64url!!")).toBeNull();
  });
});

describe("deriveKey", () => {
  it("derives independent subkeys per purpose from the same secret", async () => {
    const a = await deriveKey("secret", "purpose-a");
    const b = await deriveKey("secret", "purpose-b");
    const payload = new TextEncoder().encode("hello");
    const sigA = await crypto.subtle.sign("HMAC", a, payload);
    expect(await crypto.subtle.verify("HMAC", b, sigA, payload)).toBe(false);
  });
});

describe("signPayload / verifyPayload", () => {
  it("round-trips a JSON payload through sign and verify", async () => {
    const payload = new TextEncoder().encode(JSON.stringify({ hello: "world" }));
    const token = await signPayload(payload, "secret", "test-purpose");
    const decoded = await verifyPayload(token, "secret", "test-purpose");
    expect(decoded).toEqual({ hello: "world" });
  });

  it("rejects a token signed under a different purpose", async () => {
    const payload = new TextEncoder().encode(JSON.stringify({ hello: "world" }));
    const token = await signPayload(payload, "secret", "purpose-a");
    expect(await verifyPayload(token, "secret", "purpose-b")).toBeNull();
  });

  it("rejects a token signed with a different secret", async () => {
    const payload = new TextEncoder().encode(JSON.stringify({ hello: "world" }));
    const token = await signPayload(payload, "secret-a", "test-purpose");
    expect(await verifyPayload(token, "secret-b", "test-purpose")).toBeNull();
  });

  it("rejects a tampered payload", async () => {
    const payload = new TextEncoder().encode(JSON.stringify({ hello: "world" }));
    const token = await signPayload(payload, "secret", "test-purpose");
    const [, signature] = token.split(".");
    const tampered = `${base64url(new TextEncoder().encode(JSON.stringify({ hello: "tampered" })))}.${signature}`;
    expect(await verifyPayload(tampered, "secret", "test-purpose")).toBeNull();
  });

  it("rejects a malformed token", async () => {
    expect(await verifyPayload("not-a-token", "secret", "test-purpose")).toBeNull();
    expect(await verifyPayload("a.b.c", "secret", "test-purpose")).toBeNull();
  });

  it("rejects an oversized token", async () => {
    const huge = "a".repeat(10_000);
    expect(await verifyPayload(huge, "secret", "test-purpose", 8_192)).toBeNull();
  });
});
