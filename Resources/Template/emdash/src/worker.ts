/**
 * The EmDash site's Worker entry (#2050). Astro's Cloudflare handler serves the site;
 * EmDash's scheduled handler runs on the Worker's cron trigger and publishes scheduled
 * articles when they come due. EmDash re-runs `content:beforePublish` at that point, so
 * `anglesite-gate` checks a scheduled article again when it goes live.
 */
import handler from "@astrojs/cloudflare/entrypoints/server";
import { createScheduledHandler } from "@emdash-cms/cloudflare/worker";

export default {
  ...handler,
  scheduled: createScheduledHandler(),
};
