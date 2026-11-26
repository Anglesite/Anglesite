/**
 * What lets a removed article answer `410 Gone` (#2221), kept apart from the EmDash plugin so it
 * can be tested without EmDash. Dependency-free on purpose: the template's `npm test` runs this
 * with no EmDash install.
 *
 * Webmention §3.1.5 asks a site to re-send a deleted post's Webmentions once the post answers
 * `410`, so each linked site drops its mention. EmDash's redirect middleware answers a rule of
 * type `410` before any route renders, so unpublishing or deleting an article adds one for its
 * path, and publishing it again lifts it. The rules are grouped, so they are visible in EmDash's
 * admin as removed articles, and a rule the owner made for the same path is never touched.
 *
 * The rules are found by path and group rather than remembered, so a lost write can't leave an
 * article answering `410` after it is published again. One KV entry per EmDash entry keeps only
 * the path it was last published at, which a deletion's event doesn't carry.
 */

/** The slice of EmDash's plugin `KVAccess` the record uses. */
export interface PathStore {
  get<T>(key: string): Promise<T | null>;
  set(key: string, value: unknown): Promise<void>;
}

/** One redirect rule, as EmDash's `RedirectInfo` has it. */
export interface GoneRule {
  id: string;
  source: string;
  type: number;
  enabled: boolean;
  groupName: string | null;
}

/**
 * The slice of EmDash's plugin `RedirectAccess` the record uses. `create` and `delete` are there
 * only with `redirects:write`; without them nothing is added or lifted.
 */
export interface GoneRules {
  create?(input: { source: string; type: 410; groupName: string }): Promise<unknown>;
  get(id: string): Promise<{ redirect: GoneRule; _rev: string } | null>;
  delete?(id: string, options: { _rev: string }): Promise<boolean>;
  list(options: { search: string; limit?: number; cursor?: string }): Promise<{ items: GoneRule[]; cursor?: string; hasMore?: boolean }>;
}

/** What the record holds. */
export interface ArticleRecord {
  /** The path the article was last published at. */
  path: string;
}

/** The group EmDash's admin lists these rules under, and how this tells its rules from the owner's. */
export const GONE_RULE_GROUP = "Removed articles (Anglesite)";

/**
 * How long EmDash may keep serving a lifted `410` from an isolate that cached it
 * (`REDIRECT_CACHE_TTL_MS`, 30 s), with a margin. A republished article goes out after this.
 */
export const REDIRECT_CACHE_WAIT_MS = 35_000;

/** What the record couldn't do, for the plugin's log. */
export type RemovalWarning = (message: string) => void;

/** The plugin-KV key of an entry's record. `null` for an entry without an id. */
export function articleKey(id: unknown): string | null {
  return typeof id === "string" && id !== "" ? `article:${id}` : null;
}

/** The deferred-syndication task for an entry (EmDash task names: a letter, then `[A-Za-z0-9_-]`). */
const DEFERRED_PREFIX = "resyndicate-";
export function deferredTaskName(id: unknown): string | null {
  return typeof id === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(id) ? `${DEFERRED_PREFIX}${id}` : null;
}
/** The entry a deferred-syndication task is for, or `null` for any other task. */
export function deferredEntry(name: string, data: Record<string, unknown> | undefined): string | null {
  if (!name.startsWith(DEFERRED_PREFIX)) return null;
  const id = data?.id;
  return typeof id === "string" && deferredTaskName(id) === name ? id : null;
}

/** `path` without a trailing slash: EmDash's middleware answers a rule at either spelling. */
const withoutSlash = (path: string) => (path.length > 1 && path.endsWith("/") ? path.slice(0, -1) : path);

/**
 * Every rule whose source governs `path`, at either spelling, enabled or not, through every page
 * of the listing (a `LIKE` over sources and destinations, so other rows can come first).
 */
