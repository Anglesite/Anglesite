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
 *   (#2174). Publishing it again posts it afresh.
 *
 * Which of those applies is kept in this plugin's KV (`federation-record.ts`).
 */
import { definePlugin } from "emdash";
import { env, waitUntil } from "cloudflare:workers";
import { newPostObjectIri, retractFromFollowers, syndicatePublishedPost, type WorkerEnv } from "../../worker/worker.ts";
import { readConfig } from "../../scripts/config.ts";
import { federatedKey, publishedArticle, syndicationOrigin, type PublishedRecord } from "./published-article.ts";
import { retractRecorded, syndicateRecorded, type RecordStore } from "./federation-record.ts";

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
  kv: RecordStore;
  site: { url: string };
  log: { info(message: string): void; warn(message: string): void };
}

/** Takes an article back from followers, when it was posted to them. */
async function retract(id: unknown, ctx: HookContext, reason: string): Promise<void> {
  const origin = originFor(ctx.site.url);
  if (!origin) return;
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
    version: "0.2.0",
    // EmDash runs content hooks only for a plugin that may read content.
    capabilities: ["content:read"],
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
          await retract((event.content as PublishedRecord).id, ctx, "unpublished");
        },
      },
      "content:afterDelete": {
        timeout: HOOK_TIMEOUT_MS,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          await retract(event.id, ctx, "deleted");
        },
      },
    },
  });
}
