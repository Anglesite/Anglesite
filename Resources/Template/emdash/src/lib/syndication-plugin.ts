/**
 * `anglesite-syndication`: sends an EmDash article out when it is published (#2168), the
 * Worker-side counterpart of Publish Site's post-deploy passes, which never see an EmDash
 * article. A native EmDash plugin, registered by the overlay's `astro.config.ts` and bundled into
 * the Worker, so it reaches the Worker's own bindings (`cloudflare:workers`).
 *
 * EmDash runs these hooks after its response, for an editor's action and a scheduled publish
 * alike, so nothing here slows publishing down or can stop it (`errorPolicy: "continue"`).
 *
 * - `content:afterPublish`: the article goes out through `syndicatePublishedPost` in
 *   `worker/worker.ts`. ActivityPub followers get it as a new post the first time and as an
 *   `Update` after that (#2174); Webmention and WebSub go out on every publish.
 * - `content:afterUnpublish` and `content:afterDelete`: followers get a `Delete` of the post
 *   (#2174). Publishing it again posts it afresh. The article's URL answers `410 Gone` through an
 *   EmDash redirect rule, and the sites it linked to are re-sent its Webmentions so they drop
 *   their mentions (#2221, Webmention §3.1.5). Publishing it again lifts the rule; the article
 *   then goes out from a one-shot task once EmDash's redirect cache can no longer serve the `410`
 *   from another isolate (`REDIRECT_CACHE_WAIT_MS`), rather than straight away.
 * - `cron`: runs those deferred sends.
 *
 * Which of those applies is kept in this plugin's KV (`federation-record.ts`,
 * `removal-record.ts`).
 */
import { definePlugin } from "emdash";
import { env, waitUntil } from "cloudflare:workers";
import {
  newPostObjectIri,
  notifyLinkedSitesOfRemoval,
  retractFromFollowers,
  syndicatePublishedPost,
  type WorkerEnv,
} from "../../worker/worker.ts";
import { readConfig } from "../../scripts/config.ts";
import { articlePath, federatedKey, publishedArticle, syndicationOrigin, type PublishedRecord } from "./published-article.ts";
import { retractRecorded, syndicateRecorded, type RecordStore } from "./federation-record.ts";
import {
  REDIRECT_CACHE_WAIT_MS,
  articleKey,
  deferredEntry,
  deferredTaskName,
  recordPublished,
  recordRemoved,
  type GoneRules,
  type PathStore,
} from "./removal-record.ts";

/** The Worker's background-work context, for the social handlers that take one. */
const executionContext = {
  waitUntil,
  passThroughOnException() {},
  props: {},
} as unknown as ExecutionContext;

/** Within the 30 seconds a Worker keeps running after its response. */
const HOOK_TIMEOUT_MS = 25_000;

const workerEnv = () => env as unknown as WorkerEnv;

/** The site's canonical origin, or `null` (then nothing goes out). */
const originFor = (siteURL: string) => syndicationOrigin(workerEnv().SITE_URL, readConfig("SITE_URL"), siteURL);

/** The slice of EmDash's plugin context these hooks use. */
interface HookContext {
  kv: RecordStore & PathStore;
  /** Present with the `redirects:write` capability. */
  redirects?: GoneRules | undefined;
  site: { url: string };
  log: { info(message: string): void; warn(message: string): void };
}

/** The context's one-shot task scheduler, which EmDash gives every plugin. */
interface Scheduler {
  schedule(name: string, options: { schedule: string; data?: Record<string, unknown> }): Promise<void>;
}

/** Sends a published entry out, and logs what reached whom. */
async function syndicateEntry(record: PublishedRecord, ctx: HookContext): Promise<void> {
  const origin = originFor(ctx.site.url);
  const article = origin ? publishedArticle(record, origin) : null;
  if (!origin || !article) return;
  const outcome = await syndicateRecorded(
    ctx.kv, federatedKey(record.id), article.published,
    () => newPostObjectIri(origin),
    (federation) => syndicatePublishedPost(article, workerEnv(), executionContext, { origin, federation }),
    { warn: (message) => ctx.log.warn(message) },
  );
  ctx.log.info(
    `syndicated ${article.url} (entry ${String(record.id)}): ActivityPub ${outcome.activityPub}, ` +
      `Webmentions ${outcome.webmentions.delivered}/${outcome.webmentions.targets}` +
      `${outcome.webmentions.failed ? " (failed)" : ""}, WebSub ${outcome.websub}`,
  );
}