async function rulesFor(rules: GoneRules, path: string): Promise<GoneRule[]> {
  const bare = withoutSlash(path);
  const found: GoneRule[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 100; page++) {
    const result = await rules.list({ search: bare, limit: 100, ...(cursor ? { cursor } : {}) });
    found.push(...result.items.filter((rule) => withoutSlash(rule.source) === bare));
    if (!result.hasMore || !result.cursor) break;
    cursor = result.cursor;
  }
  return found;
}

const isOurs = (rule: GoneRule) => rule.type === 410 && rule.groupName === GONE_RULE_GROUP;

/**
 * Records that the entry under `key` was published at `path`, and lifts every `410` this added
 * there when it was removed, so the article answers again. A rule left at an old path (the
 * article came back under a new slug) stays: that URL is still gone. A `410` the owner made for
 * the path is theirs, and stays (warned about). `lifted` only when a rule actually came down.
 */
export async function recordPublished(
  store: PathStore,
  rules: GoneRules | undefined,
  key: string | null,
  path: string,
  { warn = () => {} }: { warn?: RemovalWarning } = {},
): Promise<"lifted" | "none"> {
  let outcome: "lifted" | "none" = "none";
  if (rules?.delete) {
    try {
      const governing = await rulesFor(rules, path);
      for (const rule of governing.filter(isOurs)) {
        const current = await rules.get(rule.id);
        if (current && (await rules.delete(rule.id, { _rev: current._rev }))) {
          outcome = "lifted";
        } else if (current) {
          warn(`couldn't lift the 410 for ${rule.source}: it answers Gone until the next publish lifts it`);
        }
      }
      if (governing.some((rule) => rule.enabled && rule.type === 410 && !isOurs(rule))) {
        warn(`${path} has a 410 of its own: the article answers Gone until it is removed in EmDash's redirects`);
      }
    } catch {
      warn(`couldn't lift the 410 for ${path}: it answers Gone until the next publish lifts it`);
    }
  }
  if (key) {
    try {
      await store.set(key, { path } satisfies ArticleRecord);
    } catch {
      warn(`couldn't record ${key}: a later deletion of it isn't told to the sites it links to`);
    }
  }
  return outcome;
}

/**
 * Makes the entry under `key` answer `410` at its path (`pathHint`, or the one recorded at its
 * last publish), and returns that path once it does, for the Webmention re-send. `null` when
 * there's nothing to tell: no path known, already removed, or the path has a redirect of the
 * owner's (left as it is, warned about), since a redirect they made isn't a removal. Only enabled
 * rules answer, so a turned-off one counts as none; but one at the same source blocks a new rule.
 */
export async function recordRemoved(
  store: PathStore,
  rules: GoneRules | undefined,
  key: string | null,
  pathHint: string | null,
  { warn = () => {} }: { warn?: RemovalWarning } = {},
): Promise<string | null> {
  if (!rules?.create) return null;
  let path = pathHint;
  if (!path && key) {
    try {
      path = (await store.get<ArticleRecord>(key))?.path ?? null;
    } catch {
      warn(`couldn't read ${key}: linked sites aren't told it was removed`);
    }
  }
  if (!path) return null;

  try {
    const governing = await rulesFor(rules, path);
    const enabled = governing.filter((rule) => rule.enabled);
    // Already ours: an unpublish, then a delete. The first one told the linked sites.
    if (enabled.some(isOurs)) return null;
    if (enabled.some((rule) => rule.type !== 410)) {
      warn(`${path} has a redirect of its own: left as it is, and linked sites aren't told it was removed`);
      return null;
    }
    // The owner's own 410 answers Gone already.
    if (enabled.length > 0) return path;
    if (governing.some((rule) => rule.source === path)) {
      warn(`${path} has a turned-off redirect in EmDash: left as it is, and linked sites aren't told it was removed`);
      return null;
    }
    await rules.create({ source: path, type: 410, groupName: GONE_RULE_GROUP });
  } catch {
    warn(`couldn't make ${path} answer 410: linked sites aren't told it was removed`);
    return null;
  }
  return path;
}
