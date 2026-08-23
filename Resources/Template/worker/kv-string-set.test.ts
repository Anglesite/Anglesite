import { describe, it, expect } from "vitest";
import { readStringSetFromKV } from "./kv-string-set.ts";

describe("readStringSetFromKV", () => {
  it("returns the parsed set for a valid JSON string array", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example", "bob.example"]) } };
    expect(await readStringSetFromKV(env, "some:key")).toEqual(new Set(["alice.example", "bob.example"]));
  });

  it("passes the given key through to the KV get call", async () => {
    let seenKey: string | undefined;
    const env = {
      SOCIAL_KV: {
        get: async (key: string) => {
          seenKey = key;
          return JSON.stringify([]);
        },
      },
    };
    await readStringSetFromKV(env, "vouch:trusted-domains");
    expect(seenKey).toBe("vouch:trusted-domains");
  });

  it("returns an empty set when SOCIAL_KV is not bound", async () => {
    expect(await readStringSetFromKV({}, "some:key")).toEqual(new Set());
  });

  it("returns an empty set when the key is missing", async () => {
    const env = { SOCIAL_KV: { get: async () => null } };
    expect(await readStringSetFromKV(env, "some:key")).toEqual(new Set());
  });

  it("returns an empty set, not thrown, when the stored value is malformed JSON", async () => {
    const env = { SOCIAL_KV: { get: async () => "not json" } };
    expect(await readStringSetFromKV(env, "some:key")).toEqual(new Set());
  });

  it("returns an empty set when the stored value is valid JSON but not an array", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify({ not: "an array" }) } };
    expect(await readStringSetFromKV(env, "some:key")).toEqual(new Set());
  });

  it("filters out non-string entries from the array", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example", 42, null, "bob.example"]) } };
    expect(await readStringSetFromKV(env, "some:key")).toEqual(new Set(["alice.example", "bob.example"]));
  });
});