/**
 * Takes a removed article back: its URL answers `410`, then the sites it linked to are told and
 * followers are sent a `Delete` (when it was posted to them), side by side, so a slow re-send
 * can't use up the hook's time before followers hear. `slug` is the event's, when it has one.
 */
async function retract(id: unknown, slug: unknown, ctx: HookContext, reason: string): Promise<void> {
  const origin = originFor(ctx.site.url);
  if (!origin) return;
  const warn = (message: string) => ctx.log.warn(message);
  const path = await recordRemoved(
    ctx.kv, ctx.redirects, articleKey(id), typeof slug === "string" && slug !== "" ? articlePath(slug) : null, { warn },
  );
  const webmentions = async () => {
    if (!path) return;
    const resent = await notifyLinkedSitesOfRemoval(`${origin}${path}`, workerEnv());
    ctx.log.info(
      `${reason} entry ${String(id)}: ${path} answers 410; Webmentions ` +
        (resent === "unavailable" ? "unavailable" : `${resent.delivered}/${resent.targets}${resent.failed ? " (failed)" : ""}`),
    );
  };
  const followers = async () => {
    const result = await retractRecorded(
      ctx.kv, federatedKey(id),
      (objectId) => retractFromFollowers(objectId, workerEnv(), executionContext, origin),
      "retracted",
      { warn },
    );
    if (result !== "none") ctx.log.info(`${reason} entry ${String(id)}: ActivityPub ${result}`);
  };
  for (const settled of await Promise.allSettled([webmentions(), followers()])) {
    if (settled.status === "rejected") warn(`${reason} entry ${String(id)}: ${String(settled.reason)}`);
  }
}

export function createPlugin() {
  return definePlugin({
    id: "anglesite-syndication",
    version: "0.3.0",
    // EmDash runs content hooks only for a plugin that may read content; a removed article's
    // `410` is an EmDash redirect rule.
    capabilities: ["content:read", "redirects:write"],
    hooks: {
      "content:afterPublish": {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          const origin = originFor(ctx.site.url);
          const record = event.content as PublishedRecord;
          const article = origin ? publishedArticle(record, origin) : null;
          if (!origin || !article) return;

          const lifted = await recordPublished(
            ctx.kv, ctx.redirects, articleKey(record.id), new URL(article.url).pathname,
            { warn: (message) => ctx.log.warn(message) },
          );
          // Another isolate can still answer 410 from its redirect cache, and a site fetching the
          // article then would drop the mention. So it goes out once no cache can.
          const task = lifted === "lifted" ? deferredTaskName(record.id) : null;
          const scheduler = (ctx as { cron?: Scheduler }).cron;
          if (task && scheduler) {
            try {
              const at = new Date(Date.now() + REDIRECT_CACHE_WAIT_MS).toISOString();
              await scheduler.schedule(task, { schedule: at, data: { id: record.id } });
              ctx.log.info(`${article.url} is published again: its 410 is lifted, and it goes out at ${at}`);
              return;
            } catch {
              ctx.log.warn(`couldn't hold ${article.url} back until its 410 has cleared: it goes out now`);
            }
          } else if (lifted === "lifted") {
            ctx.log.info(`${article.url} is published again: its 410 is lifted`);
          }
          await syndicateEntry(record, ctx);
        },
      },
      "content:afterUnpublish": {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          const record = event.content as PublishedRecord;
          await retract(record.id, record.slug, ctx, "unpublished");
        },
      },
      // Fires when an article goes to the trash (`permanent: false`) and again when it is deleted
      // for good. Taking it back at the trash is safe because EmDash restores an entry as a draft
      // (`ContentRepository.restore`), so a restored article is never live behind its 410; its
      // next publish lifts it. check-emdash-gate-runtime.mjs walks trash → restore → publish.
      "content:afterDelete": {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          await retract(event.id, null, ctx, "deleted");
        },
      },
      // A republished article's deferred send (above). It goes out only if it is still published.
      cron: {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          const id = deferredEntry(event.name, event.data);
          if (!id) return;
          const item = await ctx.content?.get("articles", id);
          if (item?.status !== "published") {
            ctx.log.info(`entry ${id} isn't published any more: its deferred send is dropped`);
            return;
          }
          await syndicateEntry(item as PublishedRecord, ctx);
        },
      },
    },
  });
}
