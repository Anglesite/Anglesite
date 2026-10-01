// Answers the slice 0 question for #2095: does an Issues automation's generic-webhook payload
// carry what the relay needs (design §8 Q2)? Pure function over the parsed JSON body, so the
// same rules run in tests against synthetic payloads and in the Worker against real captures.

/** One stack frame found in the payload, however it was encoded. */
export interface FoundFrame {
  /** JSON path where the frame was found, e.g. `data.stack[0]` or `text`. */
  path: string;
  file: string;
  line?: number;
  column?: number;
  fn?: string;
}

export interface PayloadAnalysis {
  /** Every leaf key path in the payload (array indexes collapsed to `[]`), sorted. */
  keyPaths: string[];
  /** Frames recovered from structured frame objects or from `at …` stack-trace text. */
  frames: FoundFrame[];
  /** Whether any frame path ends in `.ts`/`.tsx`, i.e. came back source-mapped. */
  sourceMapped: boolean;
  /** Whether any frame points into the stand-in `@dwk` package (`dwk-spike-pkg`). */
  hasPackageFrame: boolean;
  /** Key paths whose name looks like a stable grouping id (fingerprint / issue id). */
  fingerprintPaths: string[];
  /** Key paths that look like visitor data the relay must drop (§5). */
  sensitivePaths: string[];
  /** Whether the exception class name (`SpikePackageError`) appears anywhere. */
  hasExceptionClass: boolean;
  /** Slice 2 viability under the design's "no stack, no filing" rule. */
  verdict: "viable" | "no-stack" | "no-fingerprint";
}

const FINGERPRINT_KEY = /fingerprint|issue_?id|group(ing)?_?(id|key)|^id$/i;
const SENSITIVE_KEY = /url|header|cookie|(^|_)ip($|_)|user.?agent|query|body|user\.id|account\.id|session|email|host/i;
// `at fn (file:line:col)` or `at file:line:col` — V8's stack-trace line shape.
const STACK_LINE = /at\s+(?:(\S+)\s+\()?([^\s()]+?):(\d+):(\d+)\)?/g;

export function analyzePayload(payload: unknown): PayloadAnalysis {
  const keyPaths = new Set<string>();
  const frames: FoundFrame[] = [];
  const fingerprintPaths = new Set<string>();
  const sensitivePaths = new Set<string>();
  let hasExceptionClass = false;

  const visit = (value: unknown, path: string, key: string): void => {
    const collapsed = path.replace(/\[\d+\]/g, "[]");
    if (key && FINGERPRINT_KEY.test(key)) fingerprintPaths.add(collapsed);
    if (key && SENSITIVE_KEY.test(key)) sensitivePaths.add(collapsed);

    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, `${path}[${index}]`, key));
      return;
    }
    if (value !== null && typeof value === "object") {
      const record = value as Record<string, unknown>;
      const frame = structuredFrame(record);
      if (frame) frames.push({ path, ...frame });
      for (const [childKey, child] of Object.entries(record)) {
        visit(child, path ? `${path}.${childKey}` : childKey, childKey);
      }
      return;
    }
    keyPaths.add(collapsed);
    if (typeof value === "string") {
      if (value.includes("SpikePackageError")) hasExceptionClass = true;
      for (const match of value.matchAll(STACK_LINE)) {
        frames.push({
          path,
          fn: match[1],
          file: match[2],
          line: Number(match[3]),
          column: Number(match[4]),
        });
      }
    }
  };
  visit(payload, "", "");

  const sourceMapped = frames.some((f) => /\.tsx?$/.test(f.file));
  const hasPackageFrame = frames.some((f) => f.file.includes("dwk-spike-pkg"));
  const verdict =
    frames.length === 0 ? "no-stack" : fingerprintPaths.size === 0 ? "no-fingerprint" : "viable";

  return {
    keyPaths: [...keyPaths].sort(),
    frames,
    sourceMapped,
    hasPackageFrame,
    fingerprintPaths: [...fingerprintPaths].sort(),
    sensitivePaths: [...sensitivePaths].sort(),
    hasExceptionClass,
    verdict,
  };
}

/** A frame object in any of the common encodings (`filename`/`file`/`url` + line/column). */
function structuredFrame(record: Record<string, unknown>): Omit<FoundFrame, "path"> | undefined {
  const file = firstString(record, ["filename", "fileName", "file", "source", "script_url"]);
  const line = firstNumber(record, ["lineno", "lineNumber", "line"]);
  if (file === undefined || line === undefined) return undefined;
  return {
    file,
    line,
    column: firstNumber(record, ["colno", "columnNumber", "column", "col"]),
    fn: firstString(record, ["function", "functionName", "fn", "name"]),
  };
}

function firstString(record: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) if (typeof record[key] === "string") return record[key] as string;
  return undefined;
}

function firstNumber(record: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) if (typeof record[key] === "number") return record[key] as number;
  return undefined;
}
