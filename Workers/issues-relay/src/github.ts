// Minimal GitHub App client for the relay: App JWT → installation token → Issues REST calls.
// The App is installed only on the catalog repo with Issues read/write (design §4).

export interface GitHubAppConfig {
  appId: string;
  installationId: string;
  /** PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`). */
  privateKeyPem: string;
  fetch?: typeof fetch;
  now?: () => number;
}

export interface GitHubIssue {
  number: number;
  state: "open" | "closed";
  labels: string[];
  html_url: string;
}

const API = "https://api.github.com";
const USER_AGENT = "anglesite-issues-relay";

export class GitHubClient {
  private token?: { value: string; expiresAt: number };
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;

  constructor(private readonly config: GitHubAppConfig) {
    this.fetchImpl = config.fetch ?? fetch.bind(globalThis);
    this.now = config.now ?? Date.now;
  }

  async createIssue(repo: string, issue: { title: string; body: string; labels: string[] }): Promise<GitHubIssue> {
    return toIssue(await this.request("POST", `/repos/${repo}/issues`, issue));
  }

  async getIssue(repo: string, number: number): Promise<GitHubIssue> {
    return toIssue(await this.request("GET", `/repos/${repo}/issues/${number}`));
  }

  async comment(repo: string, number: number, body: string): Promise<void> {
    await this.request("POST", `/repos/${repo}/issues/${number}/comments`, { body });
  }

  /** Finds an issue whose body carries `markerText` — recovery when the KV mapping is gone. */
  async findByMarker(repo: string, markerText: string): Promise<GitHubIssue | undefined> {
    const q = encodeURIComponent(`repo:${repo} is:issue in:body "${markerText}"`);
    const result = (await this.request("GET", `/search/issues?q=${q}&per_page=1`)) as { items?: unknown[] };
    return result.items?.[0] ? toIssue(result.items[0]) : undefined;
  }

  private async request(method: string, path: string, body?: unknown): Promise<unknown> {
    const response = await this.fetchImpl(`${API}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${await this.installationToken()}`,
        accept: "application/vnd.github+json",
        "user-agent": USER_AGENT,
        "x-github-api-version": "2022-11-28",
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`GitHub ${method} ${path} → ${response.status}`);
    return response.json();
  }

  private async installationToken(): Promise<string> {
    if (this.token && this.token.expiresAt - 60_000 > this.now()) return this.token.value;
    const response = await this.fetchImpl(`${API}/app/installations/${this.config.installationId}/access_tokens`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${await appJWT(this.config.appId, this.config.privateKeyPem, this.now())}`,
        accept: "application/vnd.github+json",
        "user-agent": USER_AGENT,
      },
    });
    if (!response.ok) throw new Error(`GitHub installation token → ${response.status}`);
    const { token, expires_at } = (await response.json()) as { token: string; expires_at: string };
    this.token = { value: token, expiresAt: Date.parse(expires_at) };
    return token;
  }
}

/** RS256 App JWT: backdated 60 s for clock skew, valid 9 minutes (GitHub's max is 10). */
export async function appJWT(appId: string, privateKeyPem: string, nowMs: number): Promise<string> {
  const now = Math.floor(nowMs / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: appId }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

function pemToDer(pem: string): ArrayBuffer {
  if (pem.includes("BEGIN RSA PRIVATE KEY")) {
    throw new Error("GITHUB_APP_PRIVATE_KEY is PKCS#1; convert it with `openssl pkcs8 -topk8 -nocrypt`");
  }
  const base64 = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  return bytes.buffer;
}

function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function toIssue(raw: unknown): GitHubIssue {
  const issue = raw as { number: number; state: "open" | "closed"; html_url: string; labels?: Array<string | { name: string }> };
  return {
    number: issue.number,
    state: issue.state,
    html_url: issue.html_url,
    labels: (issue.labels ?? []).map((l) => (typeof l === "string" ? l : l.name)),
  };
}
