#!/usr/bin/env node
/**
 * Proves that `anglesite-gate` cancels a publish on a built EmDash site (#2089).
 *
 * `scripts/check-emdash-overlay.sh` builds an EmDash site the way the app scaffolds one and
 * checks that the gate's id and policy are in the server bundle. This script boots that build
 * the way #2087's smoke test did — `astro preview` on workerd, with a local D1 as EmDash's `DB`
 * and a local R2 bucket as `MEDIA` — and drives EmDash's content API against it:
 *
 * 1. A draft whose body holds a secret is refused by `content:beforePublish`
 *    (`422 PUBLISH_REJECTED`, with the gate's reason from `scripts/emdash-gate/policy.ts`), stays
 *    a draft, and its page is not served.
 * 2. A clean draft publishes and its page renders.
 *
 * Headless EmDash: the site's `package.json` names `seed/seed.json`, which EmDash applies on the
 * first request (the `articles` collection), and its migrations run then too. EmDash's setup
 * wizard needs a passkey, so the admin user and an API token are written straight into the local
 * D1 with `wrangler d1 execute --local` (an `ec_pat_` token is stored as the base64url SHA-256
 * of itself), the same store workerd reads.
 *
 * Usage: node scripts/check-emdash-gate-runtime.mjs <site-dir>
 *   <site-dir> is a built EmDash site (`dist/server/entry.mjs` present, dependencies installed),
 *   e.g. the `Source/` under scripts/check-emdash-overlay.sh's work dir.
 *
 * The server's log is printed when a check fails. The preview server is stopped on exit.
 */

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const BOOT_TIMEOUT_MS = 180_000;
const REQUEST_TIMEOUT_MS = 60_000;
const STOP_GRACE_MS = 10_000;

/** The bindings the overlay's astro.config.ts reads (`EMDASH_BINDINGS`). */
const DB_BINDING = "DB";
const MEDIA_BINDING = "MEDIA";

const site = resolve(process.argv[2] ?? "");
if (!process.argv[2]) fail("usage: check-emdash-gate-runtime.mjs <site-dir>");
const wranglerConfigPath = join(site, "dist", "server", "wrangler.json");
for (const required of [join(site, "dist", "server", "entry.mjs"), wranglerConfigPath, join(site, "node_modules", "astro", "bin", "astro.mjs"), join(site, "node_modules", "wrangler", "bin", "wrangler.js")]) {
  if (!existsSync(required)) fail(`not a built EmDash site: missing ${required}`);
}

/** Everything the preview server printed, shown when a check fails. */
let serverLog = "";
/** @type {import("node:child_process").ChildProcess | undefined} */
let server;
const originalWranglerConfig = readFileSync(wranglerConfigPath, "utf8");

function fail(message) {
  console.error(`✗ ${message}`);
  if (serverLog) {
    console.error("--- astro preview log ---");
    console.error(serverLog.trimEnd());
    console.error("--- end of astro preview log ---");
  }
  killServer();
  process.exit(1);
}

function check(condition, message) {
  if (!condition) fail(message);
  console.log(`✓ ${message}`);
}

function serverRunning() {
  return server !== undefined && server.pid !== undefined && server.exitCode === null && server.signalCode === null;
}

/** Signals the server's whole process group (`detached`), so workerd goes with it. */
function signalServer(signal) {
  try {
    process.kill(-server.pid, signal);
  } catch {
    // Already gone.
  }
}

let stopped = false;

/** The orderly stop: SIGTERM, a grace period for workerd to shut down, then SIGKILL. */
async function stopServer() {
  if (stopped) return;
  stopped = true;
  writeFileSync(wranglerConfigPath, originalWranglerConfig);
  if (!serverRunning()) return;
  const exited = new Promise((resolveExit) => server.once("exit", () => resolveExit(false)));
  signalServer("SIGTERM");
  if (await Promise.race([exited, sleep(STOP_GRACE_MS).then(() => true)])) signalServer("SIGKILL");
}

