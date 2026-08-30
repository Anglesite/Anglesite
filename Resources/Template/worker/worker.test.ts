import { env } from "cloudflare:workers";
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { createIndieAuthStore, type AuthorizationRequest } from "@dwk/indieauth";
import { generateSigningJwk, type SolidOidcAuthorizationRequest } from "@dwk/solid-oidc";
import { beforeEach, expect, test } from "vitest";
import {
  validateInboxFields,
  isRateLimited,
  handleInbox,
  buildInboxForwardRaw,
  handleIndieAuthConsent,
  createConsentToken,
  verifyConsentToken,
  createSolidOidcConsentToken,
  verifySolidOidcConsentToken,
  handleSolidOidc,
  handleSolidOidcConsent,
  handleSolidPod,
  handleWebdav,
  handleWebdavCredentials,
  activityPubConfig,
  resolveFanOutAddressing,
  type InboxKV,
  type WorkerEnv,
} from "./worker";
import worker from "./worker";
import { tagFediverseUrl } from "./utm-codes.ts";
import { createMicropubStore } from "@dwk/micropub";
import { READER_SESSION_COOKIE, createReaderSessionToken } from "./reader-session.ts";
import { normalizeReaderIdentity } from "./reader-identity.ts";
import { createHandleMcp, isMcpRateLimited, isMcpToolCallRequest, mcpRateLimitKey } from "./mcp-server.ts";
import type { McpConfigArtifact } from "./mcp-config.ts";

const testEnv = env as unknown as WorkerEnv;

beforeEach(async () => {
  await createIndieAuthStore(testEnv).init();
});

function makeFakeKV(initial: Record<string, string> = {}): InboxKV & { store: Map<string, string> } {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key: string) {
      return store.has(key) ? store.get(key)! : null;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
  };
}

/** A minimal `Fetcher`-shaped stub for `env.ASSETS`: maps exact request URLs (pathname only) to
 *  canned responses, everything else 404s. Cast through `unknown`, matching `assetsAlways404`
 *  below — the real `Fetcher` type also requires a `connect()` method this stub doesn't need. */
function makeFakeAssets(responses: Record<string, { status: number; body?: string }>): WorkerEnv["ASSETS"] {
  return {
    async fetch(request: Request) {
      const pathname = new URL(request.url).pathname;
      const canned = responses[pathname];
      if (!canned) return new Response(null, { status: 404 });
      return new Response(canned.body ?? null, { status: canned.status });
    },
  } as unknown as WorkerEnv["ASSETS"];
}

test("validateInboxFields: trims and accepts complete fields", () => {
  const result = validateInboxFields({ subject: " Hello ", from: " a@example.com ", message: " hi " });
  expect(result).toEqual({ subject: "Hello", from: "a@example.com", message: "hi" });
});

test("validateInboxFields: rejects a missing field", () => {
  expect(validateInboxFields({ subject: "Hello", from: "a@example.com", message: "" })).toBeNull();
});

test("validateInboxFields: rejects an over-long field", () => {
  expect(
    validateInboxFields({ subject: "x".repeat(201), from: "a@example.com", message: "hi" }),
  ).toBeNull();
});

test("isRateLimited: allows up to the window max, then blocks", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) {
    expect(await isRateLimited(kv, "1.2.3.4")).toBe(false);
  }
  expect(await isRateLimited(kv, "1.2.3.4")).toBe(true);
});

test("isRateLimited: tracks separate IPs independently", async () => {
  const kv = makeFakeKV();
  for (let i = 0; i < 5; i++) await isRateLimited(kv, "1.2.3.4");
  expect(await isRateLimited(kv, "5.6.7.8")).toBe(false);
});

test("handleInbox: stages a valid JSON submission and returns 202", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(202);
  // 2 keys, not 1: isRateLimited() always writes a `ratelimit:<ip>` counter as a side effect on
  // every allowed call, in addition to the `inbox:<id>` staged submission written here.
  expect(kv.store.size).toBe(2);
  const [, stagedRaw] = [...kv.store.entries()].find(([key]) => key.startsWith("inbox:"))!;
  const staged = JSON.parse(stagedRaw);
  expect(staged.subject).toBe("Hello");
  expect(staged.from).toBe("a@example.com");
  expect(staged.message).toBe("Hi there");
  expect(typeof staged.id).toBe("string");
  expect(typeof staged.receivedAt).toBe("string");
});

test("handleInbox: silently drops a honeypot-tripped submission", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      subject: "Hello", from: "a@example.com", message: "Hi", website: "http://spam.example",
    }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(202);
  // 1 key, not 0: rate limiting runs before the honeypot check in handleInbox, so this call still
  // writes the `ratelimit:<ip>` counter — a honeypot-tripped request still consumes a rate-limit
  // slot, which is correct: bots shouldn't be exempt from rate limiting just because they tripped
  // the honeypot.
  expect(kv.store.size).toBe(1);
});

test("handleInbox: rejects a non-POST method", async () => {
  const kv = makeFakeKV();
  const request = new Request("https://example.com/inbox", { method: "GET" });
  const response = await handleInbox(request, { INBOX_KV: kv });
  expect(response.status).toBe(405);
});

test("handleInbox: 429s once the per-IP rate limit is exceeded", async () => {
  const kv = makeFakeKV();
  const makeRequest = () =>
    new Request("https://example.com/inbox", {
      method: "POST",
      headers: { "content-type": "application/json", "CF-Connecting-IP": "1.2.3.4" },
      body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi" }),
    });
  for (let i = 0; i < 5; i++) {
    const response = await handleInbox(makeRequest(), { INBOX_KV: kv });
    expect(response.status).toBe(202);
  }
  const limited = await handleInbox(makeRequest(), { INBOX_KV: kv });
  expect(limited.status).toBe(429);
});

test("handleInbox: 500s when INBOX_KV isn't bound", async () => {
  const request = new Request("https://example.com/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi" }),
  });
  const response = await handleInbox(request, {});
  expect(response.status).toBe(500);
});

function makeFakeSendEmail(): { send: (message: unknown) => Promise<void>; calls: unknown[] } {
  const calls: unknown[] = [];
  return {
    calls,
    async send(message: unknown) {
      calls.push(message);
    },
  };
}

test("handleInbox: forwards to SEND_EMAIL when both it and INBOX_FORWARD_EMAIL are bound", async () => {
  const kv = makeFakeKV();
  const sendEmail = makeFakeSendEmail();
  const request = new Request("https://my-site.example/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, {
    INBOX_KV: kv,
    SEND_EMAIL: sendEmail as never,
    INBOX_FORWARD_EMAIL: "owner@example.com",
  });
  expect(response.status).toBe(202);
  expect(sendEmail.calls.length).toBe(1);
});

test("handleInbox: still stages the submission and returns 202 when SEND_EMAIL.send rejects", async () => {
  const kv = makeFakeKV();
  const sendEmail = {
    async send() {
      throw new Error("destination address not verified");
    },
  };
  const request = new Request("https://my-site.example/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, {
    INBOX_KV: kv,
    SEND_EMAIL: sendEmail as never,
    INBOX_FORWARD_EMAIL: "owner@example.com",
  });
  expect(response.status).toBe(202);
  const [, stagedRaw] = [...kv.store.entries()].find(([key]) => key.startsWith("inbox:"))!;
  expect(JSON.parse(stagedRaw).subject).toBe("Hello");
});

test("handleInbox: does not call SEND_EMAIL.send when INBOX_FORWARD_EMAIL is unset", async () => {
  const kv = makeFakeKV();
  const sendEmail = makeFakeSendEmail();
  const request = new Request("https://my-site.example/inbox", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ subject: "Hello", from: "a@example.com", message: "Hi there" }),
  });
  const response = await handleInbox(request, { INBOX_KV: kv, SEND_EMAIL: sendEmail as never });
  expect(response.status).toBe(202);
  expect(sendEmail.calls.length).toBe(0);
});

test("buildInboxForwardRaw: base64-encodes the subject header, so embedded CRLF can't inject a header", () => {
  const raw = buildInboxForwardRaw("inbox@my-site.example", "owner@example.com", {
    id: "abc-123",
    receivedAt: "2026-08-18T00:00:00.000Z",
    subject: "Hi\r\nBcc: attacker@evil.example",
    from: "a@example.com",
    message: "hello",
  });
  // The header/body boundary is the *first* blank line — split only there, not on every blank
  // line the body itself may contain (the injected value's own CRLF creates one further down).
  const headerEnd = raw.indexOf("\r\n\r\n");
  const headerBlock = raw.slice(0, headerEnd);
  const bodyBlock = raw.slice(headerEnd + 4);
  expect(headerBlock).not.toContain("Bcc:");
  expect(headerBlock).toMatch(/^Subject: =\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=$/m);
  // The raw, unencoded content only ever appears in the body, after the header/body separator.
  expect(bodyBlock).toContain("Hi\r\nBcc: attacker@evil.example");
});

test("buildInboxForwardRaw: puts from/message in the body untouched and the recipient in To", () => {
  const raw = buildInboxForwardRaw("inbox@my-site.example", "owner@example.com", {
    id: "abc-123",
    receivedAt: "2026-08-18T00:00:00.000Z",
    subject: "Hello",
    from: "a@example.com",
    message: "Hi there",
  });
  expect(raw).toContain("To: <owner@example.com>");
  expect(raw).toContain('From: "Site Inbox" <inbox@my-site.example>');
  expect(raw).toContain("From: a@example.com");
  expect(raw).toContain("Hi there");
  expect(raw).toContain("Submission ID: abc-123");
});

function decodeRfc2047(headerValue: string): string {
  const words = [...headerValue.matchAll(/=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=/g)].map((m) => m[1]!);
  const bytes = words.flatMap((w) => [...atob(w)].map((c) => c.charCodeAt(0)));
  return new TextDecoder().decode(new Uint8Array(bytes));
}

test("buildInboxForwardRaw: folds a near-MAX_SUBJECT_LENGTH subject into multiple RFC 2047 encoded-words, each within the 75-char cap", () => {
  const longSubject = "x".repeat(200); // MAX_SUBJECT_LENGTH
  const raw = buildInboxForwardRaw("inbox@my-site.example", "owner@example.com", {
    id: "abc-123",
    receivedAt: "2026-08-18T00:00:00.000Z",
    subject: longSubject,
    from: "a@example.com",
    message: "hi",
  });
  const headerEnd = raw.indexOf("\r\n\r\n");
  const headerBlock = raw.slice(0, headerEnd);
  const subjectMatch = headerBlock.match(/Subject: ([\s\S]*?)\r\nMIME-Version:/);
  expect(subjectMatch).not.toBeNull();
  const subjectHeader = subjectMatch![1]!;
  const lines = subjectHeader.split("\r\n ");
  expect(lines.length).toBeGreaterThan(1);
  for (const line of lines) {
    expect(line.length).toBeLessThanOrEqual(75);
    expect(line).toMatch(/^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=$/);
  }
  expect(decodeRfc2047(subjectHeader)).toBe(`[Inbox] ${longSubject}`);
});

test("buildInboxForwardRaw: a multi-byte-character subject decodes correctly across an encoded-word fold boundary", () => {
  // A run of 3-byte UTF-8 characters (each "🙂"-adjacent BMP emoji-free code point) long enough
  // to straddle the 45-byte-per-word boundary, verifying the UTF-8 boundary backoff doesn't
  // corrupt a character split across two words.
  const longSubject = "café ".repeat(40); // each "é" is 2 bytes — forces non-ASCII byte splits
  const raw = buildInboxForwardRaw("inbox@my-site.example", "owner@example.com", {
    id: "abc-123",
    receivedAt: "2026-08-18T00:00:00.000Z",
    subject: longSubject,
    from: "a@example.com",
    message: "hi",
  });
  const headerEnd = raw.indexOf("\r\n\r\n");
  const subjectMatch = raw.slice(0, headerEnd).match(/Subject: ([\s\S]*?)\r\nMIME-Version:/);
  expect(decodeRfc2047(subjectMatch![1]!)).toBe(`[Inbox] ${longSubject}`);
});

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkceChallenge(verifier: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

/**
 * `accessToken`, when supplied, adds the RFC 9449 `ath` claim (base64url SHA-256 of the access
 * token) that `@dwk/dpop`'s `verifyDpopProof` requires whenever it's checking a proof against a
 * bound access token (i.e. every Micropub/media resource request — Task 9, #360). Omit it for
 * proofs that don't carry an access token yet, like the `/token` exchange itself.
 */
async function dpopProof(
  url: string,
  method = "POST",
  keyPair?: CryptoKeyPair,
  accessToken?: string,
): Promise<string> {
  const pair = keyPair ?? await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const header = base64url(new TextEncoder().encode(JSON.stringify({ typ: "dpop+jwt", alg: "ES256", jwk })));
  const payload = base64url(new TextEncoder().encode(JSON.stringify({
    jti: crypto.randomUUID(),
    htm: method,
    htu: url,
    iat: Math.floor(Date.now() / 1000),
    ...(accessToken !== undefined
      ? { ath: base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(accessToken)))) }
      : {}),
  })));
  const signingInput = new TextEncoder().encode(`${header}.${payload}`);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, signingInput);
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

