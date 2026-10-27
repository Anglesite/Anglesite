/**
 * `anglesite-syndication`: sends an EmDash article out when it is published (#2168), the
 * Worker-side counterpart of Publish Site's post-deploy passes, which never see an EmDash
 * article. A native EmDash plugin, registered by the overlay's `astro.config.ts` and bundled into
 * the Worker, so it reaches the Worker's own bindings (`cloudflare:workers`).
 *
 * EmDash runs `content:afterPublish` after the publish response, for an editor's publish and a
 * scheduled one alike, so nothing here slows publishing down or can stop it (`errorPolicy:
 * "continue"`). The article goes out through `syndicatePublishedPost` in `worker/worker.ts`:
 * ActivityPub once per entry (claimed in this plugin's KV first), and Webmention and WebSub on
 * every publish. A failed ActivityPub post gives its claim back, so the next publish tries again
 * (`syndicateOnce`).
 */
import { definePlugin } from "emdash";
import { env, waitUntil } from "cloudflare:workers";
import { syndicatePublishedPost, type WorkerEnv } from "../../worker/worker.ts";
import { readConfig } from "../../scripts/config.ts";
import { federatedKey, publishedArticle, syndicationOrigin, type PublishedRecord } from "./published-article.ts";
import { syndicateOnce } from "./syndication-claim.ts";

/** The Worker's background-work context, for the social handlers that take one. */
const executionContext = {
  waitUntil,
  passThroughOnException() {},
  props: {},
} as unknown as ExecutionContext;

export function createPlugin() {
  return definePlugin({
    id: "anglesite-syndication",
    version: "0.1.0",
    // EmDash runs content hooks only for a plugin that may read content.
    capabilities: ["content:read"],
    hooks: {
      "content:afterPublish": {
        // Within the 30 seconds a Worker keeps running after its response.
        timeout: 25_000,
        errorPolicy: "continue",
        handler: async (event, ctx) => {
          if (event.collection !== "articles") return;
          const workerEnv = env as unknown as WorkerEnv;
          const origin = syndicationOrigin(workerEnv.SITE_URL, readConfig("SITE_URL"), ctx.site.url);
          const record = event.content as PublishedRecord;
          const article = origin ? publishedArticle(record, origin) : null;
          if (!origin || !article) return;

          const outcome = await syndicateOnce(ctx.kv, federatedKey(record), { published: article.published }, (federate) =>
            syndicatePublishedPost(article, workerEnv, executionContext, { origin, federate }),
          );
          ctx.log.info(
            `syndicated ${article.url}: ActivityPub ${outcome.activityPub}, ` +
              `Webmentions ${outcome.webmentions.delivered}/${outcome.webmentions.targets}` +
              `${outcome.webmentions.failed ? " (failed)" : ""}, WebSub ${outcome.websub}`,
          );
        },
      },
    },
  });
}
