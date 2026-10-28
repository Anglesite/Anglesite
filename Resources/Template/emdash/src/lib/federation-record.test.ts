import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ABANDONED_AFTER_MS,
  retractRecorded,
  syndicateRecorded,
  type Federation,
  type FederationRecord,
  type RecordStore,
} from "./federation-record.ts";

/** An in-memory KV with EmDash's versioned compare-and-set semantics. */
function memoryStore(options: { failGet?: boolean; failSet?: boolean; failDelete?: boolean; failSetAfter?: number } = {}) {
  const values = new Map<string, { value: unknown; revision: string }>();
  let next = 0;
  let sets = 0;
  const store: RecordStore = {
    async getVersioned<T>(key: string) {
      if (options.failGet) throw new Error("kv down");
      return (values.get(key) as { value: T; revision: string } | undefined) ?? null;
    },
    async compareAndSet(key, expected, value) {
      sets += 1;
      if (options.failSet || (options.failSetAfter !== undefined && sets > options.failSetAfter)) throw new Error("kv down");
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
  const record = () => values.get(KEY)?.value as FederationRecord | undefined;
  return { store, values, record };
}

const KEY = "federated:01J";
const PUBLISHED = "2026-10-27T09:00:00.000Z";
const NOW = Date.parse("2026-10-27T09:00:05.000Z");
let minted = 0;
const newObjectId = () => `https://news.example/users/site/outbox/${++minted}/object`;

/** A syndication that records what it was asked to do and answers like the Worker would. */
function recorder(activityPub: (federation: Federation) => string = (f) => (f?.kind === "create" ? "published" : f ? "updated" : "skipped")) {
  const seen: Federation[] = [];
  const run = async (federation: Federation) => (seen.push(federation), { activityPub: activityPub(federation) });
  return { seen, run };
}

const publish = (store: RecordStore, run: (f: Federation) => Promise<{ activityPub: string }>, options: { now?: number; warn?: (m: string) => void } = {}) =>
  syndicateRecorded(store, KEY, PUBLISHED, newObjectId, run, { now: NOW, ...options });

test("the first publish records the object's IRI before posting; later ones update that object", async () => {
  const { store, record } = memoryStore();
  const { seen, run } = recorder();
  await publish(store, async (federation) => {
    // The IRI is in the record before anything goes out.
    assert.equal(record()?.objectId, federation?.objectId);
    return run(federation);
  });
  const objectId = record()?.objectId;
  assert.deepEqual(record(), { objectId, published: PUBLISHED, claimedAt: NOW, posted: true });
  await publish(store, run);
  assert.deepEqual(seen, [{ kind: "create", objectId }, { kind: "update", objectId }]);
});

test("a first post that didn't reach followers gives the claim back, so the next publish posts it", async () => {
  for (const result of ["failed", "unavailable"]) {
    const { store, values } = memoryStore();
    await publish(store, recorder(() => result).run);
    assert.equal(values.size, 0, result);
  }
  const { store, values } = memoryStore();
  await assert.rejects(publish(store, async () => { throw new Error("boom"); }), /boom/);
  assert.equal(values.size, 0);
});

test("a first post in flight isn't posted twice; one abandoned is posted again under the same IRI", async () => {
  const { store, values, record } = memoryStore();
  values.set(KEY, { value: { objectId: "https://news.example/o/1", published: PUBLISHED, claimedAt: NOW - 1000 }, revision: "r0" });
  const inFlight = recorder();
  await publish(store, inFlight.run);
  assert.deepEqual(inFlight.seen, [null]);

  const abandoned = recorder();
  await publish(store, abandoned.run, { now: NOW + ABANDONED_AFTER_MS });
  assert.deepEqual(abandoned.seen, [{ kind: "create", objectId: "https://news.example/o/1" }]);
  assert.equal(record()?.posted, true);
});

test("a post that went out but couldn't be confirmed is warned about, and taken over later", async () => {
  // The claim is the first write; the confirmation (the second) fails.
  const { store, record } = memoryStore({ failSetAfter: 1 });
  const warnings: string[] = [];
  await publish(store, recorder().run, { warn: (m) => warnings.push(m) });
  assert.equal(record()?.posted, undefined);
  assert.match(warnings.join("\n"), /couldn't record it/);
});

test("a record written before #2174 (no object IRI) is warned about and left alone", async () => {
  const { store, values } = memoryStore();
  values.set(KEY, { value: { published: PUBLISHED }, revision: "r0" });
  const warnings: string[] = [];
  const { seen, run } = recorder();
  await publish(store, run, { warn: (m) => warnings.push(m) });
  assert.deepEqual(seen, [null]);
  assert.match(warnings.join("\n"), /predates/);
});

test("a KV that can't be read or written still syndicates, without federating", async () => {
  for (const failure of [{ failGet: true }, { failSet: true }]) {
    const { seen, run } = recorder();
    const outcome = await publish(memoryStore(failure).store, run);
    assert.deepEqual(seen, [null]);
    assert.equal(outcome.activityPub, "skipped");
  }
  const { seen, run } = recorder();
  await syndicateRecorded(memoryStore().store, null, PUBLISHED, newObjectId, run);
  assert.deepEqual(seen, [null]);
});

test("unpublishing deletes the object and clears the record; publishing again posts afresh", async () => {
  const { store, values, record } = memoryStore();
  const { seen, run } = recorder();
  await publish(store, run);
  const objectId = record()?.objectId;
  const retracted: string[] = [];
  assert.equal(await retractRecorded(store, KEY, async (id) => (retracted.push(id), "retracted" as const), "retracted"), "retracted");
  assert.deepEqual(retracted, [objectId]);
  assert.equal(values.size, 0);
  await publish(store, run);
  assert.equal(seen.at(-1)?.kind, "create");
  assert.notEqual(seen.at(-1)?.objectId, objectId);
});

test("a delete whose record can't be cleared still reads as gone: the next publish posts afresh", async () => {
  const { store, record } = memoryStore({ failDelete: true });
  const { seen, run } = recorder();
  await publish(store, run);
  const objectId = record()?.objectId;
  assert.equal(await retractRecorded(store, KEY, async () => "retracted" as const, "retracted"), "retracted");
  assert.equal(record()?.retracted, true);
  await publish(store, run);
  assert.equal(seen.at(-1)?.kind, "create");
  assert.notEqual(seen.at(-1)?.objectId, objectId);
  assert.equal(record()?.retracted, undefined);
});

test("a failed delete puts the record back, so a later publish updates rather than posts twice", async () => {
  const { store, record } = memoryStore();
  await publish(store, recorder().run);
  const before = record();
  assert.equal(await retractRecorded(store, KEY, async () => "failed" as const, "retracted"), "failed");
  assert.deepEqual(record(), before);
  const { seen, run } = recorder();
  await publish(store, run);
  assert.deepEqual(seen, [{ kind: "update", objectId: before?.objectId }]);
});

test("unpublishing while the first post is in flight still deletes it", async () => {
  const { store, values } = memoryStore();
  values.set(KEY, { value: { objectId: "https://news.example/o/9", published: PUBLISHED, claimedAt: NOW }, revision: "r0" });
  const retracted: string[] = [];
  assert.equal(await retractRecorded(store, KEY, async (id) => (retracted.push(id), "retracted" as const), "retracted"), "retracted");
  assert.deepEqual(retracted, ["https://news.example/o/9"]);
});

test("nothing to take back: never federated, already retracted, no key, no IRI, or an unreadable KV", async () => {
  const never = async () => { throw new Error("must not retract"); };
  assert.equal(await retractRecorded(memoryStore().store, KEY, never, "retracted"), "none");
  assert.equal(await retractRecorded(memoryStore().store, null, never, "retracted"), "none");
  assert.equal(await retractRecorded(memoryStore({ failGet: true }).store, KEY, never, "retracted"), "none");
  for (const value of [{ published: PUBLISHED }, { objectId: "https://news.example/o/1", posted: true, retracted: true }]) {
    const { store, values } = memoryStore();
    values.set(KEY, { value, revision: "r0" });
    assert.equal(await retractRecorded(store, KEY, never, "retracted"), "none");
  }
});
