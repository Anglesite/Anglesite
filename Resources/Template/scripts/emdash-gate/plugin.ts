/**
 * `anglesite-gate`: the EmDash plugin that runs the pre-deploy gate's content checks before an
 * entry goes live (#2055 slice 3). Shaped as EmDash's `SandboxedPlugin` default export and kept
 * dependency-free here, under the D5 hash pin; `JS/anglesite-gate/` holds it to EmDash's real
 * types, carries the manifest, bundles it with `@emdash-cms/plugin-cli`, and tests it through
 * EmDash's content pipeline (#2061).
 *
 * Only publish and schedule are gated. `content:beforeUnpublish` is deliberately not registered:
 * taking an entry down — a correction, a retraction, a legal takedown — must never be blocked by
 * the gate. EmDash re-runs `content:beforePublish` when a scheduled entry comes due, so an entry
 * scheduled before a check changed is checked again at publication time.
 *
 * Both hooks keep EmDash's default `errorPolicy: "abort"`: if the gate itself throws, the action
 * fails instead of publishing unchecked.
 */

import { decidePublish, type PublishPolicyEvent } from "./policy";

const plugin = {
  hooks: {
    "content:beforePublish": async (event: PublishPolicyEvent) => decidePublish(event),
    "content:beforeSchedule": async (event: PublishPolicyEvent) => decidePublish(event),
  },
};

export default plugin;
