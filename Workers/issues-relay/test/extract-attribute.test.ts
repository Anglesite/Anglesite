import { describe, it, expect } from "vitest";
import { extractIssue } from "../src/extract.js";
import { attribute, classifyFrame } from "../src/attribute.js";
import { packageDelivery } from "./support.js";

describe("extractIssue", () => {
  it("pulls frames, class, fingerprint, count and timestamps from stack text — never the message", () => {
    const extracted = extractIssue(packageDelivery());
    expect(extracted.exceptionClass).toBe("TypeError");
    expect(extracted.fingerprint).toBe("cf-fp-1");
    expect(extracted.count).toBe(3);
    expect(extracted.firstSeen).toBe("2026-09-30T10:00:00Z");
    expect(extracted.lastSeen).toBe("2026-09-30T11:00:00Z");
    expect(extracted.frames.map((f) => [f.fn, f.file, f.line])).toEqual([
      ["parseHTML", "node_modules/linkedom/esm/index.js", 5],
      ["verifySource", "node_modules/@dwk/webmention/src/verify.ts", 42],
      ["receive", "node_modules/@dwk/webmention/src/receive.ts", 10],
      ["handle", "worker/worker.ts", 88],
    ]);
    expect(JSON.stringify(extracted)).not.toContain("jane@example.com");
    expect(JSON.stringify(extracted)).not.toContain("reading 'source'");
  });

  it("prefers structured frame objects and does not double-count stack text", () => {
    const extracted = extractIssue({
      error: { type: "RangeError", stack: "RangeError: x\n    at f (worker/a.ts:1:1)" },
      frames: [{ filename: "node_modules/@dwk/indieauth/index.ts", lineno: 5, colno: 2, function: "issue" }],
    });
    expect(extracted.exceptionClass).toBe("RangeError");
    expect(extracted.frames).toEqual([
      { file: "node_modules/@dwk/indieauth/index.ts", line: 5, column: 2, fn: "issue" },
    ]);
  });

  it("a summary-only Notifications envelope has no frames", () => {
    const extracted = extractIssue({
      name: "Workers Issues",
      text: "New issue on my-site: TypeError",
      data: { alert_type: "workers_observability_alert", episode: { summary: "3 occurrences" } },
    });
    expect(extracted.frames).toEqual([]);
  });
});

describe("attribute", () => {
  const frame = (file: string, fn = "f") => ({ file, line: 1, column: 1, fn });

  it("files against the package when the innermost in-app frame is @dwk and template code called it", () => {
    const result = attribute([
      frame("node:internal/process"),
      frame("node_modules/linkedom/esm/index.js"),
      frame("node_modules/@dwk/webmention/src/verify.ts"),
      frame("worker/worker.ts"),
    ]);
    expect(result).toMatchObject({ kind: "package", packageName: "@dwk/webmention" });
  });

  it("matches the package on a path segment, wherever the bundle was built", () => {
    expect(classifyFrame(frame("../../../home/ci/site/node_modules/@dwk/micropub/src/a.ts"))).toMatchObject({
      kind: "package",
      packageName: "@dwk/micropub",
      publicPath: "@dwk/micropub/src/a.ts",
    });
  });

  it.each([
    ["no-stack", []],
    ["template", [frame("worker/worker.ts"), frame("node_modules/@dwk/webmention/a.ts")]],
    ["owner-code", [frame("src/lib/custom.ts"), frame("worker/worker.ts")]],
    ["owner-caller", [frame("node_modules/@dwk/webmention/a.ts"), frame("src/lib/custom.ts")]],
    ["unattributable", [frame("node:internal/x"), frame("node_modules/zod/index.js")]],
  ] as const)("does not file: %s", (reason, frames) => {
    expect(attribute([...frames])).toEqual({ kind: "not-filed", reason });
  });

  it("drops function names that could inject Markdown or mentions", () => {
    expect(classifyFrame(frame("node_modules/@dwk/x/a.ts", "@octocat")).fn).toBeUndefined();
    expect(classifyFrame(frame("node_modules/@dwk/x/a.ts", "a`b")).fn).toBeUndefined();
    expect(classifyFrame(frame("node_modules/@dwk/x/a.ts", "Object.fetch")).fn).toBe("Object.fetch");
  });

  it("treats a path with unsafe characters as owner code, so it blocks filing and is never published", () => {
    expect(classifyFrame(frame("node_modules/@dwk/x/a b.ts"))).toMatchObject({ kind: "owner" });
    expect(classifyFrame(frame("node_modules/@dwk/x/a b.ts")).publicPath).toBeUndefined();
  });
});
