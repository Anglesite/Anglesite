import { describe, it, expect } from "vitest";
import { isTrustedVouchDomain } from "./vouch-trust.ts";

describe("isTrustedVouchDomain", () => {
  it("is true when the hostname is in the pushed trust list", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example", "bob.example"]) } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(true);
  });

  it("is false when the hostname is not in the list", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example"]) } };
    expect(await isTrustedVouchDomain(env, "carol.example")).toBe(false);
  });

  it("is false when SOCIAL_KV is not bound", async () => {
    const env = {};
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false when the key is missing", async () => {
    const env = { SOCIAL_KV: { get: async () => null } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false, not thrown, when the stored value is malformed JSON", async () => {
    const env = { SOCIAL_KV: { get: async () => "not json" } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false when the stored value is valid JSON but not a string array", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify({ not: "an array" }) } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });
});
