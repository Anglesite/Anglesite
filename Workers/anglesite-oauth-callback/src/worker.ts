// OAuth callback Worker (#891): two static routes, no state, deployed to
// auth.anglesite.dwk.io. It exists so Cloudflare's OAuth client registration has an
// https redirect URI (the registration form doesn't accept custom URL schemes) that
// iOS can intercept via Apple Associated Domains before the navigation ever loads.

/// Apple App Site Association document. `webcredentials` is the service
/// `ASWebAuthenticationSession`'s `.https(host:path:)` callback matching requires;
/// each entry is `<Team ID>.<bundle ID>`: the iOS app (#891) and the macOS app (#1204,
/// #1767). Both must be signed with team M34HBJZNYA — a personal team can't hold the
/// Associated Domains capability, so ad-hoc/personal-team Debug builds never match here.
const APPLE_APP_SITE_ASSOCIATION = {
  webcredentials: {
    apps: ["M34HBJZNYA.io.dwk.anglesite.ios", "M34HBJZNYA.io.dwk.anglesite"],
  },
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
      path === "/.well-known/apple-app-site-association" || path === "/oauth-callback";
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
    return new Response(CALLBACK_FALLBACK_HTML, {
      headers: { "content-type": "text/html; charset=utf-8", ...SECURITY_HEADERS },
    });
  },
};