/**
 * Distinct `CF-Connecting-IP` per `mintAccessToken` call, so repeated calls across the file's
 * Micropub tests (Task 9, #360) don't share one IP's consent-endpoint rate-limit bucket
 * (`RATE_LIMIT_MAX_PER_WINDOW` in worker.ts) — this suite's D1/KV storage is not test-isolated
 * (see the module-level `beforeEach` re-`init`ing `AUTH_DB`), so counters accumulate across
 * tests within the file, not just within one test. Starts past the fixed IPs the IndieAuth
 * consent tests above use explicitly (192.0.2.35-43, .99).
 */
let mintAccessTokenIPCounter = 150;

/**
 * Runs the full PKCE + owner-consent + token-exchange flow (mirroring the inline steps in
 * "IndieAuth owner consent completes PKCE sign-in and issues a DPoP token" above) and returns
 * the issued access token plus the key pair its DPoP binding was minted with — callers that need
 * to make an authorized resource request (Task 9's Micropub tests) must reuse this same key pair
 * to prove possession, not generate a fresh one.
 */
async function mintAccessToken(scope: string): Promise<{ token: string; keyPair: CryptoKeyPair }> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const verifier = `anglesite-mint-verifier-${crypto.randomUUID()}-with-more-than-forty-three-characters`;
  const challenge = await pkceChallenge(verifier);
  const authorize = new URL("https://owner.example/authorize");
  authorize.search = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: crypto.randomUUID(),
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope,
  }).toString();

  await fetchWorker(new Request(authorize));

  const consentForm = new URLSearchParams(authorize.search);
  consentForm.set("password", "correct horse battery staple");
  const consent = await fetchWorker(new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "CF-Connecting-IP": `192.0.2.${mintAccessTokenIPCounter++}`,
    },
    body: consentForm,
  }));
  const approvedURL = new URL(consent.headers.get("location")!);
  const approval = await fetchWorker(new Request(approvedURL));
  const clientCallback = new URL(approval.headers.get("location")!);
  const code = clientCallback.searchParams.get("code")!;

  const tokenURL = "https://owner.example/token";
  const tokenResponse = await fetchWorker(new Request(tokenURL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      DPoP: await dpopProof(tokenURL, "POST", keyPair),
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: "https://client.example/app",
      redirect_uri: "https://client.example/callback",
      code_verifier: verifier,
    }),
  }));
  const body = await tokenResponse.json() as { access_token: string };
  return { token: body.access_token, keyPair };
}

async function fetchWorker(request: Request): Promise<Response> {
  return worker.fetch(request, testEnv, createExecutionContext());
}

// --- Generic route dispatch (#746) ---------------------------------------------------------
// These run through worker.fetch inside the workerd pool, i.e. the same runtime `wrangler dev`
// uses, so the dispatch behavior they pin down is what local preview and production serve.

test("routing: undeclared method gets 405 with an Allow header naming the declared methods", async () => {
  const inbox = await fetchWorker(new Request("https://owner.example/inbox", { method: "GET" }));
  expect(inbox.status).toBe(405);
  expect(inbox.headers.get("allow")).toBe("POST");

  const metadata = await fetchWorker(
    new Request("https://owner.example/.well-known/oauth-authorization-server", { method: "POST" }),
  );
  expect(metadata.status).toBe(405);
  expect(metadata.headers.get("allow")).toBe("GET, HEAD");
});

test("routing: HEAD mirrors GET's status and headers with an empty body where declared", async () => {
  const get = await fetchWorker(new Request("https://owner.example/.well-known/oauth-authorization-server"));
  const head = await fetchWorker(
    new Request("https://owner.example/.well-known/oauth-authorization-server", { method: "HEAD" }),
  );
  expect(head.status).toBe(get.status);
  expect(head.headers.get("content-type")).toBe(get.headers.get("content-type"));
  expect(await head.text()).toBe("");
});

test("routing: query parameters reach the handler unchanged", async () => {
  // The authorize handler can only render this consent page by reading the query it was sent.
  const authorize = new URL("https://owner.example/authorize");
  authorize.search = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: "state-query-preserved",
    code_challenge: await pkceChallenge("query-preservation-verifier-that-is-long-enough-to-be-valid"),
    code_challenge_method: "S256",
    scope: "create",
  }).toString();
  const response = await fetchWorker(new Request(authorize));
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(body).toContain("https://client.example/app");
  expect(body).toContain("state-query-preserved");
});

test("routing: unknown well-known names and the bare directory return a plain 404, not HTML", async () => {
  for (const path of ["/.well-known", "/.well-known/", "/.well-known/does-not-exist"]) {
    const response = await fetchWorker(new Request(`https://owner.example${path}`));
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toContain("text/plain");
  }
});

test("routing: case, trailing-slash, and encoded well-known variants return a true 404", async () => {
  for (const path of [
    "/.WELL-KNOWN/oauth-authorization-server",
    "/.well-known/oauth-authorization-server/",
    "/.well-known/OAuth-Authorization-Server",
    "/%2Ewell-known/oauth-authorization-server",
  ]) {
    const response = await fetchWorker(new Request(`https://owner.example${path}`));
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toContain("text/plain");
  }
});

test("routing: malformed percent-encoding returns a true 404", async () => {
  const response = await fetchWorker(new Request("https://owner.example/%E0%A4%A"));
  expect(response.status).toBe(404);
  expect(response.headers.get("content-type")).toContain("text/plain");
});

test("routing: unrelated paths fall through to the asset-first branch", async () => {
  // The vitest miniflare env deliberately has no ASSETS binding, so reaching the asset branch
  // surfaces as its 500 sentinel — proving an unclaimed path was neither 404'd nor 405'd by
  // the dispatcher.
  const response = await fetchWorker(new Request("https://owner.example/about"));
  expect(response.status).toBe(500);
  expect(await response.text()).toBe("No assets binding configured");
});

test("routing: /x/goal is handled unconditionally (#1270 slice 2), even with no running experiment", async () => {
  const postResponse = await fetchWorker(
    new Request("https://owner.example/x/goal?e=homepage-hero", { method: "POST" }),
  );
  expect(postResponse.status).toBe(204);

  const getResponse = await fetchWorker(new Request("https://owner.example/x/goal?e=homepage-hero"));
  expect(getResponse.status).toBe(405);
  expect(getResponse.headers.get("allow")).toBe("POST");
});

test("routing: with no running experiment configured, existing routes are unaffected", async () => {
  const postResponse = await fetchWorker(
    new Request("https://owner.example/inbox", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ subject: "Hi", from: "a@example.com", message: "hello" }),
    }),
  );
  expect(postResponse.status).toBe(202);

  const assetResponse = await fetchWorker(new Request("https://owner.example/about"));
  expect(assetResponse.status).toBe(500);
  expect(await assetResponse.text()).toBe("No assets binding configured");
});

test("IndieAuth metadata advertises a full RFC 8414 authorization-server document (#1580)", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/oauth-authorization-server"));
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toMatchObject({
    issuer: "https://owner.example",
    authorization_endpoint: "https://owner.example/authorize",
    token_endpoint: "https://owner.example/token",
    revocation_endpoint: "https://owner.example/revocation",
    revocation_endpoint_auth_methods_supported: ["none"],
    grant_types_supported: ["authorization_code"],
    response_types_supported: ["code"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: ["create", "update", "delete", "media", "follow", "channels", "read"],
  });
});

test("RFC 9728 protected-resource metadata points agents at this site's own authorization server (#1577)", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/oauth-protected-resource"));
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toBe("application/json");
  await expect(response.json()).resolves.toStrictEqual({
    resource: "https://owner.example",
    authorization_servers: ["https://owner.example"],
    scopes_supported: ["create", "update", "delete", "media", "follow", "channels", "read"],
    dpop_bound_access_tokens_required: true,
    dpop_signing_alg_values_supported: ["ES256", "ES384", "RS256", "PS256"],
  });
});

test("routing: protected-resource metadata rejects undeclared methods and mirrors HEAD", async () => {
  const post = await fetchWorker(
    new Request("https://owner.example/.well-known/oauth-protected-resource", { method: "POST" }),
  );
  expect(post.status).toBe(405);
  expect(post.headers.get("allow")).toBe("GET, HEAD");

  const get = await fetchWorker(new Request("https://owner.example/.well-known/oauth-protected-resource"));
  const head = await fetchWorker(
    new Request("https://owner.example/.well-known/oauth-protected-resource", { method: "HEAD" }),
  );
  expect(head.status).toBe(get.status);
  expect(head.headers.get("content-type")).toBe(get.headers.get("content-type"));
  expect(await head.text()).toBe("");
});

test("RFC 9727 API catalog lists every live protocol when fully provisioned (#1659)", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/api-catalog"));
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toBe("application/linkset+json");
  const body = (await response.json()) as { linkset: { anchor: string; "service-desc": { href: string }[] }[] };
  expect(body.linkset.map((entry) => entry.anchor)).toStrictEqual([
    "https://owner.example/.well-known/oauth-authorization-server",
    "https://owner.example/webmention",
    "https://owner.example/micropub",
    "https://owner.example/websub",
    "https://owner.example/users/site",
    "https://owner.example/.well-known/webfinger",
    "https://owner.example/.well-known/nodeinfo",
  ]);
  const indieauth = body.linkset[0];
  expect(indieauth["service-desc"]).toStrictEqual([{ href: "https://indieauth.spec.indieweb.org/" }]);
});

test("RFC 9727 API catalog always lists IndieAuth even with nothing else provisioned", async () => {
  const bareEnv = {
    ...testEnv,
    WEBMENTION_QUEUE: undefined,
    MICROPUB_DB: undefined,
    WEBSUB_QUEUE: undefined,
    WEBSUB_DB: undefined,
    ACTOR: undefined,
  } as WorkerEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/.well-known/api-catalog"),
    bareEnv,
    createExecutionContext(),
  );
  const body = (await response.json()) as { linkset: { anchor: string }[] };
  expect(body.linkset.map((entry) => entry.anchor)).toStrictEqual([
    "https://owner.example/.well-known/oauth-authorization-server",
  ]);
});

test("RFC 9727 API catalog omits an unprovisioned protocol and keeps the rest", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/.well-known/api-catalog"),
    { ...testEnv, MICROPUB_DB: undefined } as WorkerEnv,
    createExecutionContext(),
  );
  const body = (await response.json()) as { linkset: { anchor: string }[] };
  const anchors = body.linkset.map((entry) => entry.anchor);
  expect(anchors).not.toContain("https://owner.example/micropub");
  expect(anchors).toContain("https://owner.example/webmention");
});

test("routing: api-catalog rejects undeclared methods and mirrors HEAD", async () => {
  const post = await fetchWorker(new Request("https://owner.example/.well-known/api-catalog", { method: "POST" }));
  expect(post.status).toBe(405);
  expect(post.headers.get("allow")).toBe("GET, HEAD");

  const get = await fetchWorker(new Request("https://owner.example/.well-known/api-catalog"));
  const head = await fetchWorker(new Request("https://owner.example/.well-known/api-catalog", { method: "HEAD" }));
  expect(head.status).toBe(get.status);
  expect(head.headers.get("content-type")).toBe(get.headers.get("content-type"));
  expect(await head.text()).toBe("");
});

test("IndieAuth owner consent completes PKCE sign-in and issues a DPoP token", async () => {
  const verifier = "anglesite-indieauth-verifier-with-more-than-forty-three-characters";
  const challenge = await pkceChallenge(verifier);
  const authorize = new URL("https://owner.example/authorize");
  authorize.search = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: "state-355",
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope: "create update",
  }).toString();

  const prompt = await fetchWorker(new Request(authorize));
  expect(prompt.status).toBe(200);
  expect(await prompt.text()).toContain("Approve sign-in");

  const consentForm = new URLSearchParams(authorize.search);
  consentForm.set("password", "correct horse battery staple");
  const consent = await fetchWorker(new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.35" },
    body: consentForm,
  }));
  expect(consent.status).toBe(303);
  const approvedURL = new URL(consent.headers.get("location")!);
  expect(approvedURL.pathname).toBe("/authorize");
  expect(approvedURL.searchParams.get("consent")).toBeTruthy();

  const approval = await fetchWorker(new Request(approvedURL));
  expect(approval.status).toBe(302);
  const clientCallback = new URL(approval.headers.get("location")!);
  expect(clientCallback.origin).toBe("https://client.example");
  expect(clientCallback.searchParams.get("state")).toBe("state-355");
  const code = clientCallback.searchParams.get("code");
  expect(code).toBeTruthy();

  const tokenURL = "https://owner.example/token";
  const token = await fetchWorker(new Request(tokenURL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      DPoP: await dpopProof(tokenURL),
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: code!,
      client_id: "https://client.example/app",
      redirect_uri: "https://client.example/callback",
      code_verifier: verifier,
    }),
  }));
  expect(token.status).toBe(200);
  await expect(token.json()).resolves.toMatchObject({
    token_type: "DPoP",
    scope: "create update",
    me: "https://owner.example/",
  });
});

