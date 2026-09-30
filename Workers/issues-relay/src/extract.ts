// The one place that knows the shape of a Workers Issues generic-webhook delivery (#2095).
//
// Slice 0's capture (docs/specs/2026-09-30-workers-issues-payload-spike-notes.md) has not pinned
// the field names yet, so extraction is deliberately encoding-agnostic: it walks the whole JSON
// body and accepts frames as structured objects or as V8 `at fn (file:line:col)` text, and a
// grouping id under any fingerprint/issue-id-looking key. When the capture lands, tighten this
// module (and only this module) to the real fields.
//
// Never extracted: the exception *message*, request data, logs, span attributes (design §5).

export interface Frame {
  file: string;
  line: number;
  column?: number;
  fn?: string;
}

export interface ExtractedIssue {
  /** Innermost frame first, as V8 prints them. Empty → "no stack, no filing". */
  frames: Frame[];
  /** Exception class name (`TypeError`), never its message. */
  exceptionClass?: string;
  /** Cloudflare's grouping id, when the payload carries one. */
  fingerprint?: string;
  /** Absolute occurrence count snapshot. */
  count?: number;
  firstSeen?: string;
  lastSeen?: string;
}

const FINGERPRINT_KEY = /fingerprint|issue_?id/i;
const COUNT_KEY = /^(count|occurrences?|occurrence_count|occurrenceCount|total)$/i;
const FIRST_SEEN_KEY = /^(first_?seen|firstSeen|first_failed|first_fired)$/i;
const LAST_SEEN_KEY = /^(last_?seen|lastSeen|last_failed)$/i;
const CLASS_KEY = /^(exception_?(class|type|name)|error_?(class|type|name)|type)$/i;
// V8 stack line: `at fn (file:line:col)` or `at file:line:col`.
const STACK_LINE = /at\s+(?:(\S+)\s+\()?([^\s()]+?):(\d+):(\d+)\)?/g;
// First line of a V8 stack: `ClassName: message` — only the class is kept.
const STACK_HEADER = /^([A-Z][A-Za-z0-9_$]*(?:Error|Exception))(?::|$)/;
const CLASS_NAME = /^[A-Z][A-Za-z0-9_$]*(?:Error|Exception)$/;

export function extractIssue(payload: unknown): ExtractedIssue {
  const result: ExtractedIssue = { frames: [] };
  const structuredFrames: Frame[] = [];
  const textFrames: Frame[] = [];

  const visit = (value: unknown, key: string): void => {
    if (Array.isArray(value)) {
      value.forEach((item) => visit(item, key));
      return;
    }
    if (value !== null && typeof value === "object") {
      const record = value as Record<string, unknown>;
      const frame = structuredFrame(record);
      if (frame) structuredFrames.push(frame);
      for (const [childKey, child] of Object.entries(record)) visit(child, childKey);
      return;
    }
    if (typeof value === "string") {
      if (FINGERPRINT_KEY.test(key)) result.fingerprint ??= value;
      if (FIRST_SEEN_KEY.test(key)) result.firstSeen ??= value;
      if (LAST_SEEN_KEY.test(key)) result.lastSeen ??= value;
      if (CLASS_KEY.test(key) && CLASS_NAME.test(value)) result.exceptionClass ??= value;
      const header = value.match(STACK_HEADER);
      const lines = [...value.matchAll(STACK_LINE)];
      if (lines.length > 0) {
        if (header) result.exceptionClass ??= header[1];
        for (const match of lines) {
          textFrames.push({
            fn: match[1],
            file: match[2]!,
            line: Number(match[3]),
            column: Number(match[4]),
          });
        }
      }
    }
    if (typeof value === "number") {
      if (FINGERPRINT_KEY.test(key)) result.fingerprint ??= String(value);
      if (COUNT_KEY.test(key)) result.count ??= value;
    }
  };
  visit(payload, "");

  // Prefer structured frames; fall back to stack text. Never mix, or a payload that carries
  // both would list every frame twice.
  result.frames = structuredFrames.length > 0 ? structuredFrames : textFrames;
  return result;
}

function structuredFrame(record: Record<string, unknown>): Frame | undefined {
  const file = firstOf<string>(record, ["filename", "fileName", "file", "source", "script_url"], "string");
  const line = firstOf<number>(record, ["lineno", "lineNumber", "line"], "number");
  if (file === undefined || line === undefined) return undefined;
  return {
    file,
    line,
    column: firstOf<number>(record, ["colno", "columnNumber", "column", "col"], "number"),
    fn: firstOf<string>(record, ["function", "functionName", "fn"], "string"),
  };
}

function firstOf<T>(record: Record<string, unknown>, keys: string[], type: "string" | "number"): T | undefined {
  for (const key of keys) if (typeof record[key] === type) return record[key] as T;
  return undefined;
}
