import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import anglesiteHarness from "./anglesite-harness";
import { namedSlotSamples, parseProps, resolveComponentKey } from "./component-harness";

test("resolveComponentKey prefers components over layouts", () => {
  const modules = {
    "/src/components/Card.astro": async () => ({}),
    "/src/layouts/Card.astro": async () => ({}),
  };

  assert.equal(resolveComponentKey("Card", modules), "/src/components/Card.astro");
});

test("resolveComponentKey supports nested component names", () => {
  const modules = {
    "/src/components/marketing/Hero.astro": async () => ({}),
  };

  assert.equal(resolveComponentKey("marketing/Hero", modules), "/src/components/marketing/Hero.astro");
});

test("parseProps returns only JSON objects", () => {
  assert.deepEqual(parseProps('{"title":"Hello","count":2,"enabled":true}'), {
    title: "Hello",
    count: 2,
    enabled: true,
  });

  assert.deepEqual(parseProps("null"), {});
  assert.deepEqual(parseProps('"hello"'), {});
  assert.deepEqual(parseProps("[1,2,3]"), {});
  assert.deepEqual(parseProps("{malformed"), {});
  assert.deepEqual(parseProps(null), {});
});

test("namedSlotSamples extracts labeled unique named slots", () => {
  const source = `
    <header><slot name="header" /></header>
    <main><slot /></main>
    <footer><slot name='footer-links'>Fallback</slot></footer>
    <aside><slot name={"promo_panel"} /></aside>
    <slot name="header" />
  `;

  assert.deepEqual(namedSlotSamples(source), [
    { name: "header", label: "Header slot content" },
    { name: "footer-links", label: "Footer Links slot content" },
    { name: "promo_panel", label: "Promo Panel slot content" },
  ]);
});

test("namedSlotSamples ignores frontmatter literals and explicit default slots", () => {
  const source = `---
const example = '<slot name="from-frontmatter" />';
---
<slot />
<slot name="default" />
<slot name="aside" />
`;

  assert.deepEqual(namedSlotSamples(source), [{ name: "aside", label: "Aside slot content" }]);
});

test("anglesiteHarness injects the component route and the reload guard only in dev", async () => {
  const integration = anglesiteHarness();
  const setup = integration.hooks["astro:config:setup"];
  assert.ok(setup);

  const devRoutes: unknown[] = [];
  const devConfigs: { vite?: { plugins?: { name?: string }[] } }[] = [];
  await setup({
    command: "dev",
    injectRoute(route: unknown) {
      devRoutes.push(route);
    },
    updateConfig(config: (typeof devConfigs)[number]) {
      devConfigs.push(config);
    },
  } as never);

  assert.equal(devRoutes.length, 1);
  assert.deepEqual(devRoutes[0], {
    pattern: "/_anglesite/component/[...name]",
    entrypoint: fileURLToPath(new URL("./harness/component.astro", import.meta.url)),
    prerender: false,
  });
  assert.deepEqual(devConfigs.flatMap((config) => config.vite?.plugins ?? []).map((plugin) => plugin.name), [
    "anglesite-editor-write-reload",
  ]);

  const buildRoutes: unknown[] = [];
  const buildConfigs: unknown[] = [];
  await setup({
    command: "build",
    injectRoute(route: unknown) {
      buildRoutes.push(route);
    },
    updateConfig(config: unknown) {
      buildConfigs.push(config);
    },
  } as never);

  assert.deepEqual(buildRoutes, []);
  assert.deepEqual(buildConfigs, []);
});
