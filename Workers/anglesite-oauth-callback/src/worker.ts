// OAuth callback Worker (#891): static routes, no state, deployed to
// auth.anglesite.dwk.io. It exists so Cloudflare's OAuth client registration has an
// https redirect URI (the registration form doesn't accept custom URL schemes) that
// iOS can intercept via Apple Associated Domains before the navigation ever loads.
//
// It also hosts the atproto OAuth client-metadata document (#1889): atproto's
// `client_id` must be a URL that resolves to this document, per the owner's
// 2026-09-04 infra decision recorded on #1485 (see
// docs/superpowers/specs/2026-08-20-atproto-oauth-dpop-par-design.md).

/// Apple App Site Association document. `webcredentials` is the service
/// `ASWebAuthenticationSession`'s `.https(host:path:)` callback matching requires;
/// each entry is `<Team ID>.<bundle ID>`. The macOS app must be signed with the
/// `M34HBJZNYA` company team — Associated Domains isn't available to personal teams
/// (#1767) — so a personal-team Debug build can't complete this callback match.
const APPLE_APP_SITE_ASSOCIATION = {
  webcredentials: {
    apps: ["M34HBJZNYA.io.dwk.anglesite.ios", "M34HBJZNYA.io.dwk.anglesite"],
  },
};

const ORIGIN = "https://auth.anglesite.dwk.io";
const ATPROTO_CLIENT_METADATA_PATH = "/atproto/client-metadata.json";
const ATPROTO_CALLBACK_PATH = "/atproto-callback";

/// atproto OAuth client-metadata document. `client_id` must equal this document's own
/// URL, per the atproto OAuth profile's "native" client shape. Scope and
/// `dpop_bound_access_tokens` follow the design doc's client mechanics spec.
const ATPROTO_CLIENT_METADATA = {
  client_id: `${ORIGIN}${ATPROTO_CLIENT_METADATA_PATH}`,
  client_name: "Anglesite",
  client_uri: "https://anglesite.dwk.io",
  redirect_uris: [`${ORIGIN}${ATPROTO_CALLBACK_PATH}`],
  grant_types: ["authorization_code", "refresh_token"],
  response_types: ["code"],
  application_type: "native",
  token_endpoint_auth_method: "none",
  dpop_bound_access_tokens: true,
  scope: "atproto transition:generic",
};

// Fallback for when iOS doesn't intercept the redirect (e.g. the flow ran in a regular
// browser, or Associated Domains didn't apply). Deliberately static: the authorization
// `code` rides in on the query string, so nothing from the request may be reflected here.
const CALLBACK_FALLBACK_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Anglesite</title>
</head>
<body>
  <p>Sign-in complete. You can close this page and return to Anglesite.</p>
</body>
</html>
`;

// Defense-in-depth on an auth-adjacent surface: neither response reflects request data,
// but a deny-all CSP and nosniff cost nothing and cap the blast radius if that ever changes.
const SECURITY_HEADERS = {
  "content-security-policy": "default-src 'none'",
  "x-content-type-options": "nosniff",
};

export default {
  fetch(request: Request): Response {
    const path = new URL(request.url).pathname;
    const known =
      path === "/.well-known/apple-app-site-association" ||
      path === "/oauth-callback" ||
      path === ATPROTO_CLIENT_METADATA_PATH ||
      path === ATPROTO_CALLBACK_PATH;
    if (!known) {
      return new Response("Not Found", { status: 404 });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { allow: "GET, HEAD" },
      });
    }
    if (path === "/.well-known/apple-app-site-association") {
      // Apple requires this served as application/json, directly (no redirects).
      return new Response(JSON.stringify(APPLE_APP_SITE_ASSOCIATION), {
        headers: { "content-type": "application/json", ...SECURITY_HEADERS },
      });
    }
    if (path === ATPROTO_CLIENT_METADATA_PATH) {
      return new Response(JSON.stringify(ATPROTO_CLIENT_METADATA), {
        headers: { "content-type": "application/json", ...SECURITY_HEADERS },
      });
    }
    return new Response(CALLBACK_FALLBACK_HTML, {
      headers: { "content-type": "text/html; charset=utf-8", ...SECURITY_HEADERS },
    });
  },
};
