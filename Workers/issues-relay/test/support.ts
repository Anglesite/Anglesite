// Shared fakes for the relay tests: an in-memory KV and a recording GitHub client.

import type { GitHubIssue } from "../src/github.js";
import type { RelayContext } from "../src/relay.js";

export function memoryKV(): KVNamespace & { dump(): Map<string, string> } {
  const store = new Map<string, string>();
  return {
    async get(key: string, type?: string) {
      const value = store.get(key) ?? null;
      return type === "json" && value !== null ? JSON.parse(value) : value;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
    async delete(key: string) {
      store.delete(key);
    },
    dump: () => store,
  } as unknown as KVNamespace & { dump(): Map<string, string> };
}

export class FakeGitHub implements Pick<RelayContext["github"], "createIssue" | "getIssue" | "comment" | "findByMarker"> {
  issues = new Map<number, GitHubIssue & { title: string; body: string }>();
  comments: Array<{ number: number; body: string }> = [];
  private next = 1;

  async createIssue(_repo: string, issue: { title: string; body: string; labels: string[] }) {
    const created = { ...issue, number: this.next++, state: "open" as const, html_url: "https://example.test" };
    this.issues.set(created.number, created);
    return created;
  }
  async getIssue(_repo: string, number: number) {
    return this.issues.get(number)!;
  }
  async comment(_repo: string, number: number, body: string) {
    this.comments.push({ number, body });
  }
  async findByMarker(_repo: string, text: string) {
    return [...this.issues.values()].find((i) => i.body.includes(text));
  }
}

/** A delivery whose stack throws inside `@dwk/webmention`, called from the template Worker. */
export function packageDelivery(overrides: { lastSeen?: string; count?: number; line?: number; fingerprint?: string } = {}) {
  return {
    name: "Workers Issues",
    text: "New issue",
    data: {
      fingerprint: overrides.fingerprint ?? "cf-fp-1",
      count: overrides.count ?? 3,
      first_seen: "2026-09-30T10:00:00Z",
      last_seen: overrides.lastSeen ?? "2026-09-30T11:00:00Z",
      stack:
        "TypeError: Cannot read properties of undefined (reading 'source') for jane@example.com\n" +
        "    at parseHTML (node_modules/linkedom/esm/index.js:5:5)\n" +
        `    at verifySource (node_modules/@dwk/webmention/src/verify.ts:${overrides.line ?? 42}:17)\n` +
        "    at receive (node_modules/@dwk/webmention/src/receive.ts:10:3)\n" +
        "    at handle (worker/worker.ts:88:12)",
      request: { url: "https://jane.dwk.io/webmention?secret=1", headers: { cookie: "session=abc" } },
    },
    ts: 1759230000,
  };
}
