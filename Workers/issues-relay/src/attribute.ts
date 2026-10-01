// Attribution (design §3): decides whether an issue belongs to a `@dwk/*` package, and trims
// frames to the paths that are safe to publish.
//
// A site's catalog packages are all composed into one Worker, so the frame paths are the only
// signal. Frames are matched on a path *segment*, not a prefix: source-mapped paths come back
// relative to wherever the bundle was built (slice 0 dry-run: `…/src/vendor/…/index.ts`).

import type { Frame } from "./extract.js";

export type FrameKind = "package" | "template" | "dependency" | "runtime" | "owner";

export interface ClassifiedFrame extends Frame {
  kind: FrameKind;
  /** `@dwk/<name>` for a package frame. */
  packageName?: string;
  /** Publishable path, trimmed to start at `@dwk/…` or `worker/…`. Absent for other kinds. */
  publicPath?: string;
}

export type Attribution =
  | { kind: "package"; packageName: string; frames: ClassifiedFrame[] }
  | { kind: "not-filed"; reason: "no-stack" | "template" | "owner-code" | "owner-caller" | "unattributable" };

const PACKAGE_SEGMENT = /(?:^|\/)node_modules\/(@dwk\/[a-z0-9][a-z0-9._-]*)\/(.*)$/i;
// The composed site Worker's own sources (`Resources/Template/worker/`) — template-owned.
const TEMPLATE_SEGMENT = /(?:^|\/)(worker\/[^/].*)$/;
const DEPENDENCY_SEGMENT = /(?:^|\/)node_modules\//;
const RUNTIME = /^(node:|cloudflare:|internal[:/]|native|<anonymous>|wasm:)/;

// Frame text comes from a registered site's payload and ends up in a public issue: only plain
// identifiers and path characters survive, so nothing can inject Markdown or @-mentions.
const SAFE_FN = /^[A-Za-z0-9_$.<>\[\]]{1,120}$/;
const SAFE_PATH = /^[A-Za-z0-9_@.\/-]{1,300}$/;

export function classifyFrame(input: Frame): ClassifiedFrame {
  const frame: Frame = { ...input, fn: input.fn && SAFE_FN.test(input.fn) ? input.fn : undefined };
  const file = frame.file.replace(/^file:\/\//, "");
  if (RUNTIME.test(file)) return { ...frame, kind: "runtime" };
  // Anything that isn't a plain path is never published — and conservatively counts as owner
  // code, which blocks filing rather than risk misattribution.
  if (!SAFE_PATH.test(file)) return { ...frame, kind: "owner" };
  const pkg = file.match(PACKAGE_SEGMENT);
  if (pkg) return { ...frame, kind: "package", packageName: pkg[1]!.toLowerCase(), publicPath: `${pkg[1]}/${pkg[2]}` };
  if (DEPENDENCY_SEGMENT.test(file)) return { ...frame, kind: "dependency" };
  const template = file.match(TEMPLATE_SEGMENT);
  if (template) return { ...frame, kind: "template", publicPath: template[1] };
  return { ...frame, kind: "owner" };
}

/**
 * Files against a package only when (1) the innermost frame that isn't runtime or a third-party
 * dependency is in `@dwk/*`, and (2) no owner-code frame appears anywhere among its callers —
 * owner code calling into a package is more likely owner input than a package bug (§3).
 * Template frames among the callers are fine: the template is what mounts every package.
 */
export function attribute(frames: Frame[]): Attribution {
  if (frames.length === 0) return { kind: "not-filed", reason: "no-stack" };
  const classified = frames.map(classifyFrame);
  const culpritIndex = classified.findIndex((f) => f.kind !== "runtime" && f.kind !== "dependency");
  if (culpritIndex === -1) return { kind: "not-filed", reason: "unattributable" };
  const culprit = classified[culpritIndex]!;
  if (culprit.kind === "template") return { kind: "not-filed", reason: "template" };
  if (culprit.kind === "owner") return { kind: "not-filed", reason: "owner-code" };
  if (classified.slice(culpritIndex + 1).some((f) => f.kind === "owner")) {
    return { kind: "not-filed", reason: "owner-caller" };
  }
  return { kind: "package", packageName: culprit.packageName!, frames: classified };
}
