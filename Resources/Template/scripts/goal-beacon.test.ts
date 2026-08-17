// Coverage for the client-side goal beacon (public/x/goal-beacon.js, #1270 slice 2). The script
// is a plain browser file (never bundled/transformed — see its own doc comment), so this test
// stubs just enough of the DOM/browser surface it touches (document.currentScript, window's
// scroll listener API, IntersectionObserver, navigator.sendBeacon/fetch) and re-imports the
// module fresh per case: it's a self-executing IIFE that reads its globals once at import time,
// and Node's ESM loader caches a module by its exact resolved specifier — a cache-busting query
// string forces a fresh evaluation against that test's own stubs.
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join, dirname } from "node:path";

const BEACON_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "x", "goal-beacon.js");
let importCounter = 0;

interface Stubs {
  sendBeaconCalls: string[];
  fetchCalls: Array<{ url: string; init: unknown }>;
  scrollListeners: Array<() => void>;
  removedListeners: Array<() => void>;
  intersectionCallback: ((entries: Array<{ isIntersecting: boolean }>) => void) | null;
  observed: unknown[];
  disconnected: boolean;
}

function installStubs(opts: {
  dataset?: Record<string, string> | null;
  querySelectorReturns?: unknown;
  hasSendBeacon?: boolean;
  scrollHeight?: number;
  innerHeight?: number;
  scrollY?: number;
}): Stubs {
  const stubs: Stubs = {
    sendBeaconCalls: [],
    fetchCalls: [],
    scrollListeners: [],
    removedListeners: [],
    intersectionCallback: null,
    observed: [],
    disconnected: false,
  };

  const currentScript = opts.dataset === null ? null : { dataset: opts.dataset ?? {} };

  // Node ships read-only global getters for several of these (navigator, fetch) on modern
  // versions — plain assignment throws "Cannot set property ... which has only a getter".
  // `defineProperty` with `configurable: true` overrides them for this stub, and the next test's
  // call overrides them again.
  const define = (name: string, value: unknown) =>
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });

  define("document", {
    currentScript,
    documentElement: { scrollHeight: opts.scrollHeight ?? 1000 },
    querySelector: () => (opts.querySelectorReturns !== undefined ? opts.querySelectorReturns : null),
  });
  define("window", {
    scrollY: opts.scrollY ?? 0,
    innerHeight: opts.innerHeight ?? 800,
    addEventListener: (event: string, listener: () => void) => {
      if (event === "scroll") stubs.scrollListeners.push(listener);
    },
    removeEventListener: (event: string, listener: () => void) => {
      if (event === "scroll") stubs.removedListeners.push(listener);
    },
  });
  define(
    "navigator",
    opts.hasSendBeacon === false
      ? {}
      : {
          sendBeacon: (url: string) => {
            stubs.sendBeaconCalls.push(url);
            return true;
          },
        },
  );
  define("fetch", (url: string, init: unknown) => {
    stubs.fetchCalls.push({ url, init });
    return Promise.resolve({ ok: true });
  });
  define(
    "IntersectionObserver",
    class {
      constructor(callback: (entries: Array<{ isIntersecting: boolean }>) => void) {
        stubs.intersectionCallback = callback;
      }
      observe(target: unknown) {
        stubs.observed.push(target);
      }
      disconnect() {
        stubs.disconnected = true;
      }
    },
  );

  return stubs;
}

async function loadBeacon(): Promise<void> {
  importCounter += 1;
  await import(`${pathToFileURL(BEACON_PATH).href}?case=${importCounter}`);
}

test("goal-beacon: no-ops when document.currentScript is absent", async () => {
  const stubs = installStubs({ dataset: null });
  await loadBeacon();
  assert.equal(stubs.scrollListeners.length, 0);
  assert.equal(stubs.observed.length, 0);
});

test("goal-beacon: no-ops when data-experiment is missing", async () => {
  const stubs = installStubs({ dataset: { kind: "scroll", depth: "50" } });
  await loadBeacon();
  assert.equal(stubs.scrollListeners.length, 0);
});

test("goal-beacon: no-ops when data-kind is unrecognized", async () => {
  const stubs = installStubs({ dataset: { experiment: "exp1", kind: "click" } });
  await loadBeacon();
  assert.equal(stubs.scrollListeners.length, 0);
  assert.equal(stubs.observed.length, 0);
});

test("goal-beacon scroll: no-ops when depth is missing/out of range", async () => {
  const missing = installStubs({ dataset: { experiment: "exp1", kind: "scroll" } });
  await loadBeacon();
  assert.equal(missing.scrollListeners.length, 0);

  const outOfRange = installStubs({ dataset: { experiment: "exp1", kind: "scroll", depth: "150" } });
  await loadBeacon();
  assert.equal(outOfRange.scrollListeners.length, 0);
});

