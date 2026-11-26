import { test } from "node:test";
import assert from "node:assert/strict";
import {
  GONE_RULE_GROUP,
  articleKey,
  deferredEntry,
  deferredTaskName,
  recordPublished,
  recordRemoved,
  type GoneRule,
  type GoneRules,
  type PathStore,
} from "./removal-record.ts";

/** An in-memory KV. */
function memoryStore(options: { failGet?: boolean; failSet?: boolean } = {}) {
  const values = new Map<string, unknown>();
  const store: PathStore = {
    async get<T>(key: string) {
      if (options.failGet) throw new Error("kv down");
      return (values.get(key) as T | undefined) ?? null;
    },
    async set(key, value) {
      if (options.failSet) throw new Error("kv down");
      values.set(key, value);
    },
  };
  return { store, values };
}

/**
 * In-memory redirect rules, with EmDash's one-rule-per-exact-source and revision checks, and its
 * listing: a `LIKE` over sources and destinations, newest first, a page at a time.
 */
function memoryRules(options: { failCreate?: boolean; failList?: boolean; deleteReturns?: boolean } = {}) {
  const rules = new Map<string, GoneRule & { rev: number; destination: string }>();
  let next = 0;
  const access: GoneRules = {
    async create(input) {
      if (options.failCreate) throw new Error("db down");
      if ([...rules.values()].some((rule) => rule.source === input.source)) throw new Error("CONFLICT");
      const id = `r${String(++next).padStart(4, "0")}`;
      rules.set(id, { id, source: input.source, destination: "", type: input.type, enabled: true, groupName: input.groupName, rev: 1 });
      return {};
    },
    async get(id) {
      const rule = rules.get(id);
      return rule ? { redirect: rule, _rev: String(rule.rev) } : null;
    },
    async delete(id, { _rev }) {
      if (options.deleteReturns === false) return false;
      if (rules.get(id)?.rev !== Number(_rev)) throw new Error("stale revision");
      return rules.delete(id);
    },
    async list({ search, limit = 50, cursor }) {
      if (options.failList) throw new Error("db down");
      const matching = [...rules.values()]
        .filter((rule) => rule.source.includes(search) || rule.destination.includes(search))
        .sort((a, b) => b.id.localeCompare(a.id));
      const start = cursor ? Number(cursor) : 0;
      const items = matching.slice(start, start + limit);
      const more = start + limit < matching.length;
      return { items, hasMore: more, ...(more ? { cursor: String(start + limit) } : {}) };
    },
  };
  const owners = (source: string, type: number, { enabled = true, destination = "" } = {}) => {
    const id = `r${String(++next).padStart(4, "0")}`;
    rules.set(id, { id, source, destination, type, enabled, groupName: null, rev: 1 });
    return id;
  };
  const at = (source: string) => [...rules.values()].filter((rule) => rule.source === source);
  return { access, rules, owners, at };
}

const KEY = articleKey("01J")!;
const PATH = "/articles/council-vote/";

test("an entry is keyed on its id, and one without an id has no record", () => {
  assert.equal(KEY, "article:01J");
  assert.equal(articleKey(""), null);
  assert.equal(articleKey(undefined), null);
});

test("unpublishing makes the article answer 410 under Anglesite's group; publishing again lifts it", async () => {
  const { store } = memoryStore();
  const { access, at } = memoryRules();
  assert.equal(await recordPublished(store, access, KEY, PATH), "none");

  assert.equal(await recordRemoved(store, access, KEY, PATH), PATH);
  assert.deepEqual(at(PATH).map(({ type, groupName }) => ({ type, groupName })), [{ type: 410, groupName: GONE_RULE_GROUP }]);

  assert.equal(await recordPublished(store, access, KEY, PATH), "lifted");
  assert.deepEqual(at(PATH), []);
});

test("a deletion finds the path the entry was last published at", async () => {
  const { store } = memoryStore();
  const { access, at } = memoryRules();
  await recordPublished(store, access, KEY, PATH);
  assert.equal(await recordRemoved(store, access, KEY, null), PATH);
  assert.equal(at(PATH)[0]?.type, 410);

  // Nothing recorded (published before #2221) and no path in the event: nothing to tell.
  assert.equal(await recordRemoved(memoryStore().store, access, articleKey("other"), null), null);
});

test("an unpublish then a delete tells the linked sites once", async () => {
  const { store } = memoryStore();
  const { access, at } = memoryRules();
  await recordPublished(store, access, KEY, PATH);
  assert.equal(await recordRemoved(store, access, KEY, PATH), PATH);
  assert.equal(await recordRemoved(store, access, KEY, null), null);
  assert.equal(at(PATH).length, 1);
});

test("a redirect of the owner's for the path is never touched", async () => {
  const warnings: string[] = [];
  const warn = (m: string) => warnings.push(m);
  const { store } = memoryStore();
  const { access, owners, at } = memoryRules();
  owners(PATH, 301);
  assert.equal(await recordRemoved(store, access, KEY, PATH, { warn }), null);
  assert.deepEqual(at(PATH).map((rule) => rule.type), [301]);
  assert.match(warnings.join("\n"), /redirect of its own/);

  // The owner's own 410 already answers Gone: the linked sites are told, and it stays theirs.
  const own = memoryRules();
  own.owners(PATH, 410);
  assert.equal(await recordRemoved(store, own.access, KEY, PATH), PATH);
  assert.equal(await recordPublished(store, own.access, KEY, PATH, { warn }), "none");
  assert.deepEqual(own.at(PATH).map((rule) => rule.groupName), [null]);
  assert.match(warnings.join("\n"), /410 of its own/);
});

