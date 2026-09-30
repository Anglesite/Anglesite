// Builds the public GitHub issue from the allowlist in design §5. Everything that reaches
// `davidwkeith/workers` passes through here, so this is the file to review for privacy.
//
// Kept: exception class, package/template frames (trimmed path, line, column, function name),
// package name, catalog commit the site registered with, occurrence count, first/last seen.
// Dropped: the exception message, owner and third-party frames, request data, logs, attributes,
// site hostname, account id — none of it is ever read into the inputs of this module.

import type { ClassifiedFrame } from "./attribute.js";

export interface ReportInput {
  packageName: string;
  exceptionClass?: string;
  frames: ClassifiedFrame[];
  /** Site-independent grouping key (see `crossSiteFingerprint`). */
  fingerprint: string;
  count?: number;
  firstSeen?: string;
  lastSeen?: string;
  catalogCommit?: string;
}

export const MARKER_PREFIX = "anglesite-issues fingerprint=";
export const SOURCE_LABEL = "source:anglesite-issues";

export function marker(fingerprint: string): string {
  return `<!-- ${MARKER_PREFIX}${fingerprint} -->`;
}

export function packageLabel(packageName: string): string {
  return `pkg:${packageName.replace(/^@dwk\//, "")}`;
}

export function issueTitle(input: ReportInput): string {
  const top = input.frames.find((f) => f.kind === "package");
  const where = top ? ` in ${top.fn ?? "<anonymous>"} (${basename(top.publicPath!)}:${top.line})` : "";
  return `[${input.packageName}] ${input.exceptionClass ?? "Error"}${where}`;
}

export function issueBody(input: ReportInput): string {
  const lines = [
    marker(input.fingerprint),
    `An Anglesite site running \`${input.packageName}\` hit a production error that Workers Issues grouped and the relay attributed to this package.`,
    "",
    "| | |",
    "|---|---|",
    `| Exception | \`${input.exceptionClass ?? "unknown"}\` (message withheld for privacy) |`,
    `| Occurrences (this site) | ${input.count ?? "unknown"} |`,
    `| First seen | ${input.firstSeen ?? "unknown"} |`,
    `| Last seen | ${input.lastSeen ?? "unknown"} |`,
    `| Catalog commit | ${input.catalogCommit ? `\`${input.catalogCommit}\`` : "unknown"} |`,
    "",
    "### Stack (innermost first)",
    "",
    "```",
    ...stackLines(input.frames),
    "```",
    "",
    "Only `@dwk/*` and template frames are shown; the site owner's own code, third-party dependencies, request data and logs never leave their Cloudflare account.",
  ];
  return lines.join("\n");
}

export function occurrenceComment(input: ReportInput): string {
  return [
    `Reported again: ${input.count ?? "unknown"} occurrences on one site, last seen ${input.lastSeen ?? "unknown"}` +
      (input.catalogCommit ? ` (catalog \`${input.catalogCommit}\`).` : "."),
  ].join("\n");
}

function stackLines(frames: ClassifiedFrame[]): string[] {
  const out: string[] = [];
  let omitted = 0;
  const flush = () => {
    if (omitted > 0) out.push(`    … ${omitted} frame${omitted === 1 ? "" : "s"} omitted`);
    omitted = 0;
  };
  for (const frame of frames) {
    if (frame.publicPath) {
      flush();
      const position = frame.column === undefined ? `${frame.line}` : `${frame.line}:${frame.column}`;
      out.push(`    at ${frame.fn ?? "<anonymous>"} (${frame.publicPath}:${position})`);
    } else {
      omitted++;
    }
  }
  flush();
  return out;
}

/**
 * Site-independent fingerprint. Cloudflare groups per Worker, i.e. per site, so its own id can't
 * de-duplicate one package bug hit by N sites. This keys on the package, exception class and the
 * package frames' file + function (not line numbers, which shift between package versions).
 */
export async function crossSiteFingerprint(input: Pick<ReportInput, "packageName" | "exceptionClass" | "frames">): Promise<string> {
  const packageFrames = input.frames
    .filter((f) => f.kind === "package")
    .slice(0, 3)
    .map((f) => `${f.publicPath}#${f.fn ?? ""}`);
  const key = [input.packageName, input.exceptionClass ?? "", ...packageFrames].join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return [...new Uint8Array(digest)].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function basename(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}
