import { describe, it, expect } from "vitest";
import worker from "../src/worker.js";

const ORIGIN = "https://auth.anglesite.dwk.io";

function get(path: string): Promise<Response> {
  return Promise.resolve(worker.fetch(new Request(`${ORIGIN}${path}`)));
}

describe("GET /.well-known/apple-app-site-association", () => {
  it("serves the webcredentials entries for the iOS and macOS apps", async () => {
    const response = await get("/.well-known/apple-app-site-association");
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      webcredentials: { apps: string[] };
    };
    expect(body.webcredentials.apps).toEqual([
      "M34HBJZNYA.io.dwk.anglesite.ios",
      "M34HBJZNYA.io.dwk.anglesite",
    ]);
  });

  it("declares an application/json content type", async () => {
    const response = await get("/.well-known/apple-app-site-association");
    expect(response.headers.get("content-type")).toBe("application/json");
  });
});

describe("GET /oauth-callback", () => {
  it("serves the fallback page telling the user to return to Anglesite", async () => {
    const response = await get("/oauth-callback");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/html");
    expect(await response.text()).toContain("return to Anglesite");
  });

  it("never reflects callback query parameters into the page", async () => {
    const code = "secret-authorization-code";
    const response = await get(`/oauth-callback?code=${code}&state=some-state`);
    expect(response.status).toBe(200);
    expect(await response.text()).not.toContain(code);
  });
});

describe("security headers", () => {
  for (const path of ["/.well-known/apple-app-site-association", "/oauth-callback"]) {
    it(`sets nosniff and a deny-all CSP on ${path}`, async () => {
      const response = await get(path);
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
      expect(response.headers.get("content-security-policy")).toBe("default-src 'none'");
    });
  }
});

describe("everything else", () => {
  it("returns 404 for unknown paths", async () => {
    const response = await get("/");
    expect(response.status).toBe(404);
  });

  it("returns 405 for non-GET methods on known routes", async () => {
    const response = await Promise.resolve(
      worker.fetch(new Request(`${ORIGIN}/oauth-callback`, { method: "POST" })),
    );
    expect(response.status).toBe(405);
  });
});