test("back under a new slug: the old URL stays gone", async () => {
  const { store } = memoryStore();
  const { access, at } = memoryRules();
  await recordPublished(store, access, KEY, PATH);
  await recordRemoved(store, access, KEY, PATH);
  assert.equal(await recordPublished(store, access, KEY, "/articles/council-vote-final/"), "none");
  assert.equal(at(PATH)[0]?.type, 410);
});

test("a lost KV write can't strand the article at 410: the rule is found by its path", async () => {
  const { access, at } = memoryRules();
  assert.equal(await recordRemoved(memoryStore({ failSet: true }).store, access, KEY, PATH), PATH);
  assert.equal(await recordPublished(memoryStore({ failSet: true }).store, access, KEY, PATH, { warn: () => {} }), "lifted");
  assert.deepEqual(at(PATH), []);
});

test("rules that can't be read or written: warned about, and nothing is told", async () => {
  for (const failure of [{ failCreate: true }, { failList: true }]) {
    const warnings: string[] = [];
    const { access } = memoryRules(failure);
    assert.equal(await recordRemoved(memoryStore().store, access, KEY, PATH, { warn: (m) => warnings.push(m) }), null);
    assert.match(warnings.join("\n"), /couldn't make/);
  }
  // No redirect access at all (an install without the capability).
  assert.equal(await recordRemoved(memoryStore().store, undefined, KEY, PATH), null);
  const { store, values } = memoryStore();
  assert.equal(await recordPublished(store, undefined, KEY, PATH), "none");
  assert.deepEqual(values.get(KEY), { path: PATH });
});

test("an owner's rule at the path's other spelling governs it too, and is never shadowed", async () => {
  const warnings: string[] = [];
  const { access, owners, at } = memoryRules();
  owners("/articles/council-vote", 301, { destination: "/articles/new-home/" });
  assert.equal(await recordRemoved(memoryStore().store, access, KEY, PATH, { warn: (m) => warnings.push(m) }), null);
  assert.deepEqual(at(PATH), []);
  assert.match(warnings.join("\n"), /redirect of its own/);
});

test("a turned-off rule doesn't answer: none counts as removed, and one at the exact path blocks a new rule", async () => {
  const warnings: string[] = [];
  const warn = (m: string) => warnings.push(m);
  // At the other spelling: it answers nothing, so the article gets its 410.
  const twin = memoryRules();
  twin.owners("/articles/council-vote", 301, { enabled: false });
  assert.equal(await recordRemoved(memoryStore().store, twin.access, KEY, PATH, { warn }), PATH);
  assert.equal(twin.at(PATH)[0]?.groupName, GONE_RULE_GROUP);

  // At the exact path: EmDash allows one rule per source, so it stays the owner's, and nothing is told.
  for (const type of [301, 410]) {
    const exact = memoryRules();
    exact.owners(PATH, type, { enabled: false });
    assert.equal(await recordRemoved(memoryStore().store, exact.access, KEY, PATH, { warn }), null, String(type));
  }
  assert.match(warnings.join("\n"), /turned-off redirect/);

  // Ours, turned off by the owner: left off, not re-sent.
  const ours = memoryRules();
  await recordRemoved(memoryStore().store, ours.access, KEY, PATH);
  ours.at(PATH)[0]!.enabled = false;
  assert.equal(await recordRemoved(memoryStore().store, ours.access, KEY, PATH, { warn }), null);
  // Publishing again still lifts it.
  assert.equal(await recordPublished(memoryStore().store, ours.access, KEY, PATH), "lifted");
  assert.deepEqual(ours.at(PATH), []);
});

test("the rule is found past the listing's first page", async () => {
  const { access, owners, at } = memoryRules();
  await recordRemoved(memoryStore().store, access, KEY, PATH);
  // Many older URLs redirect to the article: newer rows that match the search first.
  for (let i = 0; i < 230; i++) owners(`/old/${i}/`, 301, { destination: PATH });
  assert.equal(await recordRemoved(memoryStore().store, access, KEY, PATH), null);
  assert.equal(await recordPublished(memoryStore().store, access, KEY, PATH), "lifted");
  assert.deepEqual(at(PATH), []);
});

test("lifted only when the rule came down", async () => {
  const warnings: string[] = [];
  const { access, at } = memoryRules({ deleteReturns: false });
  await recordRemoved(memoryStore().store, access, KEY, PATH);
  assert.equal(await recordPublished(memoryStore().store, access, KEY, PATH, { warn: (m) => warnings.push(m) }), "none");
  assert.equal(at(PATH).length, 1);
  assert.match(warnings.join("\n"), /couldn't lift/);
});

test("a deferred send is named for its entry, and only its own task maps back to it", () => {
  assert.equal(deferredTaskName("01JABCDEF"), "resyndicate-01JABCDEF");
  assert.equal(deferredTaskName("has space"), null);
  assert.equal(deferredTaskName(42), null);
  assert.equal(deferredEntry("resyndicate-01JABCDEF", { id: "01JABCDEF" }), "01JABCDEF");
  assert.equal(deferredEntry("resyndicate-01JABCDEF", { id: "other" }), null);
  assert.equal(deferredEntry("some-other-task", { id: "01JABCDEF" }), null);
});
