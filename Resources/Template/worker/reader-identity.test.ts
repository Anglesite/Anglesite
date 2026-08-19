import { describe, expect, it } from "vitest";
import { isAllowedReader, normalizeReaderIdentity } from "./reader-identity.ts";

describe("normalizeReaderIdentity", () => {
  it("drops the scheme, lowercases the host, and trims a trailing slash", () => {
    expect(normalizeReaderIdentity("https://Alice.example/")).toBe("alice.example");
  });

  it("treats http and https as equal", () => {
    expect(normalizeReaderIdentity("http://alice.example/")).toBe(
      normalizeReaderIdentity("https://alice.example/"),
    );
  });

  it("preserves a non-root path without its trailing slash", () => {
    expect(normalizeReaderIdentity("https://bob.example/blog/")).toBe("bob.example/blog");
  });

  it("leaves a path with no trailing slash untouched", () => {
    expect(normalizeReaderIdentity("https://bob.example/blog")).toBe("bob.example/blog");
  });
});

function kvWith(value: string | null): { get(key: string): Promise<string | null> } {
  return { get: async () => value };
}

describe("isAllowedReader", () => {
  it("returns true for a normalized match in the pushed allowlist", async () => {
    const env = { SOCIAL_KV: kvWith(JSON.stringify(["alice.example", "bob.example/blog"])) };
    expect(await isAllowedReader(env, "https://alice.example/")).toBe(true);
    expect(await isAllowedReader(env, "https://bob.example/blog/")).toBe(true);
  });

  it("returns false for a me URL not on the allowlist", async () => {
    const env = { SOCIAL_KV: kvWith(JSON.stringify(["alice.example"])) };
    expect(await isAllowedReader(env, "https://mallory.example/")).toBe(false);
  });

  it("returns false when SOCIAL_KV is unbound", async () => {
    expect(await isAllowedReader({}, "https://alice.example/")).toBe(false);
  });

  it("returns false when the key is missing", async () => {
    const env = { SOCIAL_KV: kvWith(null) };
    expect(await isAllowedReader(env, "https://alice.example/")).toBe(false);
  });

  it("returns false for malformed JSON rather than throwing", async () => {
    const env = { SOCIAL_KV: kvWith("{not json") };
    expect(await isAllowedReader(env, "https://alice.example/")).toBe(false);
  });

  it("returns false when the stored value isn't a JSON array", async () => {
    const env = { SOCIAL_KV: kvWith(JSON.stringify({ not: "an array" })) };
    expect(await isAllowedReader(env, "https://alice.example/")).toBe(false);
  });

  it("ignores non-string entries in the array", async () => {
    const env = { SOCIAL_KV: kvWith(JSON.stringify(["alice.example", 42, null])) };
    expect(await isAllowedReader(env, "https://alice.example/")).toBe(true);
  });
});
