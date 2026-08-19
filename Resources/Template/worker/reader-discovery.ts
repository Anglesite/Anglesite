/**
 * IndieAuth `authorization_endpoint` discovery for a visitor-supplied `me` URL (#1568).
 *
 * Mirrors `@dwk/webmention`'s `discoverEndpoint`/`html.ts` shape (fetch through the SSRF-safe
 * wrapper, check the `Link` header, fall back to scanning `<link>`/`<a>` elements) but that
 * package's `parseLinkHeader`/`scanElements`/`splitTokens`/`resolveUrl` helpers aren't part of its
 * public `exports` map, and its own `findWebmentionEndpoint` hardcodes the `webmention` rel — so
 * this is a small, focused reimplementation for the `authorization_endpoint` rel, the same call
 * `post-type-discovery.ts` already made for `@dwk/micropub`'s internal slug helpers. `safeFetch`
 * itself (the actual SSRF-sensitive part) is reused from `@dwk/safe-fetch`, not reimplemented.
 *
 * @see docs/superpowers/specs/2026-08-18-worker-read-gate-design.md §3
 */

import { decodeEntities } from "@dwk/mf2";
import { readBodyCapped, safeFetch, type FetchLike } from "@dwk/safe-fetch";

const AUTHORIZATION_ENDPOINT_REL = "authorization_endpoint";

/** A parsed `Link` header entry: its target URI and `rel` tokens. */
interface LinkHeaderEntry {
  readonly uri: string;
  readonly rels: readonly string[];
}

/** Split a whitespace-separated token list (e.g. a `rel` value) into tokens. */
function splitTokens(value: string | null): string[] {
  if (value === null) return [];
  return value.trim().split(/\s+/).filter((token) => token !== "");
}

