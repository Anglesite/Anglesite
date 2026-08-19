import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readAnglesiteConfig, pickRunningExperiment, type AnglesiteConfig, type AnglesiteExperiment } from "./anglesite-config";

/// Temporarily replaces `console.warn` for the duration of `fn`, recording calls, then restores it.
function withWarnSpy<T>(fn: (calls: unknown[][]) => T): T {
  const calls: unknown[][] = [];
  const original = console.warn;
  console.warn = (...args: unknown[]) => {
    calls.push(args);
  };
  try {
    return fn(calls);
  } finally {
    console.warn = original;
  }
}

function makeTempSiteRoot(): string {
  return mkdtempSync(join(tmpdir(), "anglesite-config-test-"));
}

test("readAnglesiteConfig: missing file returns the default config quietly, without warning", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const calls = withWarnSpy((calls) => {
      const result = readAnglesiteConfig(siteRoot);
      assert.deepEqual(result, { version: 1 });
      return calls;
    });
    assert.equal(calls.length, 0, "console.warn should not be called when anglesite.json is simply absent");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: present-but-invalid JSON returns the default and warns", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(join(siteRoot, "anglesite.json"), "not json {");
  try {
    const calls = withWarnSpy((calls) => {
      const result = readAnglesiteConfig(siteRoot);
      assert.deepEqual(result, { version: 1 });
      return calls;
    });
    assert.ok(calls.length >= 1, "console.warn should be called when anglesite.json exists but fails to parse");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: anglesite.json existing as a directory warns and returns the default", () => {
  const siteRoot = makeTempSiteRoot();
  mkdirSync(join(siteRoot, "anglesite.json"));
  try {
    const calls = withWarnSpy((calls) => {
      const result = readAnglesiteConfig(siteRoot);
      assert.deepEqual(result, { version: 1 });
      return calls;
    });
    assert.ok(calls.length >= 1, "console.warn should be called when anglesite.json exists but can't be read as a file");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: a JSON array root returns the default and warns", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(join(siteRoot, "anglesite.json"), "[]");
  try {
    const calls = withWarnSpy((calls) => {
      const result = readAnglesiteConfig(siteRoot);
      assert.deepEqual(result, { version: 1 });
      return calls;
    });
    assert.ok(calls.length >= 1, "console.warn should be called when anglesite.json isn't a JSON object");
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: returns declared sections as-is", () => {
  const siteRoot = makeTempSiteRoot();
  const raw = JSON.stringify({
    version: 1,
    domain: { hostname: "example.com", choice: "transfer", attach: true },
    workers: { active: ["webmention-receive"] },
  });
  writeFileSync(join(siteRoot, "anglesite.json"), raw);
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result, {
      version: 1,
      domain: { hostname: "example.com", choice: "transfer", attach: true },
      workers: { active: ["webmention-receive"] },
    });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: passes through experimental.webmcp", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { webmcp: true } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { webmcp: true });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: experimental section absent by default", () => {
  const siteRoot = makeTempSiteRoot();
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.equal(result.experimental, undefined);
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: passes through experimental.mcp", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { mcp: true } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { mcp: true });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: passes through both experimental flags together", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(
    join(siteRoot, "anglesite.json"),
    JSON.stringify({ version: 1, experimental: { webmcp: true, mcp: false } }),
  );
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experimental, { webmcp: true, mcp: false });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: passes through a declared experiments section as-is", () => {
  const siteRoot = makeTempSiteRoot();
  const raw = JSON.stringify({
    version: 1,
    experiments: {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    },
  });
  writeFileSync(join(siteRoot, "anglesite.json"), raw);
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.deepEqual(result.experiments, {
      active: [
        {
          id: "homepage-hero",
          name: "Homepage headline",
          page: "/",
          variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
          split: 0.5,
          goal: { kind: "pageview", path: "/contact/thanks/" },
          status: "running",
          startedAt: "2026-08-16",
        },
      ],
    });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

test("readAnglesiteConfig: defaults version to 1 when the file omits it", () => {
  const siteRoot = makeTempSiteRoot();
  writeFileSync(join(siteRoot, "anglesite.json"), JSON.stringify({ domain: { hostname: "example.com" } }));
  try {
    const result = readAnglesiteConfig(siteRoot);
    assert.equal(result.version, 1);
    assert.deepEqual(result.domain, { hostname: "example.com" });
  } finally {
    rmSync(siteRoot, { recursive: true, force: true });
  }
});

function makeExperiment(overrides: Partial<AnglesiteExperiment> = {}): AnglesiteExperiment {
  return {
    id: "homepage-hero",
    name: "Homepage headline",
    page: "/",
    variant: { id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/" },
    split: 0.5,
    goal: { kind: "pageview", path: "/contact/thanks/" },
    status: "running",
    startedAt: "2026-08-16",
    ...overrides,
  };
}

test("pickRunningExperiment: no experiments section returns null", () => {
  const config: AnglesiteConfig = { version: 1 };
  assert.equal(pickRunningExperiment(config), null);
});

test("pickRunningExperiment: only draft experiments returns null", () => {
  const config: AnglesiteConfig = { version: 1, experiments: { active: [makeExperiment({ status: "draft" })] } };
  assert.equal(pickRunningExperiment(config), null);
});

test("pickRunningExperiment: returns the one running experiment", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: { active: [makeExperiment({ id: "draft-one", status: "draft" }), makeExperiment({ id: "running-one" })] },
  };
  assert.equal(pickRunningExperiment(config)?.id, "running-one");
});

test("pickRunningExperiment: picks the first running experiment when multiple are (invalidly) running", () => {
  const config: AnglesiteConfig = {
    version: 1,
    experiments: { active: [makeExperiment({ id: "first" }), makeExperiment({ id: "second" })] },
  };
  assert.equal(pickRunningExperiment(config)?.id, "first");
});