/** The stop for a failure or a signal, where the process is about to exit: no event loop to wait on. */
function killServer() {
  if (stopped) return;
  stopped = true;
  writeFileSync(wranglerConfigPath, originalWranglerConfig);
  if (!serverRunning()) return;
  signalServer("SIGTERM");
  spawnSync("sleep", ["1"]);
  signalServer("SIGKILL");
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    killServer();
    process.exit(130);
  });
}
process.on("exit", killServer);

async function freePort() {
  return new Promise((resolvePort, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolvePort(port));
    });
  });
}

/** Stages the Worker config the way the app does: EmDash's D1 and R2 bindings next to the build. */
function stageWorkerConfig() {
  const config = JSON.parse(originalWranglerConfig);
  config.compatibility_flags = [...new Set([...(config.compatibility_flags ?? []), "nodejs_compat"])];
  config.d1_databases = [
    { binding: DB_BINDING, database_name: `${config.name}-social`, database_id: "00000000-0000-4000-8000-000000002089" },
  ];
  config.r2_buckets = [{ binding: MEDIA_BINDING, bucket_name: `${config.name}-media` }];
  writeFileSync(wranglerConfigPath, JSON.stringify(config));
}

async function request(base, path, { method = "GET", token, body } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    // EmDash's CSRF check for unsafe methods; a bearer token is exempt, but the header is cheap.
    headers["X-EmDash-Request"] = "1";
  }
  const response = await fetch(new URL(path, base), {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "manual",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  return { status: response.status, text, json };
}

/** A Portable Text body the way EmDash stores one. */
function portableText(text) {
  return [{ _type: "block", _key: "b1", style: "normal", markDefs: [], children: [{ _type: "span", _key: "s1", text, marks: [] }] }];
}

async function bootPreview(port) {
  // `--ignore-lock` keeps `astro preview` in the foreground (it otherwise daemonises itself when
  // it detects an agent session), so this process owns the server and can stop it.
  server = spawn(
    process.execPath,
    [join(site, "node_modules", "astro", "bin", "astro.mjs"), "preview", "--host", "127.0.0.1", "--port", String(port), "--ignore-lock"],
    { cwd: site, detached: true, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ASTRO_TELEMETRY_DISABLED: "1", FORCE_COLOR: "0", NO_COLOR: "1" } },
  );
  server.stdout.on("data", (chunk) => (serverLog += chunk));
  server.stderr.on("data", (chunk) => (serverLog += chunk));
  server.on("exit", (code, signal) => {
    serverLog += `\n[astro preview exited: code=${code} signal=${signal}]\n`;
  });

  const deadline = Date.now() + BOOT_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) fail(`astro preview exited before it was ready (code ${server.exitCode})`);
    // Vite's preview falls back to another port when the requested one is taken; the log is the
    // source of truth for where the server listens.
    const listening = serverLog.match(/http:\/\/127\.0\.0\.1:(\d+)\//);
    if (listening) {
      const base = `http://127.0.0.1:${listening[1]}`;
      try {
        // The first request runs EmDash's migrations and applies the site's seed.
        const health = await request(base, "/_emdash/api/health");
        if (health.status === 200 && health.json?.success === true) return base;
      } catch {
        // Not up yet.
      }
    }
    await sleep(1000);
  }
  fail(`astro preview did not answer /_emdash/api/health within ${BOOT_TIMEOUT_MS / 1000}s`);
}