test("IndieAuth app callback bridges the redirect into the Anglesite custom scheme", async () => {
  const response = await fetchWorker(new Request(
    "https://owner.example/indieauth/app-callback?code=abc%2F123&state=state-868&iss=https%3A%2F%2Fowner.example",
  ));
  expect(response.status).toBe(302);
  // The query string passes through byte-for-byte — the app re-validates state and redeems the
  // code itself; re-encoding here could corrupt a percent-encoded code.
  expect(response.headers.get("location")).toBe(
    "io.dwk.anglesite://indieauth-callback?code=abc%2F123&state=state-868&iss=https%3A%2F%2Fowner.example",
  );
  // The URL carries a one-time authorization code — nothing on this path may be cached.
  expect(response.headers.get("cache-control")).toBe("no-store");
});

test("IndieAuth app callback with no query still redirects into the app", async () => {
  const response = await fetchWorker(new Request("https://owner.example/indieauth/app-callback"));
  expect(response.status).toBe(302);
  expect(response.headers.get("location")).toBe("io.dwk.anglesite://indieauth-callback");
});

test("mintAccessToken: issues a token whose DPoP proof (same key pair) is accepted on a resource request", async () => {
  const { token, keyPair } = await mintAccessToken("create update media");
  expect(token.length).toBeGreaterThan(0);

  // Reuse the same key pair for a request to /token again (a cheap way to prove the key pair is
  // usable for more than the mint call itself, without depending on Task 9's /micropub route).
  const proof = await dpopProof("https://owner.example/micropub", "POST", keyPair);
  expect(proof.split(".")).toHaveLength(3);
});

test("IndieAuth consent rejects the wrong owner password", async () => {
  const body = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "https://client.example/callback",
    response_type: "code",
    state: "wrong-password",
    code_challenge: "challenge",
    code_challenge_method: "S256",
    scope: "create",
    password: "incorrect",
  });
  const response = await fetchWorker(new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.36" },
    body,
  }));
  expect(response.status).toBe(401);
});

function sampleAuthorizationRequest(overrides: Partial<AuthorizationRequest> = {}): AuthorizationRequest {
  return {
    clientId: "https://client.example/app",
    redirectUri: "https://client.example/callback",
    state: "state-355",
    codeChallenge: "challenge",
    codeChallengeMethod: "S256",
    scope: "create",
    scopes: ["create"],
    ...overrides,
  };
}

test("verifyConsentToken: accepts a token replayed against the exact request it was issued for", async () => {
  const request = sampleAuthorizationRequest();
  const token = await createConsentToken(request, "test-signing-key");
  expect(await verifyConsentToken(token, request, "test-signing-key")).toBe(true);
});

test("verifyConsentToken: rejects a token replayed against a different client_id", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ clientId: "https://attacker.example/app" });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token replayed against a different redirect_uri", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ redirectUri: "https://attacker.example/callback" });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token replayed with an escalated scope", async () => {
  const granted = sampleAuthorizationRequest();
  const token = await createConsentToken(granted, "test-signing-key");
  const tampered = sampleAuthorizationRequest({ scope: "create update delete", scopes: ["create", "update", "delete"] });
  expect(await verifyConsentToken(token, tampered, "test-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects a token signed with a different key", async () => {
  const request = sampleAuthorizationRequest();
  const token = await createConsentToken(request, "test-signing-key");
  expect(await verifyConsentToken(token, request, "a-different-signing-key")).toBe(false);
});

test("verifyConsentToken: rejects an expired token", async () => {
  const request = sampleAuthorizationRequest();
  const issuedAt = 1_000;
  const token = await createConsentToken(request, "test-signing-key", issuedAt);
  expect(await verifyConsentToken(token, request, "test-signing-key", issuedAt + 301)).toBe(false);
});

test("handleIndieAuthConsent: 503s when a required secret isn't configured", async () => {
  const { TOKEN_SIGNING_KEY: _unusedSigningKey, ...envWithoutSigningKey } = testEnv;
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.40" },
    body: new URLSearchParams({ password: "correct horse battery staple" }),
  });
  const response = await handleIndieAuthConsent(request, envWithoutSigningKey as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleIndieAuthConsent: 503s when the rate-limit KV isn't bound (fails closed, not open)", async () => {
  const { SOCIAL_KV: _unusedSocialKV, ...envWithoutKV } = testEnv;
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.42" },
    body: new URLSearchParams({ password: "correct horse battery staple" }),
  });
  const response = await handleIndieAuthConsent(request, envWithoutKV as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleIndieAuthConsent: 400s on a malformed (oversized) form body", async () => {
  const request = new Request("https://owner.example/indieauth/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.41" },
    body: `password=${"x".repeat(20_000)}`,
  });
  const response = await handleIndieAuthConsent(request, testEnv);
  expect(response.status).toBe(400);
});

test("handleIndieAuthConsent: 429s once the per-IP login attempt limit is exceeded", async () => {
  const makeRequest = () =>
    new Request("https://owner.example/indieauth/consent", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.43" },
      body: new URLSearchParams({ password: "incorrect" }),
    });
  for (let i = 0; i < 5; i++) {
    const response = await handleIndieAuthConsent(makeRequest(), testEnv);
    expect(response.status).toBe(401);
  }
  const limited = await handleIndieAuthConsent(makeRequest(), testEnv);
  expect(limited.status).toBe(429);
});

// --- Solid-OIDC identity endpoint + consent bridge (#1071) ---------------------------------

function sampleSolidOidcAuthorizationRequest(
  overrides: Partial<SolidOidcAuthorizationRequest> = {},
): SolidOidcAuthorizationRequest {
  return {
    clientId: "https://client.example/app",
    redirectUri: "https://client.example/callback",
    scope: "webid",
    codeChallenge: "challenge",
    state: "state-355",
    nonce: "nonce-123",
    ...overrides,
  };
}

const OWNER_WEBID = "https://example.com/profile/card#me";

test("createSolidOidcConsentToken / verifySolidOidcConsentToken: round-trips a webid within the TTL", async () => {
  const request = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(request, OWNER_WEBID, "signing-key", 1000);
  const grant = await verifySolidOidcConsentToken(token, request, "signing-key", 1050);
  expect(grant?.webid).toBe(OWNER_WEBID);
});

test("verifySolidOidcConsentToken: rejects an expired token", async () => {
  const request = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(request, OWNER_WEBID, "signing-key", 1000);
  const grant = await verifySolidOidcConsentToken(token, request, "signing-key", 10_000);
  expect(grant).toBeNull();
});

test("verifySolidOidcConsentToken: rejects a token signed with a different key", async () => {
  const request = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(request, OWNER_WEBID, "signing-key", 1000);
  const grant = await verifySolidOidcConsentToken(token, request, "wrong-key", 1050);
  expect(grant).toBeNull();
});

test("verifySolidOidcConsentToken: accepts a token replayed against the exact request it was issued for", async () => {
  const request = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(request, OWNER_WEBID, "signing-key", 1000);
  const grant = await verifySolidOidcConsentToken(token, request, "signing-key", 1050);
  expect(grant).not.toBeNull();
  expect(grant?.clientId).toBe(request.clientId);
  expect(grant?.redirectUri).toBe(request.redirectUri);
  expect(grant?.webid).toBe(OWNER_WEBID);
});

test("verifySolidOidcConsentToken: rejects a token replayed against a different client_id", async () => {
  const granted = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(granted, OWNER_WEBID, "signing-key", 1000);
  const tampered = sampleSolidOidcAuthorizationRequest({ clientId: "https://attacker.example/app" });
  const grant = await verifySolidOidcConsentToken(token, tampered, "signing-key", 1050);
  expect(grant).toBeNull();
});

test("verifySolidOidcConsentToken: rejects a token replayed against a different redirect_uri", async () => {
  const granted = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(granted, OWNER_WEBID, "signing-key", 1000);
  const tampered = sampleSolidOidcAuthorizationRequest({ redirectUri: "https://attacker.example/callback" });
  const grant = await verifySolidOidcConsentToken(token, tampered, "signing-key", 1050);
  expect(grant).toBeNull();
});

test("verifySolidOidcConsentToken: rejects a token replayed with an escalated scope", async () => {
  const granted = sampleSolidOidcAuthorizationRequest();
  const token = await createSolidOidcConsentToken(granted, OWNER_WEBID, "signing-key", 1000);
  const tampered = sampleSolidOidcAuthorizationRequest({ scope: "webid offline_access" });
  const grant = await verifySolidOidcConsentToken(token, tampered, "signing-key", 1050);
  expect(grant).toBeNull();
});

test("handleSolidOidc: 503s when OIDC_SIGNING_KEY is unbound", async () => {
  const request = new Request("https://example.com/oidc/jwks");
  const response = await handleSolidOidc(request, { ...testEnv, OIDC_SIGNING_KEY: undefined }, createExecutionContext());
  expect(response.status).toBe(503);
});

test("handleSolidOidc: 503s when OIDC_SIGNING_KEY is a parseable-but-non-object JSON value", async () => {
  const request = new Request("https://example.com/oidc/jwks");
  const response = await handleSolidOidc(request, { ...testEnv, OIDC_SIGNING_KEY: "null" }, createExecutionContext());
  expect(response.status).toBe(503);
});

test("handleSolidOidcConsent: 503s when a required secret isn't configured", async () => {
  const { TOKEN_SIGNING_KEY: _unusedSigningKey, ...envWithoutSigningKey } = testEnv;
  const body = new URLSearchParams({ password: "correct horse battery staple", webid: OWNER_WEBID });
  const request = new Request("https://example.com/oidc/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.60" },
    body: body.toString(),
  });
  const response = await handleSolidOidcConsent(request, envWithoutSigningKey as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleSolidOidcConsent: 503s when the rate-limit KV isn't bound (fails closed, not open)", async () => {
  const { SOCIAL_KV: _unusedSocialKV, ...envWithoutKV } = testEnv;
  const body = new URLSearchParams({ password: "correct horse battery staple", webid: OWNER_WEBID });
  const request = new Request("https://example.com/oidc/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.61" },
    body: body.toString(),
  });
  const response = await handleSolidOidcConsent(request, envWithoutKV as unknown as WorkerEnv);
  expect(response.status).toBe(503);
});

test("handleSolidOidcConsent: rejects the wrong owner password", async () => {
  const body = new URLSearchParams({ password: "wrong", webid: OWNER_WEBID });
  const request = new Request("https://example.com/oidc/consent", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.62" },
    body: body.toString(),
  });
  const response = await handleSolidOidcConsent(request, testEnv);
  expect(response.status).toBe(401);
});

/**
 * Extracts every `<input type="hidden" name="..." value="...">` field from a rendered
 * consent page, unescaping the handful of entities `escapeHTML` (worker.ts) produces.
 */
function extractHiddenFields(html: string): Record<string, string> {
  const unescapeHTML = (value: string): string =>
    value
      .replace(/&quot;/g, "\"")
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&");
  const fields: Record<string, string> = {};
  const pattern = /<input type="hidden" name="([^"]*)" value="([^"]*)">/g;
  for (const match of html.matchAll(pattern)) {
    fields[unescapeHTML(match[1] ?? "")] = unescapeHTML(match[2] ?? "");
  }
  return fields;
}

test("Solid-OIDC consent round trip: normalizes redirect_uri and defaults scope so mint and verify agree (#1071 final review)", async () => {
  // Reproduces the exact failure mode the final review flagged: a bare-origin `redirect_uri`
  // (no trailing slash) and no `scope` at all in the authorization request — the shape
  // `@dwk/solid-oidc`'s own `handleAuthorize` normalizes (`new URL(...).toString()` adds a
  // trailing slash) and defaults (`?? "openid webid"`) before invoking the approval hook.
  // Before the fix, the consent page's hidden fields echoed the *raw* query string, so the
  // grant minted from the consent POST never matched what the live request's normalized/
  // defaulted `authorizationRequest` expected at verify time — bouncing the owner back to this
  // same consent page forever, even with the correct password.
  const jwk = await generateSigningJwk();
  const oidcEnv = { ...testEnv, OIDC_SIGNING_KEY: JSON.stringify(jwk) };
  const ctx = createExecutionContext();

  const verifier = "anglesite-oidc-round-trip-verifier-with-more-than-forty-three-characters";
  const challenge = await pkceChallenge(verifier);

  const authorizeUrl = new URL("https://owner.example/oidc/authorize");
  authorizeUrl.search = new URLSearchParams({
    client_id: "https://client.example/app",
    redirect_uri: "http://localhost:3000",
    response_type: "code",
    state: "round-trip-state",
    code_challenge: challenge,
    code_challenge_method: "S256",
    // Deliberately no `scope` — exercises the library's default.
  }).toString();

  const consentPageResponse = await handleSolidOidc(new Request(authorizeUrl), oidcEnv, ctx);
  expect(consentPageResponse.status).toBe(200);
  const hidden = extractHiddenFields(await consentPageResponse.text());

  // The fix: hidden fields carry the library's normalized/defaulted values, not a raw echo.
  expect(hidden.redirect_uri).toBe("http://localhost:3000/");
  expect(hidden.scope).toBe("openid webid");

  const consentBody = new URLSearchParams(hidden);
  consentBody.set("password", "correct horse battery staple");
  const consentResponse = await handleSolidOidcConsent(
    new Request("https://owner.example/oidc/consent", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "CF-Connecting-IP": "192.0.2.71" },
      body: consentBody.toString(),
    }),
    oidcEnv,
  );
  expect(consentResponse.status).toBe(303);
  const location = consentResponse.headers.get("location");
  expect(location).not.toBeNull();

  // Replay the same bare-origin/omitted-scope request against the live authorize endpoint. A
  // 302 with a `code` proves verification succeeded; the pre-fix behavior was a 200 back to the
  // consent page (an infinite loop for this client shape), never a successful redirect.
  const finalResponse = await handleSolidOidc(new Request(location as string), oidcEnv, ctx);
  expect(finalResponse.status).toBe(302);
  const finalLocation = new URL(finalResponse.headers.get("location") ?? "");
  expect(finalLocation.origin + finalLocation.pathname).toBe("http://localhost:3000/");
  expect(finalLocation.searchParams.get("code")).toBeTruthy();
  expect(finalLocation.searchParams.get("state")).toBe("round-trip-state");
});