/** Split a `Link` header on top-level commas, respecting `<…>` and quoted values. */
function splitLinks(value: string): string[] {
  const result: string[] = [];
  let depth = 0;
  let inQuotes = false;
  let current = "";
  for (let i = 0; i < value.length; i++) {
    const char = value[i] as string;
    if (char === "\"" && value[i - 1] !== "\\") {
      inQuotes = !inQuotes;
    } else if (!inQuotes && char === "<") {
      depth++;
    } else if (!inQuotes && char === ">") {
      depth--;
    }
    if (char === "," && depth === 0 && !inQuotes) {
      result.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  if (current.trim() !== "") result.push(current);
  return result;
}

/** Split a `Link` entry's parameter string on top-level semicolons, respecting quoted values. */
function splitParams(paramString: string): string[] {
  const result: string[] = [];
  let inQuotes = false;
  let current = "";
  for (let i = 0; i < paramString.length; i++) {
    const char = paramString[i] as string;
    if (char === "\"" && paramString[i - 1] !== "\\") inQuotes = !inQuotes;
    if (char === ";" && !inQuotes) {
      result.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  if (current.trim() !== "") result.push(current);
  return result;
}

/** Extract the `rel` parameter from a `Link` entry's parameter string. */
function extractRel(paramString: string): string | null {
  for (const param of splitParams(paramString)) {
    const match = /^\s*rel\s*=\s*("([^"]*)"|'([^']*)'|[^;\s]+)\s*$/i.exec(param);
    if (match !== null) return match[2] ?? match[3] ?? match[1] ?? null;
  }
  return null;
}

/** Parse an HTTP `Link` header into entries, e.g. `<https://a.example/auth>; rel="authorization_endpoint"`. */
function parseLinkHeader(value: string | null): LinkHeaderEntry[] {
  if (value === null || value.trim() === "") return [];
  const entries: LinkHeaderEntry[] = [];
  for (const part of splitLinks(value)) {
    const match = /^\s*<([^>]*)>(.*)$/.exec(part);
    if (match === null) continue;
    const uri = match[1] ?? "";
    const rels = splitTokens(extractRel(match[2] ?? ""));
    if (rels.length > 0) entries.push({ uri, rels });
  }
  return entries;
}

/** Whether a `Content-Type` value names an HTML document. */
function isHtmlContentType(contentType: string): boolean {
  const essence = contentType.split(";")[0]?.trim().toLowerCase() ?? "";
  return essence === "text/html" || essence === "application/xhtml+xml";
}

/** Resolve `uri` against `base`, returning a normalized absolute URL or `null`. */
function resolveUrl(uri: string, base: string): string | null {
  try {
    return new URL(uri, base).toString();
  } catch {
    return null;
  }
}

interface ScannedElement {
  readonly name: string;
  readonly attrs: Readonly<Record<string, string | null>>;
}

/** Scan `html` with the runtime's streaming `HTMLRewriter` for elements matching `selector`. */
async function scanElements(
  html: string,
  selector: string,
  attrNames: readonly string[],
): Promise<ScannedElement[]> {
  const elements: ScannedElement[] = [];
  const rewriter = new HTMLRewriter().on(selector, {
    element(el) {
      const attrs: Record<string, string | null> = {};
      for (const name of attrNames) {
        const value = el.getAttribute(name);
        attrs[name] = value === null ? null : decodeEntities(value);
      }
      elements.push({ name: el.tagName, attrs });
    },
  });
  await rewriter.transform(new Response(html)).text();
  return elements;
}

/** Find the declared `authorization_endpoint` in a fetched document's `Link` header + HTML. */
async function findAuthorizationEndpoint(
  linkHeader: string | null,
  html: string,
  documentUrl: string,
): Promise<string | null> {
  for (const entry of parseLinkHeader(linkHeader)) {
    if (entry.rels.includes(AUTHORIZATION_ENDPOINT_REL)) {
      return resolveUrl(entry.uri, documentUrl);
    }
  }
  if (html === "") return null;
  const elements = await scanElements(html, "base, link, a", ["rel", "href"]);
  let documentBase = documentUrl;
  for (const el of elements) {
    if (el.name === "base" && el.attrs.href) {
      documentBase = resolveUrl(el.attrs.href, documentUrl) ?? documentUrl;
      break;
    }
  }
  for (const el of elements) {
    if (el.name === "base") continue;
    if (!splitTokens(el.attrs.rel).includes(AUTHORIZATION_ENDPOINT_REL)) continue;
    const href = el.attrs.href;
    if (href === null || href === undefined) continue;
    return resolveUrl(href, documentBase);
  }
  return null;
}

/** Options for {@link discoverAuthorizationEndpoint}. */
export interface DiscoverOptions {
  /** `fetch` implementation to use; defaults to the global `fetch`. */
  readonly fetch?: FetchLike;
  /**
   * Local-dev opt-in passed through to `@dwk/safe-fetch`'s `allowedHosts`. Never enable in a
   * production composition.
   */
  readonly fetchAllowedHosts?: readonly string[];
}

/**
 * Fetch `me` (through the SSRF-safe wrapper — the host and every redirect hop are validated
 * against private/loopback/link-local ranges, redirects capped, the whole call bounded by a
 * timeout) and discover its declared `authorization_endpoint`. Returns the absolute endpoint URL,
 * or `null` when discovery finds none, the fetch fails, or it's blocked on SSRF grounds.
 */
export async function discoverAuthorizationEndpoint(
  me: string,
  options?: DiscoverOptions,
): Promise<string | null> {
  const doFetch: FetchLike = options?.fetch ?? ((input, init) => fetch(input, init));

  let response: Response;
  let base: string;
  try {
    const result = await safeFetch(
      doFetch,
      me,
      { method: "GET", headers: { accept: "text/html, */*" } },
      { allowedHosts: options?.fetchAllowedHosts },
    );
    response = result.response;
    base = result.url;
  } catch {
    return null;
  }

  const fromHeader = await findAuthorizationEndpoint(response.headers.get("link"), "", base);
  if (fromHeader !== null) return fromHeader;

  const contentType = response.headers.get("content-type") ?? "";
  if (!isHtmlContentType(contentType)) return null;

  const html = await readBodyCapped(response);
  if (html === null) return null;
  return findAuthorizationEndpoint(null, html, base);
}
