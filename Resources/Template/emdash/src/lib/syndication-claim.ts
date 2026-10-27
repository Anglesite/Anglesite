/**
 * The once-per-entry claim on posting an article to ActivityPub followers (#2168), kept apart
 * from the EmDash plugin so it can be tested without EmDash. Dependency-free on purpose: the
 * template's `npm test` runs this with no EmDash install.
 *
 * The claim is taken before syndicating and given back unless the post reached followers, so a
 * later publish tries again. That covers a step that reports a failure and one that throws. A KV
 * that can't be written still lets the article's Webmentions and WebSub notice go out; it only
 * holds back the ActivityPub post, which can't be guaranteed to go out once.
 */

/** The slice of EmDash's plugin `KVAccess` the claim uses. */
export interface ClaimStore {
  compareAndSet(key: string, expectedRevision: null, value: unknown): Promise<{ applied: true; revision: string } | { applied: false }>;
  compareAndDelete(key: string, expectedRevision: string): Promise<unknown>;
}

/**
 * Runs `syndicate` with `federate` true only if this call took the claim on `key` (`null`: no
 * claim possible, so not federated), and gives the claim back if ActivityPub wasn't published.
 */
export async function syndicateOnce<T extends { activityPub: string }>(
  store: ClaimStore,
  key: string | null,
  value: unknown,
  syndicate: (federate: boolean) => Promise<T>,
): Promise<T> {
  let revision: string | null = null;
  if (key) {
    try {
      const claim = await store.compareAndSet(key, null, value);
      if (claim.applied) revision = claim.revision;
    } catch {
      // Not claimed: the other steps still run.
    }
  }
  const release = async () => {
    if (!key || revision === null) return;
    try {
      await store.compareAndDelete(key, revision);
    } catch {
      // A claim that can't be given back holds this entry's ActivityPub post back; nothing else.
    }
  };
  let outcome: T;
  try {
    outcome = await syndicate(revision !== null);
  } catch (error) {
    await release();
    throw error;
  }
  if (outcome.activityPub !== "published") await release();
  return outcome;
}