test("handleSolidOidc: 503s when OIDC_SIGNING_KEY is a parseable object missing required JWK members", async () => {
  const request = new Request("https://example.com/oidc/jwks");
  const response = await handleSolidOidc(
    request,
    { ...testEnv, OIDC_SIGNING_KEY: JSON.stringify({ kty: "nonsense" }) },
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

// --- Inbound Webmention receive (V-3.1, #359) ----------------------------------------------
// Composition of @dwk/webmention's receiver. These run through worker.fetch in the workerd pool
// with WEBMENTION_QUEUE/WEBMENTION_INBOX/SITE_URL bound (see vitest.config.ts), so they exercise
// the same synchronous validate-then-enqueue path production serves. Async link-verification is
// the library's own concern (covered by its suite + webmention.rocks), not re-tested here.

function webmentionForm(fields: Record<string, string>): Request {
  return new Request("https://owner.example/webmention", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
}

test("webmention receive: a valid source/target under this origin is accepted (202)", async () => {
  const response = await fetchWorker(
    webmentionForm({ source: "https://commenter.example/reply", target: "https://owner.example/blog/hello/" }),
  );
  expect(response.status).toBe(202);
});

test("webmention receive: a missing field is rejected (400)", async () => {
  const noTarget = await fetchWorker(webmentionForm({ source: "https://commenter.example/reply" }));
  expect(noTarget.status).toBe(400);
  const noSource = await fetchWorker(webmentionForm({ target: "https://owner.example/blog/hello/" }));
  expect(noSource.status).toBe(400);
});

test("webmention receive: source equal to target is rejected (400)", async () => {
  const response = await fetchWorker(
    webmentionForm({ source: "https://owner.example/x/", target: "https://owner.example/x/" }),
  );
  expect(response.status).toBe(400);
});

test("webmention receive: a target on a foreign host is rejected (400)", async () => {
  const response = await fetchWorker(
    webmentionForm({ source: "https://commenter.example/reply", target: "https://elsewhere.example/post/" }),
  );
  expect(response.status).toBe(400);
});

test("webmention receive: a non-POST method gets 405 with Allow: POST", async () => {
  const response = await fetchWorker(new Request("https://owner.example/webmention", { method: "GET" }));
  expect(response.status).toBe(405);
  expect(response.headers.get("allow")).toBe("POST");
});

test("webmention receive: 503 when inbound Webmention isn't provisioned (no queue binding)", async () => {
  const { WEBMENTION_QUEUE: _unusedQueue, ...envWithoutQueue } = testEnv;
  const response = await worker.fetch(
    webmentionForm({ source: "https://commenter.example/reply", target: "https://owner.example/blog/hello/" }),
    envWithoutQueue as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("webmention queue consumer: no-ops (does not throw) when the inbox/site origin is unprovisioned", async () => {
  const { WEBMENTION_INBOX: _unusedInbox, SITE_URL: _unusedSiteURL, ...envWithoutInbox } = testEnv;
  const emptyBatch = { queue: "site-webmention", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, envWithoutInbox as WorkerEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

// --- Micropub server (V-3.2, #360) ---------------------------------------------------------
// Composition of @dwk/micropub's create/update/delete endpoint + media endpoint. These run
// through worker.fetch in the workerd pool with MICROPUB_DB/MEDIA/AUTH_DB/TOKEN_SIGNING_KEY
// bound (see vitest.config.ts), exercising the same dispatch path production serves. The
// library's own mf2/auth/media internals are its own concern (covered by its suite +
// micropub.rocks), not re-tested here.

test("micropub: an unauthorized request (no Authorization header) is rejected", async () => {
  const response = await fetchWorker(new Request("https://owner.example/micropub?q=config"));
  expect(response.status).toBe(401);
  // RFC 9728 §5.1 discovery signal (#1665): points an agent at the protected-resource metadata
  // document straight from the failed request.
  expect(response.headers.get("www-authenticate")).toBe(
    'DPoP resource_metadata="https://owner.example/.well-known/oauth-protected-resource"',
  );
});

test("micropub: a valid token creates a post (201 + Location)", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["Hello from a Micropub client"] },
    }),
  }));
  expect(response.status).toBe(201);
  expect(response.headers.get("location")).toBeTruthy();
});

test("micropub: q=config is served to an authorized request", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub?q=config";
  const response = await fetchWorker(new Request(url, {
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "GET", keyPair, token),
    },
  }));
  expect(response.status).toBe(200);
});

test("micropub: 503 when MICROPUB_DB isn't bound", async () => {
  const { MICROPUB_DB: _unusedDB, ...envWithoutDB } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/micropub?q=config"),
    envWithoutDB as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("micropub: a note (plain content, no name) is created under /notes/", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["Just a quick note"] },
    }),
  }));
  expect(response.status).toBe(201);
  const location = response.headers.get("location");
  expect(location).toMatch(/^https:\/\/owner\.example\/notes\/[0-9a-z-]+$/);
});

test("micropub: an article (name distinct from content) is created under /articles/", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: {
        name: ["My Big Announcement"],
        content: ["Today I'm launching something new..."],
      },
    }),
  }));
  expect(response.status).toBe(201);
  expect(response.headers.get("location")).toMatch(/^https:\/\/owner\.example\/articles\/my-big-announcement/);
});

test("micropub: a bookmark (bookmark-of) is created under /bookmarks/", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { "bookmark-of": ["https://example.com/article"] },
    }),
  }));
  expect(response.status).toBe(201);
  expect(response.headers.get("location")).toMatch(/^https:\/\/owner\.example\/bookmarks\//);
});

test("micropub: an h-event post is created under /events/", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-event"],
      properties: { name: ["Meetup"], start: ["2026-08-01T18:00:00Z"] },
    }),
  }));
  expect(response.status).toBe(201);
  expect(response.headers.get("location")).toMatch(/^https:\/\/owner\.example\/events\//);
});

test("micropub: an unrecognized type (h-card) falls back to the flat URL scheme", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-card"],
      properties: { name: ["Jane Doe"] },
    }),
  }));
  expect(response.status).toBe(201);
  const location = response.headers.get("location") ?? "";
  // Flat scheme: exactly one path segment, no collection prefix.
  expect(new URL(location).pathname.split("/").filter(Boolean).length).toBe(1);
});

// --- WebSub hub (V-3.3, #361) ---------------------------------------------------------------
// Composition of @dwk/websub's hub. These run through worker.fetch in the workerd pool with
// WEBSUB_DB/WEBSUB_QUEUE/SITE_URL bound (see vitest.config.ts), so they exercise the same
// synchronous validate-then-enqueue path production serves. Intent verification, fan-out, and
// HMAC delivery signing are the library's own concern (covered by its suite + websub.rocks),
// not re-tested here. SITE_URL (https://test.example) is the canonical topic origin — requests
// arrive on a different origin below precisely to pin down that topics are keyed on SITE_URL,
// not on whatever host the request happened to hit.

function websubForm(fields: Record<string, string>): Request {
  return new Request("https://owner.example/websub", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
}

test("websub hub: a subscribe for a canonical feed topic is accepted (202)", async () => {
  const response = await fetchWorker(
    websubForm({
      "hub.mode": "subscribe",
      "hub.callback": "https://subscriber.example/callback",
      "hub.topic": "https://test.example/rss.xml",
    }),
  );
  expect(response.status).toBe(202);
});

test("websub hub: every root feed is a subscribable topic", async () => {
  for (const path of ["/rss.xml", "/atom.xml", "/feed.json"]) {
    const response = await fetchWorker(
      websubForm({
        "hub.mode": "subscribe",
        "hub.callback": "https://subscriber.example/callback",
        "hub.topic": `https://test.example${path}`,
      }),
    );
    expect(response.status).toBe(202);
  }
});

test("websub hub: a subscribe for a non-feed topic is rejected (400)", async () => {
  const response = await fetchWorker(
    websubForm({
      "hub.mode": "subscribe",
      "hub.callback": "https://subscriber.example/callback",
      "hub.topic": "https://test.example/blog/hello/",
    }),
  );
  expect(response.status).toBe(400);
});

test("websub hub: topics are keyed on SITE_URL, not the request origin", async () => {
  // The request arrives on owner.example, but the canonical origin is SITE_URL
  // (test.example) — a feed path on the request origin is not a topic this hub serves.
  const response = await fetchWorker(
    websubForm({
      "hub.mode": "subscribe",
      "hub.callback": "https://subscriber.example/callback",
      "hub.topic": "https://owner.example/rss.xml",
    }),
  );
  expect(response.status).toBe(400);
});

test("websub hub: a publish ping for a canonical feed topic is accepted (202)", async () => {
  const response = await fetchWorker(
    websubForm({ "hub.mode": "publish", "hub.url": "https://test.example/atom.xml" }),
  );
  expect(response.status).toBe(202);
});

test("websub hub: a publish ping for a foreign topic is rejected (400)", async () => {
  const response = await fetchWorker(
    websubForm({ "hub.mode": "publish", "hub.url": "https://elsewhere.example/rss.xml" }),
  );
  expect(response.status).toBe(400);
});

test("websub hub: a non-POST method gets 405 with Allow: POST", async () => {
  const response = await fetchWorker(new Request("https://owner.example/websub", { method: "GET" }));
  expect(response.status).toBe(405);
  expect(response.headers.get("allow")).toBe("POST");
});

test("websub hub: 503 when the hub isn't provisioned (no queue/store binding)", async () => {
  const { WEBSUB_QUEUE: _unusedQueue, WEBSUB_DB: _unusedDB, ...envWithoutHub } = testEnv;
  const response = await worker.fetch(
    websubForm({
      "hub.mode": "subscribe",
      "hub.callback": "https://subscriber.example/callback",
      "hub.topic": "https://test.example/rss.xml",
    }),
    envWithoutHub as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("micropub: 503 when MEDIA isn't bound", async () => {
  const { MEDIA: _unusedMedia, ...envWithoutMedia } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/micropub?q=config"),
    envWithoutMedia as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("micropub: 503 when AUTH_DB isn't bound (IndieAuth not provisioned)", async () => {
  const { AUTH_DB: _unusedAuthDB, ...envWithoutAuthDB } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/micropub?q=config"),
    envWithoutAuthDB as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("micropub: 503 when TOKEN_SIGNING_KEY isn't bound", async () => {
  const { TOKEN_SIGNING_KEY: _unusedSigningKey, ...envWithoutSigningKey } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/micropub?q=config"),
    envWithoutSigningKey as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("micropub media: uploading a file with the media scope returns 201 + Location", async () => {
  const { token, keyPair } = await mintAccessToken("media");
  const url = "https://owner.example/media";
  const form = new FormData();
  form.set("file", new File(["hello world"], "hello.txt", { type: "text/plain" }));
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: form,
  }));
  expect(response.status).toBe(201);
  const location = response.headers.get("location");
  expect(location).toBeTruthy();
  return location;
});

test("micropub media: uploading without the media scope is rejected", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/media";
  const form = new FormData();
  form.set("file", new File(["hello world"], "hello.txt", { type: "text/plain" }));
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: form,
  }));
  expect(response.status).toBe(403);
});

test("micropub media: 503 when MEDIA isn't bound", async () => {
  const { MEDIA: _unusedMedia, ...envWithoutMedia } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/media", { method: "POST" }),
    envWithoutMedia as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("routing: /media/ prefix dispatches to the Micropub handler directly (not yet reachable via run_worker_first in production, see worker.ts's ROUTES comment)", async () => {
  // A GET against a *never-uploaded* key isn't distinguishing evidence here: @dwk/micropub's own
  // handleMediaGet ("Serve a previously uploaded media blob from R2 (public, unauthenticated)")
  // also 404s a missing key — same status as the router's own unclaimed-route 404, so `not.toBe
  // (404)` can't tell "the router never dispatched" apart from "it dispatched and the library
  // legitimately reported the key missing". Upload a real object first and retrieve it by its
  // actual key instead: only a genuine dispatch into the Micropub media handler can answer with
  // the uploaded bytes, so a 200 + matching body is unambiguous proof the /media/<key> prefix
  // route reaches handleMicropub.
  const { token, keyPair } = await mintAccessToken("media");
  const uploadUrl = "https://owner.example/media";
  const form = new FormData();
  form.set("file", new File(["dispatch probe"], "probe.txt", { type: "text/plain" }));
  const upload = await fetchWorker(new Request(uploadUrl, {
    method: "POST",
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(uploadUrl, "POST", keyPair, token),
    },
    body: form,
  }));
  expect(upload.status).toBe(201);
  const location = upload.headers.get("location");
  expect(location).toBeTruthy();

  const response = await worker.fetch(
    new Request(location!, { method: "GET" }),
    testEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(200);
  // Not `text/plain` in the served response — handleMediaGet forces `application/octet-stream`
  // for any type outside its image/video/audio inline allowlist, so read the bytes directly
  // rather than `.text()` (which would warn about a non-text content-type on a body that, in
  // fact, is text).
  expect(new TextDecoder().decode(await response.arrayBuffer())).toBe("dispatch probe");
});

// --- ActivityPub actor (V-4.1, #363) --------------------------------------------------------
// Composition of @dwk/activitypub's actor document, collections, and signed inbox. These run
// through worker.fetch in the workerd pool with ACTOR/AP_PRIVATE_KEY/AP_PUBLIC_KEY/
// AP_PUBLISH_TOKEN bound (see vitest.config.ts). The library's own signature/delivery internals
// are its own concern, not re-tested here.

test("activitypub: actor document is served as activity+json", async () => {
  const response = await fetchWorker(new Request("https://owner.example/users/site"));
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toContain("application/activity+json");
  const body = await response.json() as { id: string; type: string; preferredUsername: string };
  expect(body.type).toBe("Person");
  // The actor IRI stays the fixed `/users/site` regardless of the handle (#1239).
  expect(body.id).toBe("https://owner.example/users/site");
  // preferredUsername defaults to the hostname (no AP_USERNAME set in testEnv) — see the
  // "handle" block below for the override/invalid/default coverage.
  expect(body.preferredUsername).toBe("owner.example");
});

// --- Fediverse handle: AP_USERNAME default/override/validation (#1239) ---------------------
// `preferredUsername` and the WebFinger map both derive from `resolvePreferredUsername`; the
// actor IRI (`/users/site`) never changes regardless of the resolved handle.

test("handle: preferredUsername defaults to the hostname with a leading www. stripped", async () => {
  const response = await fetchWorker(new Request("https://www.owner.example/users/site"));
  const body = await response.json() as { preferredUsername: string };
  expect(body.preferredUsername).toBe("owner.example");
});

test("handle: AP_USERNAME overrides the default preferredUsername", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/users/site"),
    { ...testEnv, AP_USERNAME: "alice" } as WorkerEnv,
    createExecutionContext(),
  );
  const body = await response.json() as { id: string; preferredUsername: string };
  expect(body.preferredUsername).toBe("alice");
  // Overriding the handle never moves the actor IRI.
  expect(body.id).toBe("https://owner.example/users/site");
});

test("handle: a mixed-case AP_USERNAME override is lowercased, matching the case-insensitive grammar", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/users/site"),
    { ...testEnv, AP_USERNAME: "Alice" } as WorkerEnv,
    createExecutionContext(),
  );
  const body = await response.json() as { preferredUsername: string };
  expect(body.preferredUsername).toBe("alice");
});

test("handle: an invalid AP_USERNAME falls back to the hostname default, not a malformed document", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/users/site"),
    { ...testEnv, AP_USERNAME: "not valid!" } as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(200);
  const body = await response.json() as { preferredUsername: string };
  expect(body.preferredUsername).toBe("owner.example");
});

