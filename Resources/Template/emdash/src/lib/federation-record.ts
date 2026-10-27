/**
 * The record of an entry's post to ActivityPub followers (#2168, #2174), kept apart from the
 * EmDash plugin so it can be tested without EmDash. Dependency-free on purpose: the template's
 * `npm test` runs this with no EmDash install.
 *
 * One KV entry per EmDash entry. Its first publish claims the key and posts a `Create`; once that
 * succeeds, the record holds the IRI the outbox gave the object. A later publish then sends an
 * `Update` of that object, and unpublishing or deleting the entry sends a `Delete` and clears the
 * record, so publishing it again posts it afresh.
 *
 * A `Create` that doesn't reach followers gives the claim back, so the next publish tries again;
 * that covers a step that reports a failure and one that throws. A `Delete` that fails keeps the
 * record, so a later publish sends an `Update` rather than a second post. A KV that can't be read
 * or written still lets the article's Webmentions and WebSub notice go out; only the ActivityPub
 * side waits for the next publish.
 */

/** The slice of EmDash's plugin `KVAccess` the record uses. */
export interface RecordStore {
  getVersioned<T>(key: string): Promise<{ value: T; revision: string } | null>;
  compareAndSet(key: string, expectedRevision: string | null, value: unknown): Promise<{ applied: true; revision: string } | { applied: false }>;
  compareAndDelete(key: string, expectedRevision: string): Promise<unknown>;
}

/** What the record holds. `objectId` is absent while the first post is in flight. */
export interface FederationRecord {
  objectId?: string;
  published?: string;
}

/** `Federation` in `worker/worker.ts`, restated so this module stays dependency-free. */
export type Federation = { kind: "create" } | { kind: "update"; objectId: string } | null;

/** The slice of `SyndicationOutcome` the record reads. */
export interface FederationResult {
  activityPub: string;
  objectId?: string;
}

/**
 * Runs `syndicate` with what to do with followers on this publish of the entry recorded under
 * `key` (`null`: no record possible, so not federated), and keeps the record in step with what
 * reached them.
 */
export async function syndicateRecorded<T extends FederationResult>(
  store: RecordStore,
  key: string | null,
  published: string,
  syndicate: (federation: Federation) => Promise<T>,
): Promise<T> {
  if (!key) return syndicate(null);
  let existing: { value: FederationRecord; revision: string } | null;
  try {
    existing = await store.getVersioned<FederationRecord>(key);
  } catch {
    return syndicate(null);
  }
  if (existing) {
    const objectId = existing.value?.objectId;
    // Without an object IRI the first post is still in flight (or predates #2174): leave it be.
    return syndicate(typeof objectId === "string" ? { kind: "update", objectId } : null);
  }

  let revision: string | null = null;
  try {
    const claim = await store.compareAndSet(key, null, { published } satisfies FederationRecord);
    if (claim.applied) revision = claim.revision;
  } catch {
    // Not claimed: the other steps still run.
  }
  if (revision === null) return syndicate(null);

  const release = async () => {
    try {
      await store.compareAndDelete(key, revision);
    } catch {
      // A claim that can't be given back holds this entry's ActivityPub post back; nothing else.
    }
  };
  let outcome: T;
  try {
    outcome = await syndicate({ kind: "create" });
  } catch (error) {
    await release();
    throw error;
  }
  if (outcome.activityPub !== "published") {
    await release();
  } else if (outcome.objectId) {
    try {
      await store.compareAndSet(key, revision, { published, objectId: outcome.objectId } satisfies FederationRecord);
    } catch {
      // Posted, but no IRI to update or delete it by later: the claim still stops a second post.
    }
  }
  return outcome;
}

/**
 * Takes the entry recorded under `key` back from followers with `retract`, when it was posted to
 * them, and clears the record once that worked. `none` when there is nothing to take back.
 */
export async function retractRecorded<R extends string>(
  store: RecordStore,
  key: string | null,
  retract: (objectId: string) => Promise<R>,
  retracted: R,
): Promise<R | "none"> {
  if (!key) return "none";
  let existing: { value: FederationRecord; revision: string } | null;
  try {
    existing = await store.getVersioned<FederationRecord>(key);
  } catch {
    return "none";
  }
  const objectId = existing?.value?.objectId;
  if (!existing || typeof objectId !== "string") return "none";
  const result = await retract(objectId);
  if (result === retracted) {
    try {
      await store.compareAndDelete(key, existing.revision);
    } catch {
      // The record stays: a later publish sends an `Update` of a deleted object, which the
      // outbox keeps serving as a `Tombstone`.
    }
  }
  return result;
}
