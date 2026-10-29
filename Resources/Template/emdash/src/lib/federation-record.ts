/**
 * The record of an entry's post to ActivityPub followers (#2168, #2174), kept apart from the
 * EmDash plugin so it can be tested without EmDash. Dependency-free on purpose: the template's
 * `npm test` runs this with no EmDash install.
 *
 * One KV entry per EmDash entry, written before anything goes out. Its first publish claims the
 * key with the IRI the post's object will have (chosen here, not by the outbox, so it is known
 * from the first write on) and posts a `Create`; once that reached followers, the record says so.
 * A later publish then sends an `Update` of that object, and unpublishing or deleting the entry
 * sends a `Delete` and clears the record, so publishing it again posts it afresh.
 *
 * - A `Create` that doesn't reach followers gives the claim back, so the next publish tries again;
 *   that covers a step that reports a failure and one that throws.
 * - A claim left unconfirmed longer than any hook runs (`ABANDONED_AFTER_MS`) is taken over and
 *   posted again under the same IRI, which followers' servers treat as the same post.
 * - A `Delete` marks the record first, so a record that then can't be cleared still reads as gone,
 *   and the next publish posts afresh. A `Delete` that fails puts the record back.
 * - A KV that can't be read or written still lets the article's Webmentions and WebSub notice go
 *   out; only the ActivityPub side waits for the next publish.
 */

/** The slice of EmDash's plugin `KVAccess` the record uses. */
export interface RecordStore {
  getVersioned<T>(key: string): Promise<{ value: T; revision: string } | null>;
  compareAndSet(key: string, expectedRevision: string | null, value: unknown): Promise<{ applied: true; revision: string } | { applied: false }>;
  compareAndDelete(key: string, expectedRevision: string): Promise<unknown>;
}

/** What the record holds. */
export interface FederationRecord {
  /** The post's object IRI. Absent only on a record written before #2174, which can't be followed. */
  objectId?: string;
  published?: string;
  /** Epoch ms the claim was taken: how long an unconfirmed `Create` has been in flight. */
  claimedAt?: number;
  /** The `Create` reached followers. */
  posted?: true;
  /** A `Delete` went out: the post is gone from followers. */
  retracted?: true;
}

/** `Federation` in `worker/worker.ts`, restated so this module stays dependency-free. */
export type Federation = { kind: "create"; objectId: string } | { kind: "update"; objectId: string } | null;

/** The slice of `SyndicationOutcome` the record reads. */
export interface FederationResult {
  activityPub: string;
}

/** Longer than any one hook may run (25 s), with room for clock skew between Workers. */
export const ABANDONED_AFTER_MS = 10 * 60 * 1000;

/** What the record couldn't do, for the plugin's log. */
export type RecordWarning = (message: string) => void;

/**
 * Runs `syndicate` with what to do with followers on this publish of the entry recorded under
 * `key` (`null`: no record possible, so not federated), and keeps the record in step with what
 * reached them. `newObjectId` makes the IRI a first post's object gets.
 */
export async function syndicateRecorded<T extends FederationResult>(
  store: RecordStore,
  key: string | null,
  published: string,
  newObjectId: () => string,
  syndicate: (federation: Federation) => Promise<T>,
  { now = Date.now(), warn = () => {} }: { now?: number; warn?: RecordWarning } = {},
): Promise<T> {
  if (!key) return syndicate(null);
  let existing: { value: FederationRecord; revision: string } | null;
  try {
    existing = await store.getVersioned<FederationRecord>(key);
  } catch {
    warn(`couldn't read ${key}: not sent to followers this time`);
    return syndicate(null);
  }

  const record = existing?.value ?? {};
  if (existing && !record.retracted) {
    if (typeof record.objectId !== "string") {
      warn(`${key} predates its object's IRI being recorded: followers aren't sent its changes`);
      return syndicate(null);
    }
    if (record.posted) return syndicate({ kind: "update", objectId: record.objectId });
    const abandoned = typeof record.claimedAt !== "number" || now - record.claimedAt > ABANDONED_AFTER_MS;
    if (!abandoned) return syndicate(null);
  }

  // Claim the key: a fresh entry, a retracted one (posted afresh), or an abandoned claim (taken
  // over, under the same IRI).
  const objectId = existing && !record.retracted && typeof record.objectId === "string" ? record.objectId : newObjectId();
  const claimed: FederationRecord = { objectId, published, claimedAt: now };
  let revision: string | null = null;
  try {
    const claim = await store.compareAndSet(key, existing?.revision ?? null, claimed);
    if (claim.applied) revision = claim.revision;
  } catch {
    warn(`couldn't claim ${key}: not sent to followers this time`);
  }
  if (revision === null) return syndicate(null);

  const release = async () => {
    try {
      await store.compareAndDelete(key, revision);
    } catch {
      warn(`couldn't release ${key}: its first post waits until the claim is abandoned`);
    }
  };
  let outcome: T;
  try {
    outcome = await syndicate({ kind: "create", objectId });
  } catch (error) {
    await release();
    throw error;
  }
  if (outcome.activityPub !== "published") {
    await release();
    return outcome;
  }
  let confirmed = false;
  try {
    confirmed = (await store.compareAndSet(key, revision, { ...claimed, posted: true } satisfies FederationRecord)).applied;
  } catch {
    // Reported below.
  }
  if (!confirmed) warn(`posted ${objectId}, but couldn't record it: it is posted again under the same IRI later`);
  return outcome;
}

/**
 * Takes the entry recorded under `key` back from followers with `retract`, when it was posted to
 * them (or may have been: a first post in flight), and clears the record once that worked. `none`
 * when there is nothing to take back.
 */
export async function retractRecorded<R extends string>(
  store: RecordStore,
  key: string | null,
  retract: (objectId: string) => Promise<R>,
  retracted: R,
  { warn = () => {} }: { warn?: RecordWarning } = {},
): Promise<R | "none"> {
  if (!key) return "none";
  let existing: { value: FederationRecord; revision: string } | null;
  try {
    existing = await store.getVersioned<FederationRecord>(key);
  } catch {
    warn(`couldn't read ${key}: not taken back from followers`);
    return "none";
  }
  const record = existing?.value;
  if (!existing || !record || record.retracted || typeof record.objectId !== "string") return "none";

  // Marked before the `Delete`, so a record that can't be cleared afterwards still reads as gone.
  let revision: string;
  try {
    const marked = await store.compareAndSet(key, existing.revision, { ...record, retracted: true } satisfies FederationRecord);
    if (!marked.applied) return "none";
    revision = marked.revision;
  } catch {
    warn(`couldn't update ${key}: not taken back from followers`);
    return "none";
  }
  const result = await retract(record.objectId);
  try {
    if (result === retracted) {
      await store.compareAndDelete(key, revision);
    } else {
      // Still with followers: put the record back, so a later publish updates it.
      await store.compareAndSet(key, revision, record);
    }
  } catch {
    if (result !== retracted) warn(`couldn't restore ${key}: a later publish posts it afresh`);
  }
  return result;
}