test("handle: the FEP-2c59 webfinger back-link on the actor document matches the resolved handle", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/users/site"),
    { ...testEnv, AP_USERNAME: "alice" } as WorkerEnv,
    createExecutionContext(),
  );
  const body = await response.json() as { webfinger?: string };
  expect(body.webfinger).toBe("acct:alice@owner.example");
});

test("handle: HEAD /users/site still succeeds with no body to patch", async () => {
  const response = await worker.fetch(
    new Request("https://owner.example/users/site", { method: "HEAD" }),
    testEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(200);
});

test("activitypub: outbox collection is served", async () => {
  const response = await fetchWorker(new Request("https://owner.example/users/site/outbox"));
  expect(response.status).toBe(200);
});

test("activitypub: nodeinfo discovery document is served", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/nodeinfo"));
  expect(response.status).toBe(200);
});

test("activitypub: 503 when ACTOR isn't bound", async () => {
  const { ACTOR: _unusedActor, ...envWithoutActor } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/users/site"),
    envWithoutActor as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("activitypub: /inbox still serves inbox-capture, not the ActivityPub shared inbox", async () => {
  // Regression guard for the route collision documented in worker.ts's activityPubConfig
  // (sharedInbox: false) — POST /inbox must keep going to the bespoke inbox-capture handler.
  const response = await fetchWorker(new Request("https://owner.example/inbox", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "subject=Hi&from=a%40example.com&message=hello",
  }));
  expect(response.status).toBe(202);
});

test("micropub-to-activitypub fan-out: a successful create lands a Note in the outbox", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  // Unlike `fetchWorker` (which mints its own throwaway ExecutionContext), the fan-out runs in
  // `ctx.waitUntil` — it is NOT guaranteed to have completed just because `worker.fetch` resolved.
  // Capture this call's own context and explicitly `waitOnExecutionContext` it before checking the
  // outbox; without that wait this test is flaky-by-construction (a race, not a real "already
  // landed" guarantee), per `@cloudflare/vitest-pool-workers`' documented waitUntil-testing helper.
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["Hello, fediverse"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  // The collection root (`/outbox`) is just an `OrderedCollection` summary (`totalItems` +
  // `first`/`last` page links) — `@dwk/activitypub` puts the actual `orderedItems` array on the
  // paged `OrderedCollectionPage` sub-resource, so that's what a fan-out assertion needs to fetch.
  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: Array<{ object?: { content?: string } }> };
  expect(outboxPage.orderedItems?.some((item) => item.object?.content?.includes("Hello, fediverse"))).toBe(true);
});

test("micropub-to-activitypub fan-out: an mf2 rich-text content object publishes its value, not \"[object Object]\"", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      // mf2 rich-text content shape: { html, value } — not a plain string. @dwk/micropub accepts
      // this form; the fan-out must extract `.value`, never `String(...)`-coerce the object.
      properties: { content: [{ html: "<p>Hello, <b>rich</b> fediverse</p>", value: "Hello, rich fediverse" }] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: Array<{ object?: { content?: string } }> };
  expect(outboxPage.orderedItems?.some((item) => item.object?.content?.includes("Hello, rich fediverse"))).toBe(true);
  expect(outboxPage.orderedItems?.some((item) => item.object?.content?.includes("[object Object]"))).toBe(false);
});

test("micropub-to-activitypub fan-out: an html-only mf2 rich-text content object (the standard Micropub create shape, no value key) still publishes a non-empty Note", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      // Standard Micropub JSON *create* shape for HTML content: { html } with no `value` key at
      // all — `value` only appears in mf2 read back off a rendered page. The fan-out must fall
      // back to `.html`, not just `.value`, or this silently skips publishing.
      properties: { content: [{ html: "<p>Hello, html-only fediverse</p>" }] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: Array<{ object?: { content?: string } }> };
  expect(outboxPage.orderedItems?.some((item) => item.object?.content?.includes("Hello, html-only fediverse"))).toBe(true);
});

type FanOutAttachment = { type?: string; url?: string; name?: string };
type FanOutOutboxItem = { object?: { content?: string; attachment?: FanOutAttachment[] } };

test("micropub-to-activitypub fan-out (#1240): a JSON create with photos lands a Note carrying the expected attachment array", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: {
        content: ["A photo for Pixelfed"],
        // Mixed shapes: a bare URL string and the mf2 alt-text object form { value, alt } —
        // both must map to an AS2 `Image` attachment.
        photo: ["https://media.example/plain.jpg", { value: "https://media.example/alt.jpg", alt: "A view" }],
      },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  const published = outboxPage.orderedItems?.find((item) => item.object?.content?.includes("A photo for Pixelfed"));
  expect(published?.object?.attachment).toEqual([
    { type: "Image", url: "https://media.example/plain.jpg" },
    { type: "Image", url: "https://media.example/alt.jpg", name: "A view" },
  ]);
});

test("micropub-to-activitypub fan-out (#1240): a photo-less JSON create publishes a Note with no attachment field", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["No photo here"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  const published = outboxPage.orderedItems?.find((item) => item.object?.content?.includes("No photo here"));
  expect(published?.object?.attachment).toBeUndefined();
});

test("micropub-to-activitypub fan-out (#1240, #1325 review): a photo-only create with no caption still fans out", async () => {
  // The primary case #1240 exists to fix: Pixelfed renders only posts with an attachment, and a
  // bare photo with no caption text is a normal, common Micropub shape — it must not be dropped
  // by a `content`-only guard (a bug caught in PR review before merge).
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { photo: ["https://media.example/caption-less.jpg"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  const published = outboxPage.orderedItems?.find((item) =>
    item.object?.attachment?.some((attachment) => attachment.url === "https://media.example/caption-less.jpg"),
  );
  expect(published?.object?.attachment).toEqual([
    { type: "Image", url: "https://media.example/caption-less.jpg" },
  ]);
});

test("micropub-to-activitypub fan-out (#1240): a form-encoded create with photo fields lands the same attachment mapping", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const body = new URLSearchParams();
  body.append("h", "entry");
  body.append("content", "Form-encoded photo post");
  body.append("photo", "https://media.example/form-a.jpg");
  body.append("photo[]", "https://media.example/form-b.jpg");
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: body.toString(),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  const published = outboxPage.orderedItems?.find((item) => item.object?.content?.includes("Form-encoded photo post"));
  expect(published?.object?.attachment).toEqual([
    { type: "Image", url: "https://media.example/form-a.jpg" },
    { type: "Image", url: "https://media.example/form-b.jpg" },
  ]);
});

test("micropub-to-activitypub fan-out (#1240, #1325 review): a form-encoded create using the properties[photo][] nesting convention still attaches", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const body = new URLSearchParams();
  body.append("h", "entry");
  // Same `properties[x]` nesting convention `content` already falls back to
  // (`form.get("properties[content]")`) — a client using it for `photo` must not have its
  // attachments silently dropped from the fan-out.
  body.append("properties[content]", "Nested-properties photo post");
  body.append("properties[photo][]", "https://media.example/nested.jpg");
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: body.toString(),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  const published = outboxPage.orderedItems?.find((item) => item.object?.content?.includes("Nested-properties photo post"));
  expect(published?.object?.attachment).toEqual([
    { type: "Image", url: "https://media.example/nested.jpg" },
  ]);
});

test("micropub-to-activitypub fan-out: never fires when ActivityPub isn't provisioned", async () => {
  const { AP_PUBLISH_TOKEN: _unusedToken, ...envWithoutToken } = testEnv;
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const request = new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({ type: ["h-entry"], properties: { content: ["No federation here"] } }),
  });
  const response = await worker.fetch(request, envWithoutToken as WorkerEnv, createExecutionContext());
  // Must still succeed as a plain Micropub create — the fan-out being skipped is silent, not a failure.
  expect(response.status).toBe(201);
});

test("resolveFanOutAddressing (#1565): public/absent visibility always addresses the AS2 Public collection", () => {
  expect(resolveFanOutAddressing(undefined, [])).toEqual({ to: ["https://www.w3.org/ns/activitystreams#Public"] });
  expect(resolveFanOutAddressing("public", ["https://mastodon.example/users/friend"])).toEqual({
    to: ["https://www.w3.org/ns/activitystreams#Public"],
  });
});

test("resolveFanOutAddressing (#1565): restricted visibility with linked contacts addresses them blindly, never publicly", () => {
  expect(resolveFanOutAddressing("contacts", ["https://mastodon.example/users/friend", "https://a.example/users/b"]))
    .toEqual({ bto: ["https://mastodon.example/users/friend", "https://a.example/users/b"] });
});

test("resolveFanOutAddressing (#1565): restricted visibility with no linked contacts returns null rather than falling back to public", () => {
  // The critical privacy invariant: nobody to `bto` deliver to must skip federation entirely, not
  // default to `{ to: [Public] }` — see the doc comment on `resolveFanOutAddressing`.
  expect(resolveFanOutAddressing("contacts", [])).toBeNull();
});

test("micropub-to-activitypub fan-out (#1565): a restricted JSON create with linked contacts delivers via bto, never appears in the public outbox", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: {
        content: ["For contacts only"],
        visibility: ["contacts"],
        // The ephemeral, never-persisted delivery hint (#1565) — see `handleMicropub`'s
        // pre-`micropub()` extraction and `MicropubPost`'s `mp-*` command convention.
        "mp-bto": ["https://mastodon.example/users/friend"],
      },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  expect(outboxPage.orderedItems?.some((item) => item.object?.content?.includes("For contacts only"))).toBe(false);
});

