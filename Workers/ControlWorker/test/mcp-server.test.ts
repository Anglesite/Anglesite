import { describe, it, expect, afterEach } from "vitest";
import http from "node:http";
import type net from "node:net";
import { createMcpServer } from "../in-guest/mcp-server-core.js";

const TOKEN = "a".repeat(64);

function listen(server: http.Server): Promise<number> {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve(typeof address === "object" && address ? address.port : 0);
    });
  });
}

function close(server: http.Server): Promise<void> {
  return new Promise((resolve) => server.close(() => resolve()));
}

/** Grabs an ephemeral port and frees it immediately, for an "unreachable upstream" fixture. */
async function unusedPort(): Promise<number> {
  const probe = http.createServer();
  const port = await listen(probe);
  await close(probe);
  return port;
}

describe("createMcpServer", () => {
  let upstream: http.Server | undefined;
  let proxy: http.Server | undefined;
  let proxyPort: number;

  afterEach(async () => {
    if (proxy) await close(proxy);
    if (upstream) await close(upstream);
    proxy = undefined;
    upstream = undefined;
  });

  async function setup(
    handler: http.RequestListener = (req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ path: req.url }));
    },
  ) {
    upstream = http.createServer(handler);
    const upstreamPort = await listen(upstream);
    proxy = createMcpServer({ expectedToken: TOKEN, upstreamPort });
    proxyPort = await listen(proxy);
  }

  it("proxies an authorized request to the upstream sidecar", async () => {
    await setup();
    const res = await fetch(`http://127.0.0.1:${proxyPort}/mcp`, {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ path: "/mcp" });
  });

  it("returns 401 for a missing token without reaching the upstream", async () => {
    let upstreamHit = false;
    await setup((_req, res) => {
      upstreamHit = true;
      res.writeHead(200).end();
    });
    const res = await fetch(`http://127.0.0.1:${proxyPort}/mcp`);
    expect(res.status).toBe(401);
    expect(upstreamHit).toBe(false);
  });

  it("returns 401 for a wrong token", async () => {
    await setup();
    const res = await fetch(`http://127.0.0.1:${proxyPort}/mcp`, {
      headers: { authorization: "Bearer wrong" },
    });
    expect(res.status).toBe(401);
  });

  it("returns 502 when the upstream is unreachable", async () => {
    const upstreamPort = await unusedPort();
    proxy = createMcpServer({ expectedToken: TOKEN, upstreamPort });
    proxyPort = await listen(proxy);
    const res = await fetch(`http://127.0.0.1:${proxyPort}/mcp`, {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(res.status).toBe(502);
  });

  describe("upgrade handling", () => {
    function makeSocket() {
      const state = { written: "", destroyed: false };
      const socket = {
        write: (data: string) => {
          state.written += data;
        },
        destroy: () => {
          state.destroyed = true;
        },
      } as unknown as net.Socket;
      return { socket, state };
    }

    it("delegates to mcpAuthUpgradeGuard: a valid token leaves the socket open", async () => {
      await setup();
      const { socket, state } = makeSocket();
      const req = {
        headers: { authorization: `Bearer ${TOKEN}` },
      } as http.IncomingMessage;
      proxy!.emit("upgrade", req, socket, Buffer.alloc(0));
      expect(state.destroyed).toBe(false);
      expect(state.written).toBe("");
    });

    it("delegates to mcpAuthUpgradeGuard: an invalid token destroys the socket with 401", async () => {
      await setup();
      const { socket, state } = makeSocket();
      const req = { headers: {} } as http.IncomingMessage;
      proxy!.emit("upgrade", req, socket, Buffer.alloc(0));
      expect(state.destroyed).toBe(true);
      expect(state.written).toContain("401");
    });
  });
});
