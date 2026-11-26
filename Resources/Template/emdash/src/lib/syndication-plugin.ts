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
 *   their mentions (#2221, Webmention §3.1.5). Publishing it again lifts the rule first.
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
import { articleKey, recordPublished, recordRemoved, type GoneRules, type PathStore } from "./removal-record.ts";

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
  redirects?: GoneRules;
  site: { url: string };
  log: { info(message: string): void; warn(message: string): void };
}

/**
 * Takes a removed article back: its URL answers `410` and the sites it linked to are told, then
 * followers are sent a `Delete`, when it was posted to them. `slug` is the event's, when it has one.
 */
async function retract(id: unknown, slug: unknown, ctx: HookContext, reason: string): Promise<void> {
  const origin = originFor(ctx.site.url);
  if (!origin) return;
  const warn = (message: string) => ctx.log.warn(message);
  const path = await recordRemoved(
    ctx.kv, ctx.redirects, articleKey(id), typeof slug === "string" && slug !== "" ? articlePath(slug) : null, { warn },
  );
  if (path) {
    const resent = await notifyLinkedSitesOfRemoval(`${origin}${path}`, workerEnv());
    ctx.log.info(
      `${reason} entry ${String(id)}: ${path} answers 410; Webmentions ` +
        (resent === "unavailable" ? "unavailable" : `${resent.delivered}/${resent.targets}${resent.failed ? " (failed)" : ""}`),
    );
  }
  const result = await retractRecorded(
    ctx.kv, federatedKey(id),
    (objectId) => retractFromFollowers(objectId, workerEnv(), executionContext, origin),
    "retracted",
    { warn: (message) => ctx.log.warn(message) },
  );
  if (result !== "none") ctx.log.info(`${reason} entry ${String(id)}: ActivityPub ${result}`);
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

          // Answering again before anyone is told it's back.
          const lifted = await recordPublished(
            ctx.kv, ctx.redirects, articleKey(record.id), new URL(article.url).pathname,
            { warn: (message) => ctx.log.warn(message) },
          );
          if (lifted === "lifted") ctx.log.info(`${article.url} is published again: its 410 is lifted`);

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
      "content:afterDelete": {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          await retract(event.id, null, ctx, "deleted");
        },
      },
    },
  });
}
