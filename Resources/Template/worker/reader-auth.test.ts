import { describe, expect, it, vi } from "vitest";
import { handleReaderCallback, handleReaderSignin } from "./reader-auth.ts";
import { createSigninState } from "./reader-session.ts";

const SIGNING_KEY = "test-signing-key";

function kvWith(value: string | null) {
  return { get: async () => value };
}

describe("handleReaderSignin", () => {
  it("renders the sign-in form when no me is given", async () => {
    const request = new Request("https://site.example/contacts/signin?redirect=/notes/hello");
    const response = await handleReaderSignin(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain('name="me"');
    expect(body).toContain('value="/notes/hello"');
  });

  it("falls back to / for an unsafe redirect target", async () => {
    const request = new Request("https://site.example/contacts/signin?redirect=https://evil.example/");
    const response = await handleReaderSignin(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    const body = await response.text();
    expect(body).toContain('value="/"');
  });

  it("re-renders the form with an error for an invalid me", async () => {
    const request = new Request("https://site.example/contacts/signin?me=not-a-url");
    const response = await handleReaderSignin(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("doesn&#39;t look like a valid website address");
  });

  it("re-renders the form with an error when discovery finds nothing", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () => new Response("<html></html>", { headers: { "content-type": "text/html" } })) as unknown as typeof fetch;
    try {
      const request = new Request("https://site.example/contacts/signin?me=https://alice.example/");
      const response = await handleReaderSignin(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
      expect(await response.text()).toContain("Couldn&#39;t find a sign-in endpoint");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("discovers the endpoint and redirects with PKCE + state params", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () =>
      new Response('<html><head><link rel="authorization_endpoint" href="https://alice.example/auth"></head></html>', {
        headers: { "content-type": "text/html" },
      }),
    ) as unknown as typeof fetch;
    try {
      const request = new Request("https://site.example/contacts/signin?me=https://alice.example/&redirect=/notes/hello");
      const response = await handleReaderSignin(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
      expect(response.status).toBe(302);
      const location = new URL(response.headers.get("location")!);
      expect(location.origin + location.pathname).toBe("https://alice.example/auth");
      expect(location.searchParams.get("response_type")).toBe("code");
      expect(location.searchParams.get("client_id")).toBe("https://site.example/");
      expect(location.searchParams.get("redirect_uri")).toBe("https://site.example/contacts/callback");
      expect(location.searchParams.get("code_challenge_method")).toBe("S256");
      expect(location.searchParams.get("code_challenge")).toBeTruthy();
      expect(location.searchParams.get("state")).toBeTruthy();
      expect(location.searchParams.has("scope")).toBe(false);
    } finally {
      globalThis.fetch = original;
    }
  });
});

describe("handleReaderCallback", () => {
  it("returns an error page when the visited site reports an error", async () => {
    const request = new Request("https://site.example/contacts/callback?error=access_denied");
    const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    expect(response.status).toBe(400);
    expect(await response.text()).toContain("declined the request");
  });

  it("returns an error page when code or state is missing", async () => {
    const request = new Request("https://site.example/contacts/callback?state=abc");
    const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    expect(response.status).toBe(400);
  });

  it("returns an error page for an invalid/expired state token", async () => {
    const request = new Request("https://site.example/contacts/callback?code=abc&state=garbage");
    const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
    expect(await response.text()).toContain("expired");
  });

  it("returns an error page when the identity endpoint rejects the code", async () => {
    const state = await createSigninState(
      { me: "https://alice.example/", redirectTo: "/notes/hello", authorizationEndpoint: "https://alice.example/auth", verifier: "v" },
      SIGNING_KEY,
    );
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () => new Response("bad code", { status: 400 })) as unknown as typeof fetch;
    try {
      const request = new Request(`https://site.example/contacts/callback?code=abc&state=${encodeURIComponent(state)}`);
      const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
      expect(await response.text()).toContain("rejected the sign-in code");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("returns an error page when the returned me doesn't match what was claimed", async () => {
    const state = await createSigninState(
      { me: "https://alice.example/", redirectTo: "/notes/hello", authorizationEndpoint: "https://alice.example/auth", verifier: "v" },
      SIGNING_KEY,
    );
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ me: "https://mallory.example/" }), {
        headers: { "content-type": "application/json" },
      }),
    ) as unknown as typeof fetch;
    try {
      const request = new Request(`https://site.example/contacts/callback?code=abc&state=${encodeURIComponent(state)}`);
      const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY });
      expect(await response.text()).toContain("didn&#39;t match");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("returns an error page when the verified identity isn't on the allowlist", async () => {
    const state = await createSigninState(
      { me: "https://alice.example/", redirectTo: "/notes/hello", authorizationEndpoint: "https://alice.example/auth", verifier: "v" },
      SIGNING_KEY,
    );
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ me: "https://alice.example/" }), {
        headers: { "content-type": "application/json" },
      }),
    ) as unknown as typeof fetch;
    try {
      const request = new Request(`https://site.example/contacts/callback?code=abc&state=${encodeURIComponent(state)}`);
      const response = await handleReaderCallback(request, { TOKEN_SIGNING_KEY: SIGNING_KEY, SOCIAL_KV: kvWith(null) });
      expect(await response.text()).toContain("doesn&#39;t have you as a contact");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("sets a session cookie and redirects when the identity is verified and allowlisted", async () => {
    const state = await createSigninState(
      { me: "https://alice.example/", redirectTo: "/notes/hello", authorizationEndpoint: "https://alice.example/auth", verifier: "v" },
      SIGNING_KEY,
    );
    const original = globalThis.fetch;
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ me: "https://alice.example/" }), {
        headers: { "content-type": "application/json" },
      }),
    ) as unknown as typeof fetch;
    try {
      const request = new Request(`https://site.example/contacts/callback?code=abc&state=${encodeURIComponent(state)}`);
      const response = await handleReaderCallback(request, {
        TOKEN_SIGNING_KEY: SIGNING_KEY,
        SOCIAL_KV: kvWith(JSON.stringify(["alice.example"])),
      });
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe("/notes/hello");
      const cookie = response.headers.get("set-cookie") ?? "";
      expect(cookie).toContain("__Host-anglesite_reader=");
      expect(cookie).toContain("HttpOnly");
    } finally {
      globalThis.fetch = original;
    }
  });
});
