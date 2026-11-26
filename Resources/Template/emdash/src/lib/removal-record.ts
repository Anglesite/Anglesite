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
  groupName: string | null;
}

/** The slice of EmDash's plugin `RedirectAccessWithWrite` the record uses. */
export interface GoneRules {
  create(input: { source: string; type: 410; groupName: string }): Promise<unknown>;
  get(id: string): Promise<{ redirect: GoneRule; _rev: string } | null>;
  delete(id: string, options: { _rev: string }): Promise<boolean>;
  list(options: { search: string }): Promise<{ items: GoneRule[] }>;
}

/** What the record holds. */
export interface ArticleRecord {
  /** The path the article was last published at. */
  path: string;
}

/** The group EmDash's admin lists these rules under, and how this tells its rules from the owner's. */
export const GONE_RULE_GROUP = "Removed articles (Anglesite)";

/** What the record couldn't do, for the plugin's log. */
export type RemovalWarning = (message: string) => void;

/** The plugin-KV key of an entry's record. `null` for an entry without an id. */
export function articleKey(id: unknown): string | null {
  return typeof id === "string" && id !== "" ? `article:${id}` : null;
}

/** The rule for exactly `path`, if there is one. */
async function ruleFor(rules: GoneRules, path: string): Promise<GoneRule | undefined> {
  return (await rules.list({ search: path })).items.find((rule) => rule.source === path);
}

const isOurs = (rule: GoneRule) => rule.type === 410 && rule.groupName === GONE_RULE_GROUP;

/**
 * Records that the entry under `key` was published at `path`, and lifts the `410` this added
 * there when it was removed, so the article answers again before it is syndicated. A rule left at
 * an old path (the article came back under a new slug) stays: that URL is still gone. A `410` the
 * owner made for the path is theirs, and stays (warned about). `lifted` when a rule came down.
 */
export async function recordPublished(
  store: PathStore,
  rules: GoneRules | undefined,
  key: string | null,
  path: string,
  { warn = () => {} }: { warn?: RemovalWarning } = {},
): Promise<"lifted" | "none"> {
  let outcome: "lifted" | "none" = "none";
  if (rules) {
    try {
      const rule = await ruleFor(rules, path);
      if (rule && isOurs(rule)) {
        const current = await rules.get(rule.id);
        if (current) await rules.delete(rule.id, { _rev: current._rev });
        outcome = "lifted";
      } else if (rule?.type === 410) {
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
 * owner's (left as it is, warned about), since a redirect they made isn't a removal.
 */
export async function recordRemoved(
  store: PathStore,
  rules: GoneRules | undefined,
  key: string | null,
  pathHint: string | null,
  { warn = () => {} }: { warn?: RemovalWarning } = {},
): Promise<string | null> {
  if (!rules) return null;
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
    const existing = await ruleFor(rules, path);
    // Already ours: an unpublish, then a delete. The first one told the linked sites.
    if (existing && isOurs(existing)) return null;
    if (existing && existing.type !== 410) {
      warn(`${path} has a redirect of its own: left as it is, and linked sites aren't told it was removed`);
      return null;
    }
    // The owner's own 410 answers Gone already.
    if (!existing) await rules.create({ source: path, type: 410, groupName: GONE_RULE_GROUP });
  } catch {
    warn(`couldn't make ${path} answer 410: linked sites aren't told it was removed`);
    return null;
  }
  return path;
}
