/**
 * The publish layer of the pre-deploy gate for EmDash sites (#2055 slice 3,
 * docs/specs/2026-09-28-external-cms-content-source-decision.md § Gate): decides whether an
 * EmDash entry may be published or scheduled, using the same pinned checks the deploy scan runs
 * (`../gate-checks.ts`). Pure and runtime-neutral — no Node built-ins — because it runs inside
 * EmDash's plugin sandbox (a Worker isolate on Cloudflare, workerd on Node).
 *
 * `plugin.ts` wires this into EmDash's `content:beforePublish` / `content:beforeSchedule` policy
 * hooks. Those hooks hand over the effective draft (`event.content.data`), so the plugin needs
 * only the `hooks.content-policy:register` capability — no content, schema or network access.
 */

import {
  checkEmbedMedia,
  checkMixedContent,
  checkNoRestrictedContentInDist,
  checkPII,
  checkSecrets,
  type Issue,
} from "../gate-checks";

/** The fields of EmDash's publish/schedule policy event this policy reads. */
export interface PublishPolicyEvent {
  content: { data: unknown; slug?: string | null };
  collection: string;
}

/** EmDash's policy-hook result: `undefined` allows the action; a cancellation rejects it. */
export type PublishDecision = undefined | { cancel: true; reason: string };

/** EmDash rejects a cancellation reason outside 1–500 plain-text characters. */
export const MAX_REASON_LENGTH = 500;

/** Keys whose string values a rendered page loads as a resource (`src="…"`). */
const RESOURCE_KEYS = new Set(["src", "srcset", "url", "poster"]);

/**
 * Flattens an entry's field values into the two shapes the checks read:
 * - `text`: every string value, one per line — what a reader sees, plus link targets. Secrets,
 *   PII and the restricted-audience marker are looked for here, unescaped, so a value can't
 *   slip past a pattern because rendering would have entity-encoded a quote in it.
 * - `html`: only the URL-bearing values, as the attributes a rendered page would carry them in
 *   (`href` as a link, `src`/`url`/… as a resource), so the checks that match on HTML context
 *   (embed hotlinks, mixed content) see the same context they see in `dist/`.
 *
 * Works on any JSON shape, Portable Text included (spans' `text`, `markDefs[].href`, image and
 * embed blocks' URL fields). Keys starting with `_` (`_key`, `_type`, `_ref`) are Portable Text
 * bookkeeping, never rendered, and are skipped.
 */
export function scannableContent(data: unknown): { text: string; html: string } {
  const text: string[] = [];
  const html: string[] = [];
  const visit = (value: unknown, key: string | null): void => {
    if (typeof value === "string") {
      text.push(value);
      if (key === "href") html.push(`<a href="${value}"></a>`);
      else if (key !== null && RESOURCE_KEYS.has(key)) html.push(`<img src="${value}">`);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) visit(item, key);
      return;
    }
    if (typeof value === "object" && value !== null) {
      for (const [childKey, child] of Object.entries(value)) {
        if (childKey.startsWith("_")) continue;
        visit(child, childKey);
      }
    }
  };
  visit(data, null);
  return { text: text.join("\n"), html: html.join("\n") };
}

/**
 * Every issue the gate finds in an entry. `restricted-content-in-dist` is checked against the
 * entry's raw fields, where an audience field (`visibility: contacts`) lives.
 */
export function publishIssues(event: PublishPolicyEvent): Issue[] {
  const file = `${event.collection}/${event.content.slug || "draft"}`;
  const { text, html } = scannableContent(event.content.data);
  let raw = "";
  try {
    raw = JSON.stringify(event.content.data) ?? "";
  } catch {
    // A cyclic value can't come from EmDash's JSON store; if one ever did, the text checks above
    // still ran over everything reachable.
  }
  return [
    ...checkSecrets(text, file),
    ...checkPII(text, file),
    ...checkEmbedMedia(html, file),
    ...checkMixedContent(html, file),
    ...checkNoRestrictedContentInDist(file, raw),
  ];
}

/** What each check's finding means, in the words of the writer who has to fix it. */
const WRITER_REASONS: Record<string, string> = {
  "exposed-token": "it contains what looks like a password, API key or private key",
  "pii-email": "it contains an email address",
  "pii-phone": "it contains a phone number",
  "pii-ssn": "it contains what looks like a Social Security number",
  "embed-media-hotlink": "it loads an image or video straight from a social network — upload the file instead",
  "mixed-content": "it loads an image or media file over http:// — use an https:// address",
  "restricted-content-in-dist": "it is marked for contacts only, and this site doesn't publish restricted posts",
};

/**
 * One plain-text cancellation reason naming each distinct problem once, cut to EmDash's
 * 500-character limit.
 */
export function writerReason(issues: Issue[]): string {
  const parts = [...new Set(issues.map((issue) => WRITER_REASONS[issue.category] ?? issue.message))];
  const reason = `Anglesite can't publish this yet: ${parts.join("; ")}.`;
  return reason.length <= MAX_REASON_LENGTH ? reason : `${reason.slice(0, MAX_REASON_LENGTH - 1)}…`;
}

/**
 * The policy decision. Warnings block too — the same rule as `npm run build:ci`'s `--strict`
 * scan, because nothing downstream re-asks: a published entry is live.
 */
export function decidePublish(event: PublishPolicyEvent): PublishDecision {
  const issues = publishIssues(event);
  return issues.length === 0 ? undefined : { cancel: true, reason: writerReason(issues) };
}
