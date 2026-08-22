import { beforeEach, expect, test, vi } from "vitest";
import { env } from "cloudflare:workers";
import { createExecutionContext } from "cloudflare:test";
import worker, { type WorkerEnv } from "./worker";

/**
 * Regression test for #1597 finding C1: `handleWebmentionQueue` must pass
 * `isTrustedVouchDomain` in the config it hands `createWebmentionQueueConsumer`, or every vouch
 * defaults to untrusted (`@dwk/webmention`'s own documented fallback for an omitted predicate)
 * and the whole Vouch trust-list mechanism — `vouch-trust.ts`, `BlogrollTrustSync`,
 * `BlogrollTrustKVClient` — computes and stores a trust list that nothing ever reads.
 *
 * `@dwk/webmention` is mocked only to capture the config object passed to
 * `createWebmentionQueueConsumer`; every export (including `createWebmentionQueueConsumer`
 * itself) still delegates to the real implementation, so this doesn't change behavior for any
 * other webmention test in this suite.
 */
let capturedConfig: Record<string, unknown> | undefined;

vi.mock("@dwk/webmention", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@dwk/webmention")>();
  return {
    ...actual,
    createWebmentionQueueConsumer: (config: Record<string, unknown>) => {
      capturedConfig = config;
      return actual.createWebmentionQueueConsumer(config as never);
    },
  };
});

const testEnv = env as unknown as WorkerEnv;

beforeEach(() => {
  capturedConfig = undefined;
});

function emptyQueueBatch() {
  return { queue: "site-webmention", messages: [] } as unknown as Parameters<NonNullable<typeof worker.queue>>[0];
}

test("webmention queue consumer config includes isTrustedVouchDomain", async () => {
  await worker.queue!(emptyQueueBatch(), testEnv, createExecutionContext());
  expect(capturedConfig).toBeDefined();
  expect(typeof capturedConfig?.isTrustedVouchDomain).toBe("function");
});

test("the wired isTrustedVouchDomain reads the real SOCIAL_KV trust list", async () => {
  await testEnv.SOCIAL_KV!.put("vouch:trusted-domains", JSON.stringify(["alice.example"]));
  await worker.queue!(emptyQueueBatch(), testEnv, createExecutionContext());

  const isTrustedVouchDomain = capturedConfig?.isTrustedVouchDomain as (hostname: string) => Promise<boolean>;
  await expect(isTrustedVouchDomain("alice.example")).resolves.toBe(true);
  await expect(isTrustedVouchDomain("carol.example")).resolves.toBe(false);
});
