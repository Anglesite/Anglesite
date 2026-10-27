import { test } from "node:test";
import assert from "node:assert/strict";
import { retractRecorded, syndicateRecorded, type Federation, type RecordStore } from "./federation-record.ts";

/** An in-memory KV with EmDash's versioned compare-and-set semantics. */
function memoryStore(options: { failGet?: boolean; failSet?: boolean; failDelete?: boolean } = {}) {
  const values = new Map<string, { value: unknown; revision: string }>();
  let next = 0;
  const store: RecordStore = {
    async getVersioned<T>(key: string) {
      if (options.failGet) throw new Error("kv down");
      return (values.get(key) as { value: T; revision: string } | undefined) ?? null;
    },
    async compareAndSet(key, expected, value) {
      if (options.failSet) throw new Error("kv down");
      if ((values.get(key)?.revision ?? null) !== expected) return { applied: false };
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

const KEY = "federated:01J";
const OBJECT = "https://news.example/users/site/outbox/0f2c/object";
const PUBLISHED = "2026-10-27T09:00:00.000Z";

/** A syndication that records what it was asked to do and answers like the Worker would. */
function recorder(activityPub: (federation: Federation) => string = (f) => (f?.kind === "create" ? "published" : f ? "updated" : "skipped")) {
  const seen: Federation[] = [];
  const run = async (federation: Federation) => {
    seen.push(federation);
    const result = activityPub(federation);
    return { activityPub: result, ...(result === "published" ? { objectId: OBJECT } : {}) };
  };
  return { seen, run };
}

test("the first publish posts the article and records its object; later ones update that object", async () => {
  const { store, values } = memoryStore();
  const { seen, run } = recorder();
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  assert.deepEqual(values.get(KEY)?.value, { published: PUBLISHED, objectId: OBJECT });
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  assert.deepEqual(seen, [{ kind: "create" }, { kind: "update", objectId: OBJECT }, { kind: "update", objectId: OBJECT }]);
});

test("a first post that didn't reach followers gives the claim back, so the next publish posts it", async () => {
  for (const result of ["failed", "unavailable"]) {
    const { store, values } = memoryStore();
    await syndicateRecorded(store, KEY, PUBLISHED, recorder(() => result).run);
    assert.equal(values.size, 0, result);
  }
  const { store, values } = memoryStore();
  await assert.rejects(syndicateRecorded(store, KEY, PUBLISHED, async () => { throw new Error("boom"); }), /boom/);
  assert.equal(values.size, 0);
});

test("a post in flight, or recorded without an object, is neither posted again nor updated", async () => {
  const { store, values } = memoryStore();
  values.set(KEY, { value: { published: PUBLISHED }, revision: "r0" });
  const { seen, run } = recorder();
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  assert.deepEqual(seen, [null]);
});

test("a KV that can't be read or written still syndicates, without federating", async () => {
  for (const failure of [{ failGet: true }, { failSet: true }]) {
    const { seen, run } = recorder();
    const outcome = await syndicateRecorded(memoryStore(failure).store, KEY, PUBLISHED, run);
    assert.deepEqual(seen, [null]);
    assert.equal(outcome.activityPub, "skipped");
  }
  const { seen, run } = recorder();
  await syndicateRecorded(memoryStore().store, null, PUBLISHED, run);
  assert.deepEqual(seen, [null]);
});

test("unpublishing a federated article deletes its object and clears the record; publishing it again posts it afresh", async () => {
  const { store, values } = memoryStore();
  const { seen, run } = recorder();
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  const retracted: string[] = [];
  const result = await retractRecorded(store, KEY, async (objectId) => (retracted.push(objectId), "retracted" as const), "retracted");
  assert.equal(result, "retracted");
  assert.deepEqual(retracted, [OBJECT]);
  assert.equal(values.size, 0);
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  assert.deepEqual(seen.at(-1), { kind: "create" });
});

test("a failed delete keeps the record, so a later publish updates rather than posts twice", async () => {
  const { store, values } = memoryStore();
  await syndicateRecorded(store, KEY, PUBLISHED, recorder().run);
  assert.equal(await retractRecorded(store, KEY, async () => "failed" as const, "retracted"), "failed");
  assert.ok(values.has(KEY));
  const { seen, run } = recorder();
  await syndicateRecorded(store, KEY, PUBLISHED, run);
  assert.deepEqual(seen, [{ kind: "update", objectId: OBJECT }]);
});

test("nothing to take back: never federated, no key, or an unreadable KV", async () => {
  const never = async () => { throw new Error("must not retract"); };
  assert.equal(await retractRecorded(memoryStore().store, KEY, never, "retracted"), "none");
  assert.equal(await retractRecorded(memoryStore().store, null, never, "retracted"), "none");
  assert.equal(await retractRecorded(memoryStore({ failGet: true }).store, KEY, never, "retracted"), "none");
  const inFlight = memoryStore();
  inFlight.values.set(KEY, { value: { published: PUBLISHED }, revision: "r0" });
  assert.equal(await retractRecorded(inFlight.store, KEY, never, "retracted"), "none");
});
