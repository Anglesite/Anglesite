/**
 * The EmDash site's Worker entry (#2050). Astro's Cloudflare handler serves the site;
 * EmDash's scheduled handler runs on the Worker's cron trigger and publishes scheduled
 * articles when they come due. EmDash re-runs `content:beforePublish` at that point, so
 * `anglesite-gate` checks a scheduled article again when it goes live.
 *
 * The site's social endpoints (Webmention, IndieAuth, ActivityPub…) run in this same Worker
 * (#2162): a request for one of the template Worker's routes goes to its handler, and so do its
 * queues and its crons. Anglesite binds only the features the site has turned on; a route whose
 * feature is off answers as it does on any other Anglesite site.
 */
import handler from "@astrojs/cloudflare/entrypoints/server";
import { createScheduledHandler } from "@emdash-cms/cloudflare/worker";
import social, { matchRoute } from "../worker/worker.ts";

// EmDash's sandbox runner reaches this through the Worker's own exports to give each sandboxed
// (marketplace) plugin its scoped bridge. It only does anything on a Worker with a `LOADER`
// Worker Loader binding (#2106): an existing EmDash install connected to Anglesite keeps its
// marketplace plugins that way.
export { PluginBridge } from "@emdash-cms/cloudflare/worker";
// The social endpoints' Durable Objects, which Cloudflare looks for in the Worker's own exports.
export { ActivityPubObject, SolidPodObject } from "../worker/worker.ts";

// Nothing else is exported: workerd accepts only handlers and classes as a Worker's exports.

/** EmDash's cron (`EmDashWorkerConfig.cron`). The social crons are the template Worker's. */
const EMDASH_CRON = "* * * * *";

const emdashScheduled = createScheduledHandler({ generalCron: EMDASH_CRON });

/** Whether a request goes to the social endpoints rather than to Astro. */
function isSocialRoute(url: string): boolean {
  return matchRoute(new URL(url).pathname) !== null;
}

type SocialEnv = Parameters<typeof social.fetch>[1];

export default {
  ...handler,
  fetch(request: Request, env: SocialEnv, ctx: ExecutionContext): Promise<Response> {
    if (isSocialRoute(request.url)) return social.fetch(request, env, ctx);
    return handler.fetch(request, env, ctx);
  },
  queue: social.queue,
  async scheduled(controller: ScheduledController, env: SocialEnv, ctx: ExecutionContext): Promise<void> {
    if (controller.cron === EMDASH_CRON) return emdashScheduled(controller, env, ctx);
    return social.scheduled(controller, env, ctx);
  },
};