test("micropub-to-activitypub fan-out (#1565): a restricted create with no linked contacts fans out to nobody, not the public", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["Restricted with no linked contacts"], visibility: ["contacts"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  expect(
    outboxPage.orderedItems?.some((item) => item.object?.content?.includes("Restricted with no linked contacts")),
  ).toBe(false);
});

test("micropub-to-activitypub fan-out (#1565): a form-encoded restricted create reads visibility and mp-bto[] the same way", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const body = new URLSearchParams();
  body.append("h", "entry");
  body.append("content", "Form-encoded restricted post");
  body.append("visibility", "contacts");
  body.append("mp-bto[]", "https://mastodon.example/users/friend");
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: body.toString(),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as { orderedItems?: FanOutOutboxItem[] };
  expect(
    outboxPage.orderedItems?.some((item) => item.object?.content?.includes("Form-encoded restricted post")),
  ).toBe(false);
});

test("tagFediverseUrl: appends utm params when a campaign targets fediverse", () => {
  const campaigns = [
    { source: "fediverse", medium: "social", campaign: "affiliate-2026", appliesTo: ["fediverse"] },
  ];
  const tagged = tagFediverseUrl("https://owner.example/notes/abc/", campaigns);
  const u = new URL(tagged);
  expect(u.searchParams.get("utm_source")).toBe("fediverse");
  expect(u.searchParams.get("utm_medium")).toBe("social");
  expect(u.searchParams.get("utm_campaign")).toBe("affiliate-2026");
});

test("tagFediverseUrl: returns the url unchanged when no campaign targets fediverse", () => {
  const campaigns = [{ source: "rss", medium: "feed", campaign: "x", appliesTo: ["blog"] }];
  expect(tagFediverseUrl("https://owner.example/notes/abc/", campaigns)).toBe("https://owner.example/notes/abc/");
});

test("tagFediverseUrl: a malformed artifact (not an array) is treated as no campaigns", () => {
  expect(tagFediverseUrl("https://owner.example/notes/abc/", { bad: true })).toBe(
    "https://owner.example/notes/abc/",
  );
});

test("tagFediverseUrl: malformed individual entries in the artifact are ignored", () => {
  const campaigns = [{ source: "fediverse" }, { source: "fediverse", medium: "social", campaign: "x", appliesTo: ["fediverse"] }];
  const tagged = tagFediverseUrl("https://owner.example/notes/abc/", campaigns);
  expect(new URL(tagged).searchParams.get("utm_campaign")).toBe("x");
});

test("tagFediverseUrl: returns the original string unchanged rather than throwing on an unparseable URL", () => {
  const campaigns = [
    { source: "fediverse", medium: "social", campaign: "affiliate-2026", appliesTo: ["fediverse"] },
  ];
  expect(() => tagFediverseUrl("not a url", campaigns)).not.toThrow();
  expect(tagFediverseUrl("not a url", campaigns)).toBe("not a url");
});

test("micropub-to-activitypub fan-out: outbox Note.url matches the created post's Location when the default utm-codes.json has no active Fediverse campaign", async () => {
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/micropub";
  const ctx = createExecutionContext();
  const createResponse = await worker.fetch(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      type: ["h-entry"],
      properties: { content: ["UTM url wiring check"] },
    }),
  }), testEnv, ctx);
  expect(createResponse.status).toBe(201);
  const location = createResponse.headers.get("location");
  await waitOnExecutionContext(ctx);

  const outboxPageResponse = await fetchWorker(new Request("https://owner.example/users/site/outbox?page=1"));
  const outboxPage = await outboxPageResponse.json() as {
    orderedItems?: Array<{ object?: { url?: string; content?: string } }>;
  };
  const item = outboxPage.orderedItems?.find((i) => i.object?.content?.includes("UTM url wiring check"));
  expect(item?.object?.url).toBe(location);
});