/** Writes the admin user and an API token into the local D1 the running server reads. */
function createAdminToken() {
  const token = `ec_pat_${randomBytes(32).toString("base64url")}`;
  const hash = createHash("sha256").update(token).digest("base64url");
  const now = new Date().toISOString();
  const userID = "01ANGLESITEGATE0000000000";
  const sql = [
    `INSERT INTO users (id, email, name, role, email_verified, disabled, created_at, updated_at) VALUES ('${userID}', 'gate@anglesite.invalid', 'Anglesite gate check', 50, 1, 0, '${now}', '${now}')`,
    `INSERT INTO _emdash_api_tokens (id, name, token_hash, prefix, user_id, scopes, created_at) VALUES ('01ANGLESITEGATETOKEN00000', 'anglesite-gate check', '${hash}', '${token.slice(0, 11)}', '${userID}', '["admin"]', '${now}')`,
  ].join("; ");
  const result = spawnSync(
    process.execPath,
    [join(site, "node_modules", "wrangler", "bin", "wrangler.js"), "d1", "execute", DB_BINDING, "--local", "--persist-to", join(site, ".wrangler", "state"), "--config", wranglerConfigPath, "--command", sql],
    { cwd: site, encoding: "utf8", timeout: 120_000, env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false", FORCE_COLOR: "0", NO_COLOR: "1" } },
  );
  if (result.status !== 0) {
    serverLog += `\n--- wrangler d1 execute ---\n${result.stdout}\n${result.stderr}\n`;
    fail(`wrangler d1 execute --local failed (status ${result.status})`);
  }
  return token;
}

async function main() {
  stageWorkerConfig();
  // A clean local store every run: D1 (migrations + seed run again on first request), R2, KV.
  for (const store of ["d1", "r2", "kv"]) rmSync(join(site, ".wrangler", "state", "v3", store), { recursive: true, force: true });

  const base = await bootPreview(await freePort());
  console.log(`✓ astro preview is serving the EmDash site at ${base}`);

  const setup = await request(base, "/_emdash/api/setup/status");
  check(setup.json?.data?.seedInfo?.collections === 1, "EmDash applied the site's seed on first request");

  const token = createAdminToken();
  const me = await request(base, "/_emdash/api/auth/me", { token });
  check(me.status === 200 && me.json?.data?.role === 50, "the API token authenticates as an admin");

  // 1. A secret in the body trips the gate. Built at runtime and vendor-neutral, so it matches the
  //    gate's generic pattern without looking like a real provider's key (as in policy.test.ts).
  const secret = `api_key: ${"x".repeat(24)}`;
  const leaked = await request(base, "/_emdash/api/content/articles", {
    method: "POST",
    token,
    body: { slug: "leaked-key", status: "draft", data: { title: "Leaked key", summary: "A note", content: portableText(`Config notes: ${secret}`) } },
  });
  check(leaked.status === 201 && typeof leaked.json?.data?.item?.id === "string", "a draft with a secret in its body is saved as a draft");
  const leakedID = leaked.json.data.item.id;

  const refused = await request(base, `/_emdash/api/content/articles/${leakedID}/publish`, { method: "POST", token, body: {} });
  check(refused.status === 422 && refused.json?.success === false, `publishing it is refused (HTTP ${refused.status}: ${refused.text.slice(0, 200)})`);
  check(refused.json?.error?.code === "PUBLISH_REJECTED", "EmDash reports the publish as cancelled by a content policy (PUBLISH_REJECTED)");
  const reason = String(refused.json?.error?.message ?? "");
  check(reason.startsWith("Anglesite can't publish this yet") && reason.includes("API key"), `the cancellation carries the gate's reason: ${JSON.stringify(reason)}`);

  const stillDraft = await request(base, `/_emdash/api/content/articles/${leakedID}`, { token });
  check(stillDraft.json?.data?.item?.status === "draft", "the refused entry is still a draft");
  const leakedPage = await request(base, "/articles/leaked-key/");
  check(leakedPage.status === 404, "the refused entry's page is not served");

  // 2. A clean draft publishes.
  const clean = await request(base, "/_emdash/api/content/articles", {
    method: "POST",
    token,
    body: { slug: "council-vote", status: "draft", data: { title: "Council approves budget", summary: "The vote", content: portableText("The council voted 5–2 on Tuesday.") } },
  });
  check(clean.status === 201 && typeof clean.json?.data?.item?.id === "string", "a clean draft is saved as a draft");
  const cleanID = clean.json.data.item.id;

  const published = await request(base, `/_emdash/api/content/articles/${cleanID}/publish`, { method: "POST", token, body: {} });
  check(published.status === 200 && published.json?.data?.item?.status === "published", `publishing it succeeds (HTTP ${published.status})`);
  const cleanPage = await request(base, "/articles/council-vote/");
  check(cleanPage.status === 200 && cleanPage.text.includes("Council approves budget") && cleanPage.text.includes("h-entry"), "the published article renders as an h-entry");

  await stopServer();
  console.log("✓ anglesite-gate cancels a failing publish and passes a clean one on the built EmDash site");
}

main().catch((error) => fail(error instanceof Error ? (error.stack ?? error.message) : String(error)));