test("goal-beacon scroll: does not fire before the depth threshold is crossed", async () => {
  const stubs = installStubs({
    dataset: { experiment: "exp1", kind: "scroll", depth: "75" },
    scrollHeight: 1000,
    innerHeight: 200,
    scrollY: 100,
  });
  await loadBeacon();
  assert.equal(stubs.scrollListeners.length, 1);

  stubs.scrollListeners[0]();
  assert.equal(stubs.sendBeaconCalls.length, 0);
});

test("goal-beacon scroll: fires once when the depth threshold is crossed, then stops listening", async () => {
  const stubs = installStubs({
    dataset: { experiment: "homepage-hero", kind: "scroll", depth: "75" },
    scrollHeight: 1000,
    innerHeight: 200,
    scrollY: 100,
  });
  await loadBeacon();
  const onScroll = stubs.scrollListeners[0];

  // (scrollY + innerHeight) / scrollHeight * 100 = (600 + 200) / 1000 * 100 = 80 >= 75
  (globalThis as unknown as { window: { scrollY: number } }).window.scrollY = 600;
  onScroll();
  assert.deepEqual(stubs.sendBeaconCalls, ["/x/goal?e=homepage-hero"]);
  assert.equal(stubs.removedListeners.length, 1);

  // A second crossing (e.g. the caller invoking a stale reference) must not send twice.
  onScroll();
  assert.equal(stubs.sendBeaconCalls.length, 1);
});

test("goal-beacon visible: no-ops when data-selector is missing", async () => {
  const stubs = installStubs({ dataset: { experiment: "exp1", kind: "visible" } });
  await loadBeacon();
  assert.equal(stubs.observed.length, 0);
});

test("goal-beacon visible: no-ops when the selector matches no element", async () => {
  const stubs = installStubs({
    dataset: { experiment: "exp1", kind: "visible", selector: "#missing" },
    querySelectorReturns: null,
  });
  await loadBeacon();
  assert.equal(stubs.observed.length, 0);
});

test("goal-beacon visible: observes the target and does not fire while not intersecting", async () => {
  const target = { id: "testimonials" };
  const stubs = installStubs({
    dataset: { experiment: "exp1", kind: "visible", selector: "#testimonials" },
    querySelectorReturns: target,
  });
  await loadBeacon();
  assert.deepEqual(stubs.observed, [target]);

  stubs.intersectionCallback?.([{ isIntersecting: false }]);
  assert.equal(stubs.sendBeaconCalls.length, 0);
  assert.equal(stubs.disconnected, false);
});

test("goal-beacon visible: fires once and disconnects when the target intersects", async () => {
  const target = { id: "testimonials" };
  const stubs = installStubs({
    dataset: { experiment: "homepage-hero", kind: "visible", selector: "#testimonials" },
    querySelectorReturns: target,
  });
  await loadBeacon();

  stubs.intersectionCallback?.([{ isIntersecting: false }, { isIntersecting: true }]);
  assert.deepEqual(stubs.sendBeaconCalls, ["/x/goal?e=homepage-hero"]);
  assert.equal(stubs.disconnected, true);

  stubs.intersectionCallback?.([{ isIntersecting: true }]);
  assert.equal(stubs.sendBeaconCalls.length, 1);
});

test("goal-beacon: falls back to a keepalive fetch when sendBeacon is unavailable", async () => {
  const target = { id: "testimonials" };
  const stubs = installStubs({
    dataset: { experiment: "homepage-hero", kind: "visible", selector: "#testimonials" },
    querySelectorReturns: target,
    hasSendBeacon: false,
  });
  await loadBeacon();

  stubs.intersectionCallback?.([{ isIntersecting: true }]);
  assert.equal(stubs.sendBeaconCalls.length, 0);
  assert.equal(stubs.fetchCalls.length, 1);
  assert.equal(stubs.fetchCalls[0].url, "/x/goal?e=homepage-hero");
  assert.deepEqual(stubs.fetchCalls[0].init, { method: "POST", keepalive: true });
});

test("goal-beacon: URL-encodes the experiment id", async () => {
  const stubs = installStubs({
    dataset: { experiment: "a b&c", kind: "scroll", depth: "10" },
    scrollHeight: 100,
    innerHeight: 100,
    scrollY: 100,
  });
  await loadBeacon();
  stubs.scrollListeners[0]();
  assert.deepEqual(stubs.sendBeaconCalls, ["/x/goal?e=a%20b%26c"]);
});
