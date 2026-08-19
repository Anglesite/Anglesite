/**
 * `/contacts/signin` and `/contacts/callback` — the IndieAuth relying-party flow a visitor uses to
 * prove "I am https://alice.example/" to this site (#1568).
 *
 * Always requests the scope-less "profile exchange" (no access token, no DPoP): the code is
 * redeemed at the discovered `authorization_endpoint` itself, exactly the flow
 * `@dwk/indieauth`'s own `handleProfileExchange` implements reciprocally for this site's owner.
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §2, §9
 */

import { canonicalizeProfileUrl } from "@dwk/indieauth";
import { readBodyCapped, safeFetch } from "@dwk/safe-fetch";
import { escapeHTML } from "./render-utils.ts";
import { isAllowedReader, normalizeReaderIdentity } from "./reader-identity.ts";
import { discoverAuthorizationEndpoint } from "./reader-discovery.ts";
import {
  createPkcePair,
  createReaderSessionToken,
  createSigninState,
  readerSessionSetCookie,
  verifySigninState,
} from "./reader-session.ts";

/** Bindings this module needs. */
export interface ReaderAuthEnv {
  readonly TOKEN_SIGNING_KEY: string;
  readonly SOCIAL_KV?: { get(key: string): Promise<string | null> };
}

const CALLBACK_PATH = "/contacts/callback";

/** A site-relative path (starts with `/`, never `//` or a backslash) — an open-redirect guard. */
function safeRedirectPath(candidate: string | null): string {
  if (candidate && candidate.startsWith("/") && !candidate.startsWith("//") && !candidate.includes("\\")) {
    return candidate;
  }
  return "/";
}

function pageResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function signinForm(redirectTo: string, error?: string): Response {
  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Sign in</title></head><body><main>
<h1>Sign in with your site</h1>
${error ? `<p role="alert">${escapeHTML(error)}</p>` : ""}
<form method="get" action="/contacts/signin">
<input type="hidden" name="redirect" value="${escapeHTML(redirectTo)}">
<label>Your website <input name="me" type="url" placeholder="https://you.example/" required autofocus></label>
<button type="submit">Sign in</button>
</form></main></body></html>`;
  return pageResponse(body);
}

function errorPage(message: string): Response {
  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Sign-in problem</title></head><body><main>
<h1>Couldn't sign you in</h1>
<p>${escapeHTML(message)}</p>
<p><a href="/contacts/signin">Try again</a></p>
</main></body></html>`;
  return pageResponse(body, 400);
}

/**
 * `GET /contacts/signin`: with no `me`, renders the sign-in form. With `me`, discovers that
 * site's `authorization_endpoint` and redirects the browser there to start the OAuth dance.
 *
 * Deliberately does *not* pre-check the allowlist before discovering/redirecting: doing so would
 * make this endpoint an oracle for "is this URL one of the owner's private contacts" (the visitor
 * hasn't proven the identity they typed yet, so a differential response here would leak contact-
 * list membership to anyone willing to guess URLs). The allowlist check happens only after the
 * callback verifies the visitor really does own the URL they claimed.
 */
export async function handleReaderSignin(request: Request, env: ReaderAuthEnv): Promise<Response> {
  const url = new URL(request.url);
  const redirectTo = safeRedirectPath(url.searchParams.get("redirect"));
  const meParam = url.searchParams.get("me");
  if (!meParam) return signinForm(redirectTo);

  const me = canonicalizeProfileUrl(meParam);
  if (me === null) return signinForm(redirectTo, "That doesn't look like a valid website address.");

  const authorizationEndpoint = await discoverAuthorizationEndpoint(me);
  if (authorizationEndpoint === null) {
    return signinForm(redirectTo, "Couldn't find a sign-in endpoint for that site.");
  }

  const { verifier, challenge } = await createPkcePair();
  const state = await createSigninState(
    { me, redirectTo, authorizationEndpoint, verifier },
    env.TOKEN_SIGNING_KEY,
  );

  const authUrl = new URL(authorizationEndpoint);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set("client_id", `${url.origin}/`);
  authUrl.searchParams.set("redirect_uri", `${url.origin}${CALLBACK_PATH}`);
  authUrl.searchParams.set("state", state);
  authUrl.searchParams.set("code_challenge", challenge);
  authUrl.searchParams.set("code_challenge_method", "S256");
  return new Response(null, { status: 302, headers: { location: authUrl.toString() } });
}

interface ProfileExchangeResponse {
  readonly me?: unknown;
}

function isProfileExchangeResponse(value: unknown): value is ProfileExchangeResponse {
  return typeof value === "object" && value !== null;
}

/**
 * `GET /contacts/callback`: redeem the authorization code at the endpoint discovered for this
 * sign-in, confirm the returned identity matches what was claimed, check it against the pushed
 * allowlist, and — only then — start a reader session.
 */
export async function handleReaderCallback(request: Request, env: ReaderAuthEnv): Promise<Response> {
  const url = new URL(request.url);
  if (url.searchParams.get("error")) {
    return errorPage("The site you signed in with declined the request.");
  }

  const code = url.searchParams.get("code");
  const stateParam = url.searchParams.get("state");
  if (!code || !stateParam) return errorPage("Missing sign-in parameters.");

  const signin = await verifySigninState(stateParam, env.TOKEN_SIGNING_KEY);
  if (signin === null) return errorPage("This sign-in link has expired. Please try again.");

  let response: Response;
  try {
    const result = await safeFetch(
      (input, init) => fetch(input, init),
      signin.authorizationEndpoint,
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          client_id: `${url.origin}/`,
          redirect_uri: `${url.origin}${CALLBACK_PATH}`,
          code_verifier: signin.verifier,
        }).toString(),
      },
    );
    response = result.response;
  } catch {
    return errorPage("Couldn't reach your site to confirm your identity.");
  }
  if (!response.ok) return errorPage("Your site rejected the sign-in code.");

  const body = await readBodyCapped(response);
  if (body === null) return errorPage("Your site's response was too large to read.");
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return errorPage("Your site's response wasn't valid.");
  }
  if (!isProfileExchangeResponse(parsed) || typeof parsed.me !== "string") {
    return errorPage("Your site's response didn't confirm an identity.");
  }

  const verifiedMe = canonicalizeProfileUrl(parsed.me);
  if (verifiedMe === null || verifiedMe !== signin.me) {
    return errorPage("The confirmed identity didn't match the site you signed in with.");
  }

  if (!(await isAllowedReader(env, verifiedMe))) {
    return errorPage("You're signed in, but this site doesn't have you as a contact.");
  }

  const token = await createReaderSessionToken(normalizeReaderIdentity(verifiedMe), env.TOKEN_SIGNING_KEY);
  return new Response(null, {
    status: 302,
    headers: { location: signin.redirectTo, "set-cookie": readerSessionSetCookie(token) },
  });
}
