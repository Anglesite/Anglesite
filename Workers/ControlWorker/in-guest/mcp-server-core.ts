import http from "node:http";
import type net from "node:net";
import { mcpAuthMiddleware, mcpAuthUpgradeGuard } from "./mcp-auth.js";

export interface McpServerOptions {
  expectedToken: string;
  upstreamHost?: string;
  upstreamPort: number;
}

/**
 * Bearer-authenticated proxy fronting the baked MCP sidecar's loopback-only HTTP
 * transport. Mirrors auth-proxy.ts's request/upgrade proxying shape, but gates on
 * a Bearer token via mcpAuthMiddleware/mcpAuthUpgradeGuard instead of a session
 * cookie, since the sidecar's own startHttpServer binds and listens itself with
 * no hook for injecting middleware in front of it.
 */
export function createMcpServer({
  expectedToken,
  upstreamHost = "127.0.0.1",
  upstreamPort,
}: McpServerOptions): http.Server {
  const middleware = mcpAuthMiddleware(expectedToken);

  const server = http.createServer((req, res) => {
    middleware(req, res, () => {
      const proxy = http.request(
        {
          host: upstreamHost,
          port: upstreamPort,
          path: req.url,
          method: req.method,
          headers: req.headers,
        },
        (upstream) => {
          res.writeHead(upstream.statusCode!, upstream.headers);
          upstream.pipe(res);
        },
      );
      proxy.on("error", (err) => {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            error: "upstream unavailable",
            detail: (err as Error).message,
          }),
        );
      });
      req.pipe(proxy);
    });
  });

  server.on("upgrade", (req: http.IncomingMessage, socket: net.Socket) => {
    mcpAuthUpgradeGuard(expectedToken, req, socket);
  });

  return server;
}