test("websub queue consumer: no-ops (does not throw) when the hub is unprovisioned", async () => {
  const { WEBSUB_DB: _unusedDB, SITE_URL: _unusedSiteURL, ...envWithoutHub } = testEnv;
  const emptyBatch = { queue: "site-websub", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, envWithoutHub as WorkerEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("websub queue consumer: dispatches into @dwk/websub's consumer without throwing when provisioned", async () => {
  // An empty batch exercises the real provisioned path — env validated, websubOrigin resolved,
  // createWebSubQueueConsumer instantiated, consumer(batch, ...) invoked — without triggering any
  // verify/distribute/deliver job (there are none), so it's safe to run against the real
  // `@dwk/websub` consumer rather than a stub, unlike a populated batch (see vitest.config.ts's
  // comment on why site-websub isn't a registered queue consumer in this suite).
  const emptyBatch = { queue: "site-websub", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, testEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

// --- WebFinger discovery (V-4.4, #366) ------------------------------------------------------
// Composition of @dwk/webfinger's handler, which is RFC 7033-conformant on its own (query
// validation, CORS, JRD body, 400/404) — these tests cover only what this file supplies: the
// resource map resolving the canonical + alias `acct:` handles to the ActivityPub actor (#1239),
// and the 503-when-unconfigured guard every other composed handler in this file follows.

test("webfinger: resolves the canonical acct:<hostname>@<host> handle by default", async () => {
  const response = await fetchWorker(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:owner.example@owner.example"),
  );
  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toContain("application/jrd+json");
  expect(response.headers.get("access-control-allow-origin")).toBe("*");
  const jrd = await response.json() as { subject: string; links: Array<{ rel: string; type?: string; href?: string }> };
  expect(jrd.subject).toBe("acct:owner.example@owner.example");
  expect(jrd.links).toContainEqual({
    rel: "self",
    type: "application/activity+json",
    href: "https://owner.example/users/site",
  });
});

test("webfinger: the legacy acct:site@<host> handle resolves as an alias to the canonical handle", async () => {
  const response = await fetchWorker(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:site@owner.example"),
  );
  expect(response.status).toBe(200);
  const jrd = await response.json() as { subject: string; links: Array<{ rel: string; type?: string; href?: string }> };
  // The alias's JRD subject is the canonical handle, not the alias itself.
  expect(jrd.subject).toBe("acct:owner.example@owner.example");
  expect(jrd.links).toContainEqual({
    rel: "self",
    type: "application/activity+json",
    href: "https://owner.example/users/site",
  });
});

test("webfinger: with AP_USERNAME set, the override is canonical and both the hostname default and acct:site alias resolve", async () => {
  const envWithOverride = { ...testEnv, AP_USERNAME: "alice" } as WorkerEnv;
  const canonical = await worker.fetch(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:alice@owner.example"),
    envWithOverride,
    createExecutionContext(),
  );
  expect(canonical.status).toBe(200);
  expect((await canonical.json() as { subject: string }).subject).toBe("acct:alice@owner.example");

  for (const alias of ["site", "owner.example"]) {
    const response = await worker.fetch(
      new Request(`https://owner.example/.well-known/webfinger?resource=acct:${alias}@owner.example`),
      envWithOverride,
      createExecutionContext(),
    );
    expect(response.status).toBe(200);
    expect((await response.json() as { subject: string }).subject).toBe("acct:alice@owner.example");
  }
});

test("webfinger: a mixed-case AP_USERNAME override still resolves at the conventional lowercase acct: query", async () => {
  // Regression guard: the resource map is a plain object keyed by the resolved (lowercased)
  // handle, so an un-normalized "Alice" override would only answer acct:Alice@... — undiscoverable
  // via the lowercase acct:alice@... form most Fediverse clients query.
  const response = await worker.fetch(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:alice@owner.example"),
    { ...testEnv, AP_USERNAME: "Alice" } as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(200);
  const jrd = await response.json() as { subject: string };
  expect(jrd.subject).toBe("acct:alice@owner.example");
});

test("webfinger: an AP_USERNAME override equal to the derived default produces no extra alias handle", async () => {
  // The default *is* the canonical handle here, so acct:owner.example just resolves normally —
  // no separate alias entry, but it must not error or produce a duplicate-key surprise either.
  const envWithRedundantOverride = { ...testEnv, AP_USERNAME: "owner.example" } as WorkerEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:owner.example@owner.example"),
    envWithRedundantOverride,
    createExecutionContext(),
  );
  expect(response.status).toBe(200);
  expect((await response.json() as { subject: string }).subject).toBe("acct:owner.example@owner.example");
});

test("webfinger: 503 when ActivityPub isn't configured", async () => {
  const { ACTOR: _unusedActor, ...envWithoutActor } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:site@owner.example"),
    envWithoutActor as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("webfinger: 400 when the resource query parameter is missing", async () => {
  const response = await fetchWorker(new Request("https://owner.example/.well-known/webfinger"));
  expect(response.status).toBe(400);
  expect(response.headers.get("access-control-allow-origin")).toBe("*");
});

test("webfinger: 404 for a resource this site does not control", async () => {
  const response = await fetchWorker(
    new Request("https://owner.example/.well-known/webfinger?resource=acct:someone-else@owner.example"),
  );
  expect(response.status).toBe(404);
  expect(response.headers.get("access-control-allow-origin")).toBe("*");
});

// --- Microsub reader (V-4.3, #365) ----------------------------------------------------------
// Composition of @dwk/microsub's single endpoint. These run through worker.fetch in the workerd
// pool with MICROSUB_DB/MICROSUB_QUEUE/AUTH_DB/TOKEN_SIGNING_KEY bound (see vitest.config.ts),
// exercising the same DPoP-authorized dispatch path production serves. Feed discovery/parsing
// and the poller/queue-consumer's own internals are the library's own concern (covered by its
// suite), not re-tested here — `discoverFeed` fails closed against the sandbox's blocked network,
// so `follow` still succeeds (it persists the subscription unconditionally) but never populates
// the timeline from a live fetch.

async function createMicrosubChannel(
  name: string,
  token: string,
  keyPair: CryptoKeyPair,
): Promise<string> {
  const url = "https://owner.example/microsub?action=channels";
  const response = await fetchWorker(new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: new URLSearchParams({ name }),
  }));
  const { uid } = await response.json() as { uid: string };
  return uid;
}

test("microsub: an unauthorized request (no Authorization header) is rejected", async () => {
  const response = await fetchWorker(new Request("https://owner.example/microsub?action=channels"));
  expect(response.status).toBe(401);
  // RFC 9728 §5.1 discovery signal (#1665): points an agent at the protected-resource metadata
  // document straight from the failed request.
  expect(response.headers.get("www-authenticate")).toBe(
    'DPoP resource_metadata="https://owner.example/.well-known/oauth-protected-resource"',
  );
});

test("microsub: a valid token creates a channel and follows a feed (200)", async () => {
  const { token, keyPair } = await mintAccessToken("follow channels");
  const uid = await createMicrosubChannel("Blogs", token, keyPair);

  const followURL = "https://owner.example/microsub?action=follow";
  const follow = await fetchWorker(new Request(followURL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(followURL, "POST", keyPair, token),
    },
    body: new URLSearchParams({ channel: uid, url: "https://feed.example/atom.xml" }),
  }));
  expect(follow.status).toBe(200);
  await expect(follow.json()).resolves.toMatchObject({ type: "feed", url: "https://feed.example/atom.xml" });
});

test("microsub: the timeline for a freshly created channel is empty with no paging cursor", async () => {
  const { token, keyPair } = await mintAccessToken("channels");
  const uid = await createMicrosubChannel("Timeline", token, keyPair);

  const timelineURL = `https://owner.example/microsub?action=timeline&channel=${uid}`;
  const timeline = await fetchWorker(new Request(timelineURL, {
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(timelineURL, "GET", keyPair, token),
    },
  }));
  expect(timeline.status).toBe(200);
  await expect(timeline.json()).resolves.toMatchObject({ items: [], paging: {} });
});

test("microsub: an unknown channel is rejected (404)", async () => {
  const { token, keyPair } = await mintAccessToken("channels");
  const timelineURL = "https://owner.example/microsub?action=timeline&channel=does-not-exist";
  const response = await fetchWorker(new Request(timelineURL, {
    headers: {
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(timelineURL, "GET", keyPair, token),
    },
  }));
  expect(response.status).toBe(404);
});

test("microsub: 503 when MICROSUB_DB isn't bound", async () => {
  const { MICROSUB_DB: _unusedDB, ...envWithoutDB } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/microsub?action=channels"),
    envWithoutDB as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("microsub: 503 when MICROSUB_QUEUE isn't bound", async () => {
  const { MICROSUB_QUEUE: _unusedQueue, ...envWithoutQueue } = testEnv;
  const response = await worker.fetch(
    new Request("https://owner.example/microsub?action=channels"),
    envWithoutQueue as WorkerEnv,
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("microsub queue consumer: no-ops (does not throw) when unprovisioned", async () => {
  const { MICROSUB_DB: _unusedDB, ...envWithoutMicrosub } = testEnv;
  const emptyBatch = { queue: "site-microsub", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, envWithoutMicrosub as WorkerEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("microsub queue consumer: dispatches into @dwk/microsub's consumer without throwing when provisioned", async () => {
  // An empty batch exercises the real provisioned path without triggering any poll-fetch job —
  // same rationale as the WebSub queue-consumer test above.
  const emptyBatch = { queue: "site-microsub", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, testEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("microsub scheduled poller: no-ops (does not throw) when unprovisioned", async () => {
  const { MICROSUB_DB: _unusedDB, ...envWithoutMicrosub } = testEnv;
  const controller = { cron: "*/15 * * * *", scheduledTime: Date.now() } as unknown as Parameters<
    NonNullable<typeof worker.scheduled>
  >[0];
  await expect(
    worker.scheduled!(controller, envWithoutMicrosub as WorkerEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("microsub scheduled poller: does not throw when provisioned (no followed feeds to poll)", async () => {
  const controller = { cron: "*/15 * * * *", scheduledTime: Date.now() } as unknown as Parameters<
    NonNullable<typeof worker.scheduled>
  >[0];
  await expect(
    worker.scheduled!(controller, testEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("queue dispatch: an unrecognized queue name is a no-op, not misrouted to the webmention consumer", async () => {
  // Locks in the fail-safe default from worker.ts's queue() dispatcher: matching is positive
  // ("-webmention" / "-websub") rather than "webmention = doesn't end in -websub", so a queue
  // name belonging to neither feature is dropped rather than silently handled as webmention.
  const emptyBatch = { queue: "site-some-future-feature", messages: [] } as unknown as Parameters<
    NonNullable<typeof worker.queue>
  >[0];
  await expect(
    worker.queue!(emptyBatch, testEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

// --- Solid Pod + WebDAV (V-storage) ---------------------------------------------------------
// @dwk/solid-pod's LDP resource storage (Durable Object + R2) and its WebDAV façade over the
// same pod. Neither POD/BLOBS/WEBDAV_PEPPER/GC_DB is bound in vitest.config.ts's miniflare
// fixture (no site here provisions solid-pod), so the explicit `{ ...testEnv, X: undefined }`
// overrides below just make the unbound-ness an explicit assertion rather than an accident of
// the fixture — matching handleSolidOidc's 503 test above.

test("handleSolidPod: 503s when POD/BLOBS are unbound", async () => {
  const request = new Request("https://example.com/pod/");
  const response = await handleSolidPod(request, { ...testEnv, POD: undefined, BLOBS: undefined }, createExecutionContext());
  expect(response.status).toBe(503);
});

test("handleWebdav: 503s when WEBDAV_PEPPER is unbound", async () => {
  const request = new Request("https://example.com/dav/");
  const response = await handleWebdav(request, { ...testEnv, WEBDAV_PEPPER: undefined }, createExecutionContext());
  expect(response.status).toBe(503);
});

test("handleWebdavCredentials: 503s when WEBDAV_PEPPER is unbound", async () => {
  const request = new Request("https://example.com/dav-credentials", { method: "GET" });
  const response = await handleWebdavCredentials(request, { ...testEnv, WEBDAV_PEPPER: undefined }, createExecutionContext());
  expect(response.status).toBe(503);
});

test("handleWebdav: 503s when POD/BLOBS are unbound even with WEBDAV_PEPPER set", async () => {
  const request = new Request("https://example.com/dav/");
  const response = await handleWebdav(
    request,
    { ...testEnv, POD: undefined, BLOBS: undefined, WEBDAV_PEPPER: "pepper" },
    createExecutionContext(),
  );
  expect(response.status).toBe(503);
});

test("solid-pod GC scheduled: no-ops (does not throw) when GC_DB/BLOBS are unbound", async () => {
  // @dwk/solid-pod's createSolidPodGc throws when GC_DB (or BLOBS) is missing — its
  // SolidPodGcEnv requires both, unlike this Worker's optional WorkerEnv.GC_DB/BLOBS.
  // WorkerComposition.swift doesn't provision a GC_DB binding yet, so the "*/5 * * * *" cron
  // tick must degrade gracefully rather than crash every site with solid-pod active.
  const controller = { cron: "*/5 * * * *", scheduledTime: Date.now() } as unknown as Parameters<
    NonNullable<typeof worker.scheduled>
  >[0];
  await expect(
    worker.scheduled!(controller, { ...testEnv, BLOBS: undefined, GC_DB: undefined }, createExecutionContext()),
  ).resolves.toBeUndefined();
});

test("scheduled dispatch: \"*/5 * * * *\" routes to solid-pod GC, \"*/15 * * * *\" still routes to Microsub's poller", async () => {
  // Locks in the scheduled() dispatch extension: it must branch on controller.cron rather than
  // always calling Microsub's poller (the pre-existing behavior every "*/15 * * * *" tick still
  // needs). Neither solid-pod nor Microsub is provisioned in this fixture, so both branches
  // no-op — this test exercises the branch selection itself, not either handler's inner logic.
  const gcController = { cron: "*/5 * * * *", scheduledTime: Date.now() } as unknown as Parameters<
    NonNullable<typeof worker.scheduled>
  >[0];
  const microsubController = { cron: "*/15 * * * *", scheduledTime: Date.now() } as unknown as Parameters<
    NonNullable<typeof worker.scheduled>
  >[0];
  await expect(
    worker.scheduled!(gcController, { ...testEnv, BLOBS: undefined, GC_DB: undefined }, createExecutionContext()),
  ).resolves.toBeUndefined();
  await expect(
    worker.scheduled!(microsubController, testEnv, createExecutionContext()),
  ).resolves.toBeUndefined();
});

// activityPubConfig: AP_ACTOR_TYPE/AP_MODERATORS wiring (V-5.1b, #907). A plain mock env/request
// is enough — activityPubConfig is a pure, synchronous mapping that never touches the ACTOR
// Durable Object, so no real binding is needed.
function makeActivityPubEnv(overrides: Partial<WorkerEnv> = {}): WorkerEnv {
  return {
    ACTOR: {} as WorkerEnv["ACTOR"],
    AP_PRIVATE_KEY: "private-key",
    AP_PUBLIC_KEY: "public-key",
    ...overrides,
  } as WorkerEnv;
}

test("activityPubConfig: returns null when ActivityPub isn't fully provisioned", () => {
  const request = new Request("https://example.com/");
  expect(activityPubConfig(request, makeActivityPubEnv({ ACTOR: undefined }))).toBeNull();
  expect(activityPubConfig(request, makeActivityPubEnv({ AP_PRIVATE_KEY: undefined }))).toBeNull();
  expect(activityPubConfig(request, makeActivityPubEnv({ AP_PUBLIC_KEY: undefined }))).toBeNull();
});

test("activityPubConfig: defaults to a Person actor with no moderators when AP_ACTOR_TYPE is unset", () => {
  const request = new Request("https://example.com/");
  const config = activityPubConfig(request, makeActivityPubEnv());
  expect(config?.actor.type).toBeUndefined();
  expect(config?.moderators).toBeUndefined();
});

test("activityPubConfig: AP_ACTOR_TYPE=Group sets actor.type to Group", () => {
  const request = new Request("https://example.com/");
  const config = activityPubConfig(request, makeActivityPubEnv({ AP_ACTOR_TYPE: "Group" }));
  expect(config?.actor.type).toBe("Group");
});

test("activityPubConfig: a non-Group AP_ACTOR_TYPE value is treated as Person", () => {
  const request = new Request("https://example.com/");
  const config = activityPubConfig(request, makeActivityPubEnv({ AP_ACTOR_TYPE: "Person" }));
  expect(config?.actor.type).toBeUndefined();
});

test("activityPubConfig: splits AP_MODERATORS on commas into the moderators list for a Group actor", () => {
  const request = new Request("https://example.com/");
  const config = activityPubConfig(
    request,
    makeActivityPubEnv({
      AP_ACTOR_TYPE: "Group",
      AP_MODERATORS: "https://mod1.example/actor,https://mod2.example/actor",
    }),
  );
  expect(config?.moderators).toEqual(["https://mod1.example/actor", "https://mod2.example/actor"]);
});

test("activityPubConfig: AP_MODERATORS is ignored (undefined) for a Person actor", () => {
  const request = new Request("https://example.com/");
  const config = activityPubConfig(
    request,
    makeActivityPubEnv({ AP_MODERATORS: "https://mod1.example/actor" }),
  );
  expect(config?.moderators).toBeUndefined();
});

// --- Worker read gate (#1568) ------------------------------------------------------------

async function sessionCookieFor(me: string): Promise<string> {
  const token = await createReaderSessionToken(normalizeReaderIdentity(me), testEnv.TOKEN_SIGNING_KEY);
  return `${READER_SESSION_COOKIE}=${token}`;
}

/** Minimal stub satisfying `Fetcher`, since the vitest miniflare env has no real ASSETS binding. */
function assetsAlways404(): WorkerEnv["ASSETS"] {
  return { fetch: async () => new Response("Not Found", { status: 404 }) } as unknown as WorkerEnv["ASSETS"];
}

test("contacts/signin: renders the sign-in form with no me", async () => {
  const response = await fetchWorker(new Request("https://owner.example/contacts/signin"));
  expect(response.status).toBe(200);
  expect(await response.text()).toContain('name="me"');
});

test("contacts/signin: discovers the endpoint and redirects with a signed state", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () =>
    new Response(
      '<html><head><link rel="authorization_endpoint" href="https://alice.example/auth"></head></html>',
      { headers: { "content-type": "text/html" } },
    )) as unknown as typeof fetch;
  try {
    const response = await fetchWorker(
      new Request("https://owner.example/contacts/signin?me=https://alice.example/"),
    );
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toContain("https://alice.example/auth");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("contacts/callback: verifies identity, checks the allowlist, and starts a session", async () => {
  const { createSigninState } = await import("./reader-session.ts");
  const state = await createSigninState(
    {
      me: "https://alice.example/",
      redirectTo: "/notes/hello",
      authorizationEndpoint: "https://alice.example/auth",
      verifier: "v",
    },
    testEnv.TOKEN_SIGNING_KEY,
  );
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ me: "https://alice.example/" }), {
      headers: { "content-type": "application/json" },
    })) as unknown as typeof fetch;
  try {
    await testEnv.SOCIAL_KV!.put("contacts:allowlist", JSON.stringify(["alice.example"]));
    const response = await fetchWorker(
      new Request(`https://owner.example/contacts/callback?code=abc&state=${encodeURIComponent(state)}`),
    );
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("/notes/hello");
    expect(response.headers.get("set-cookie")).toContain(READER_SESSION_COOKIE);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("contacts/feed: 403 without a session, 200 listing only contacts-visibility posts with one", async () => {
  const unauthorized = await fetchWorker(new Request("https://owner.example/contacts/feed"));
  expect(unauthorized.status).toBe(403);

  const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
  await store.insertPost({
    url: "https://owner.example/notes/gate-feed-restricted",
    type: "h-entry",
    properties: { name: ["Gate Feed Restricted"], visibility: ["contacts"] },
    now: 1_000,
  });
  const cookie = await sessionCookieFor("https://alice.example/");
  const authorized = await fetchWorker(
    new Request("https://owner.example/contacts/feed", { headers: { Cookie: cookie } }),
  );
  expect(authorized.status).toBe(200);
  expect(await authorized.text()).toContain("Gate Feed Restricted");
});

test("gated permalink fallback: unrelated 404s are untouched, plausible post URLs are gated", async () => {
  const assetsEnv = { ...testEnv, ASSETS: assetsAlways404() };

  // Not shaped like a post permalink — the gate never engages, plain 404 exactly as before #1568.
  const unrelated = await worker.fetch(
    new Request("https://owner.example/styles.css"),
    assetsEnv,
    createExecutionContext(),
  );
  expect(unrelated.status).toBe(404);

  // Plausible post URL, no session — uniform 403, not a leak-revealing 404.
  const noSession = await worker.fetch(
    new Request("https://owner.example/notes/some-slug"),
    assetsEnv,
    createExecutionContext(),
  );
  expect(noSession.status).toBe(403);

  // Authorized session, but no such post — falls back to the plain 404 (safe: only a verified,
  // allowlisted contact ever reaches this branch).
  const cookie = await sessionCookieFor("https://alice.example/");
  const authorizedNoPost = await worker.fetch(
    new Request("https://owner.example/notes/does-not-exist-either", { headers: { Cookie: cookie } }),
    assetsEnv,
    createExecutionContext(),
  );
  expect(authorizedNoPost.status).toBe(404);

  // Authorized session, real restricted post — renders it.
  const store = createMicropubStore({ MICROPUB_DB: testEnv.MICROPUB_DB! });
  await store.insertPost({
    url: "https://owner.example/notes/gate-permalink-restricted",
    type: "h-entry",
    properties: { name: ["Gate Permalink Restricted"], visibility: ["contacts"] },
    now: 1_000,
  });
  const rendered = await worker.fetch(
    new Request("https://owner.example/notes/gate-permalink-restricted", { headers: { Cookie: cookie } }),
    assetsEnv,
    createExecutionContext(),
  );
  expect(rendered.status).toBe(200);
  expect(await rendered.text()).toContain("Gate Permalink Restricted");
});

// --- MCP server endpoint (#1576) ----------------------------------------------------------

test("handleMcp: 404 when experimental.mcp is disabled", async () => {
  const handleMcp = createHandleMcp({ enabled: false, feedPaths: [] });
  const kv = makeFakeKV();
  const request = new Request("https://example.com/mcp", { method: "POST" });
  const response = await handleMcp(request, { ...testEnv, SOCIAL_KV: kv }, createExecutionContext());
  expect(response.status).toBe(404);
});

/** A JSON-RPC `tools/call` POST to `/mcp` — the only shape the rate limiter meters. `baseUrl`
 *  defaults to the read-only tools' fixture origin; owner-tool tests pass `https://owner.example`
 *  to match the origin `mintAccessToken`'s issued tokens are scoped to. */
function mcpToolCallRequest(
  name: string,
  args: Record<string, unknown> = {},
  extraHeaders: Record<string, string> = {},
  baseUrl = "https://example.com",
): Request {
  return new Request(`${baseUrl}/mcp`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...extraHeaders,
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
  });
}

test("handleMcp: 429 when the rate limit is exceeded", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const kv = makeFakeKV();
  const env = { ...testEnv, SOCIAL_KV: kv, ASSETS: makeFakeAssets({}) };
  const ip = "203.0.113.7";
  for (let i = 0; i < 60; i++) {
    const response = await handleMcp(
      mcpToolCallRequest("list_feeds", {}, { "CF-Connecting-IP": ip }),
      env,
      createExecutionContext(),
    );
    expect(response.status).not.toBe(429);
  }
  const limited = await handleMcp(
    mcpToolCallRequest("list_feeds", {}, { "CF-Connecting-IP": ip }),
    env,
    createExecutionContext(),
  );
  expect(limited.status).toBe(429);
});

test("handleMcp: non-tool-call traffic costs no KV write and is never rate-limited", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const kv = makeFakeKV();
  const env = { ...testEnv, SOCIAL_KV: kv, ASSETS: makeFakeAssets({}) };
  const ip = "203.0.113.8";

  // A bare GET (what worker.ts mirrors HEAD into) and a tools/list handshake, well past the
  // 60/window threshold — neither may increment the mcp-tool-call: counter.
  for (let i = 0; i < 70; i++) {
    await handleMcp(
      new Request("https://example.com/mcp", { method: "GET", headers: { "CF-Connecting-IP": ip } }),
      env,
      createExecutionContext(),
    );
    await handleMcp(
      new Request("https://example.com/mcp", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          "CF-Connecting-IP": ip,
        },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
      }),
      env,
      createExecutionContext(),
    );
  }
  expect([...kv.store.keys()].filter((k) => k.startsWith("mcp-tool-call:"))).toEqual([]);

  // …and a real tool call from the same IP still goes through, because nothing was counted.
  const toolCall = await handleMcp(
    mcpToolCallRequest("list_feeds", {}, { "CF-Connecting-IP": ip }),
    env,
    createExecutionContext(),
  );
  expect(toolCall.status).toBe(200);
});

test("isMcpToolCallRequest: only a JSON-RPC tools/call POST counts", async () => {
  expect(await isMcpToolCallRequest(mcpToolCallRequest("list_feeds"))).toBe(true);
  expect(await isMcpToolCallRequest(new Request("https://example.com/mcp", { method: "GET" }))).toBe(false);
  expect(
    await isMcpToolCallRequest(
      new Request("https://example.com/mcp", {
        method: "POST",
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
      }),
    ),
  ).toBe(false);
  expect(
    await isMcpToolCallRequest(new Request("https://example.com/mcp", { method: "POST", body: "not json" })),
  ).toBe(false);
  // A JSON-RPC batch counts when any member is a tools/call.
  expect(
    await isMcpToolCallRequest(
      new Request("https://example.com/mcp", {
        method: "POST",
        body: JSON.stringify([
          { jsonrpc: "2.0", id: 1, method: "tools/list" },
          { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_feeds" } },
        ]),
      }),
    ),
  ).toBe(true);
});

test("isMcpRateLimited: a failing KV write fails closed rather than throwing", async () => {
  const throwingKV = {
    async get() {
      return null;
    },
    async put() {
      throw new Error("KV PUT failed: 429 daily write quota exceeded");
    },
  } as unknown as WorkerEnv["SOCIAL_KV"];
  const limited = await isMcpRateLimited(
    new Request("https://example.com/mcp", { method: "POST" }),
    { ...testEnv, SOCIAL_KV: throwingKV },
  );
  expect(limited).toBe(true);
});

test("isMcpRateLimited: fails closed (rate-limited) when SOCIAL_KV is unbound", async () => {
  const request = new Request("https://example.com/mcp");
  const limited = await isMcpRateLimited(request, { ...testEnv, SOCIAL_KV: undefined });
  expect(limited).toBe(true);
});

test("mcpRateLimitKey: distinct IPs produce distinct keys with the mcp-tool-call: prefix", async () => {
  const a = await mcpRateLimitKey(new Request("https://example.com/mcp", { headers: { "CF-Connecting-IP": "1.1.1.1" } }));
  const b = await mcpRateLimitKey(new Request("https://example.com/mcp", { headers: { "CF-Connecting-IP": "2.2.2.2" } }));
  expect(a).not.toBe(b);
  expect(a.startsWith("mcp-tool-call:")).toBe(true);
});

/**
 * `@dwk/mcp`'s `createMcp` (#1578) answers every JSON-RPC POST with a plain `application/json`
 * body — no SSE framing, unlike phase 1's Cloudflare-`agents`-backed engine this replaced. Parses
 * both a success (`result`) and an error (`error`, e.g. `InsufficientScope`) response.
 */
function parseJsonRpcResult(body: string): {
  result?: { tools?: Array<{ name: string }>; content?: Array<{ type: string; text: string }> };
  error?: { code: number; message: string };
} {
  return JSON.parse(body);
}

/** Drives one `tools/call` all the way through the real dispatcher and returns the joined text of
 *  the tool's `content` blocks — the real integration path `tools/list` alone never exercises. */
async function callMcpTool(
  handleMcp: ReturnType<typeof createHandleMcp>,
  env: WorkerEnv,
  name: string,
  args: Record<string, unknown> = {},
): Promise<string> {
  const response = await handleMcp(mcpToolCallRequest(name, args), env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  return (body.result?.content ?? []).map((c) => c.text).join("\n");
}

test("handleMcp: enabled with a bound ASSETS responds to a tools/list JSON-RPC request", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml", "/atom.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const request = new Request("https://example.com/mcp", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  const names = (body.result?.tools ?? []).map((t) => t.name);
  expect(names).toEqual(expect.arrayContaining(["search_posts", "fetch_page_content", "list_feeds"]));
});

test("handleMcp: tools/list omits owner tools when Micropub isn't provisioned", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const { MICROPUB_DB: _unusedDB, MEDIA: _unusedMedia, ...envWithoutMicropub } = testEnv;
  const env = { ...envWithoutMicropub, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const request = new Request("https://example.com/mcp", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
  });
  const response = await handleMcp(request, env as WorkerEnv, createExecutionContext());
  const body = parseJsonRpcResult(await response.text());
  const names = (body.result?.tools ?? []).map((t) => t.name);
  expect(names).toEqual(["search_posts", "fetch_page_content", "list_feeds"]);
});

test("handleMcp: micropub_publish with no bearer token at all is rejected as insufficient scope", async () => {
  // No token means zero granted scopes (`optionalDpopAuthenticator`), not a 401 — matching
  // `ToolRegistry`'s "scope check, never a perimeter check" design: an anonymous call and a
  // present-but-wrong-scope call are indistinguishable from the registry's point of view, both
  // rejected the same way tools/call. Only a *present-but-invalid* token gets a real 401 (see
  // the replay test below).
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const request = mcpToolCallRequest(
    "micropub_publish",
    { type: "h-entry", properties: { content: ["hi"] } },
    {},
    "https://owner.example",
  );
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  expect(body.error?.message).toContain('requires the "create" scope');
});

test("handleMcp: micropub_publish rejects a token without the create scope", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const { token, keyPair } = await mintAccessToken("read");
  const url = "https://owner.example/mcp";
  const request = new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "micropub_publish", arguments: { type: "h-entry", properties: { content: ["hi"] } } },
    }),
  });
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  expect(body.error?.message).toContain('requires the "create" scope');
});

test("handleMcp: micropub_publish with a valid create-scoped token publishes a post", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/mcp";
  const request = new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "micropub_publish",
        arguments: { type: ["h-entry"], properties: { content: ["Published from an MCP client"] } },
      },
    }),
  });
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  expect(body.error).toBeUndefined();
  const text = (body.result?.content ?? []).map((c) => c.text).join("\n");
  expect(text).toContain("https://owner.example/notes/");
});

test("handleMcp: a replayed DPoP proof is rejected on a second /mcp call", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const { token, keyPair } = await mintAccessToken("create");
  const url = "https://owner.example/mcp";
  const proof = await dpopProof(url, "POST", keyPair, token);
  const makeRequest = () =>
    new Request(url, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `DPoP ${token}`, DPoP: proof },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
    });
  const first = await handleMcp(makeRequest(), env, createExecutionContext());
  expect(first.status).toBe(200);
  const second = await handleMcp(makeRequest(), env, createExecutionContext());
  expect(second.status).toBe(401);
});

test("handleMcp: micropub_media_upload with a valid media-scoped token stores the file", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: [] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const { token, keyPair } = await mintAccessToken("media");
  const url = "https://owner.example/mcp";
  const contentBase64 = btoa("not really a jpeg, just test bytes");
  const request = new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `DPoP ${token}`,
      DPoP: await dpopProof(url, "POST", keyPair, token),
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "micropub_media_upload", arguments: { contentBase64, contentType: "image/jpeg" } },
    }),
  });
  const response = await handleMcp(request, env, createExecutionContext());
  expect(response.status).toBe(200);
  const body = parseJsonRpcResult(await response.text());
  expect(body.error).toBeUndefined();
});

test("tools/call fetch_page_content: serves the .md mirror when one exists", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = {
    ...testEnv,
    SOCIAL_KV: makeFakeKV(),
    ASSETS: makeFakeAssets({
      "/blog/welcome-to-your-blog.md": { status: 200, body: "---\ntitle: \"Welcome\"\n---\n\nMirror body text." },
      // The HTML fallback must NOT win when the .md mirror is present.
      "/blog/welcome-to-your-blog": { status: 200, body: "<html><body><p>HTML fallback</p></body></html>" },
    }),
  };
  // Trailing slash normalization is part of the same path this exercises.
  const text = await callMcpTool(handleMcp, env, "fetch_page_content", { path: "/blog/welcome-to-your-blog/" });
  expect(text).toContain("Mirror body text.");
  expect(text).not.toContain("HTML fallback");
});

