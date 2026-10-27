import { test } from "node:test";
import assert from "node:assert/strict";
import { syndicateOnce, type ClaimStore } from "./syndication-claim.ts";

/** An in-memory KV with EmDash's compare-and-set semantics. */
function memoryStore(options: { failSet?: boolean; failDelete?: boolean } = {}) {
  const values = new Map<string, { value: unknown; revision: string }>();
  let next = 0;
  const store: ClaimStore = {
    async compareAndSet(key, _expected, value) {
      if (options.failSet) throw new Error("kv down");
      if (values.has(key)) return { applied: false };
      const revision = `r${++next}`;
      values.set(key, { value, revision });
      return { applied: true, revision };
    },
    async compareAndDelete(key, revision) {
      if (options.failDelete) throw new Error("kv down");
      if (values.get(key)?.revision === revision) values.delete(key);
    },
  };
  return { store, values };
}

const outcome = (activityPub: string) => async () => ({ activityPub });

test("the first publish federates and keeps the claim; later ones don't federate", async () => {
  const { store, values } = memoryStore();
  const seen: boolean[] = [];
  const run = (federate: boolean) => (seen.push(federate), Promise.resolve({ activityPub: federate ? "published" : "skipped" }));
  await syndicateOnce(store, "federated:01J", {}, run);
  await syndicateOnce(store, "federated:01J", {}, run);
  assert.deepEqual(seen, [true, false]);
  assert.ok(values.has("federated:01J"));
});

test("a post that didn't reach followers gives the claim back, so the next publish tries again", async () => {
  for (const result of ["failed", "unavailable"]) {
    const { store, values } = memoryStore();
    await syndicateOnce(store, "federated:01J", {}, outcome(result));
    assert.equal(values.size, 0, result);
  }
});

test("a syndication that throws gives the claim back and rethrows", async () => {
  const { store, values } = memoryStore();
  await assert.rejects(syndicateOnce(store, "federated:01J", {}, async () => { throw new Error("boom"); }), /boom/);
  assert.equal(values.size, 0);
});

test("a KV that can't be written still syndicates, without federating", async () => {
  const { store } = memoryStore({ failSet: true });
  const seen: boolean[] = [];
  const result = await syndicateOnce(store, "federated:01J", {}, async (federate) => (seen.push(federate), { activityPub: "skipped" }));
  assert.deepEqual(seen, [false]);
  assert.equal(result.activityPub, "skipped");
});

test("an entry without a key isn't federated, and a failed release doesn't throw", async () => {
  const seen: boolean[] = [];
  await syndicateOnce(memoryStore().store, null, {}, async (federate) => (seen.push(federate), { activityPub: "skipped" }));
  assert.deepEqual(seen, [false]);
  await syndicateOnce(memoryStore({ failDelete: true }).store, "federated:01J", {}, outcome("failed"));
});