test("tools/call fetch_page_content: falls back to plain text from the built HTML page", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = {
    ...testEnv,
    SOCIAL_KV: makeFakeKV(),
    ASSETS: makeFakeAssets({ "/about": { status: 200, body: "<html><body><h1>About</h1><p>Hello there.</p></body></html>" } }),
  };
  const text = await callMcpTool(handleMcp, env, "fetch_page_content", { path: "/about" });
  expect(text).toContain("Hello there.");
  expect(text).not.toContain("<p>");
});

test("tools/call fetch_page_content: returns the Not found shape for an unknown path", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const text = await callMcpTool(handleMcp, env, "fetch_page_content", { path: "/nope" });
  expect(text).toBe("Not found: /nope");
});

test("tools/call search_posts: returns a blog hit from the built search index", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  // The exact shape src/pages/mcp-search-index.json.ts emits — a blog entry included, which is
  // what the endpoint's ENTRY_COLLECTIONS-only iteration used to make impossible (#1576 review).
  const index = [
    {
      title: "Welcome to your blog",
      url: "/blog/welcome-to-your-blog",
      excerpt: "This is your blog's first post.",
      collection: "blog",
      tags: [],
      date: "2026-01-01T00:00:00.000Z",
    },
  ];
  const env = {
    ...testEnv,
    SOCIAL_KV: makeFakeKV(),
    ASSETS: makeFakeAssets({ "/mcp-search-index.json": { status: 200, body: JSON.stringify(index) } }),
  };
  const text = await callMcpTool(handleMcp, env, "search_posts", { query: "welcome" });
  expect(text).toContain("Welcome to your blog");
  expect(text).toContain("/blog/welcome-to-your-blog");
});

test("tools/call search_posts: reports no results rather than throwing on an unparseable index", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  // A disabled build still ships a 0-byte mcp-search-index.json with a 200 status.
  const env = {
    ...testEnv,
    SOCIAL_KV: makeFakeKV(),
    ASSETS: makeFakeAssets({ "/mcp-search-index.json": { status: 200, body: "" } }),
  };
  const text = await callMcpTool(handleMcp, env, "search_posts", { query: "welcome" });
  expect(text).toBe('No results for "welcome".');
});

test("tools/call list_feeds: returns the build-time feed path list", async () => {
  const config: McpConfigArtifact = { enabled: true, feedPaths: ["/rss.xml", "/blog/rss.xml"] };
  const handleMcp = createHandleMcp(config);
  const env = { ...testEnv, SOCIAL_KV: makeFakeKV(), ASSETS: makeFakeAssets({}) };
  const text = await callMcpTool(handleMcp, env, "list_feeds");
  expect(text).toContain("/rss.xml");
  expect(text).toContain("/blog/rss.xml");
});
