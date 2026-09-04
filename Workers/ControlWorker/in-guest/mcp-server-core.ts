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
 * transport. Mirrors auth-proxy.ts's request-proxying shape, but gates on a
 * Bearer token via mcpAuthMiddleware instead of a session cookie, since the
 * sidecar's own startHttpServer binds and listens itself with no hook for
 * injecting middleware in front of it.
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
    if (!mcpAuthUpgradeGuard(expectedToken, req, socket)) return;
    // Streamable HTTP has no long-lived Upgrade path (design doc:
    // docs/specs/2026-06-09-mcp-http-transport-design.md) and the upstream
    // sidecar's startHttpServer never listens for "upgrade" either, so there is
    // nothing to proxy an authorized request to — reject explicitly rather than
    // leaving the socket open with no response.
    socket.write("HTTP/1.1 501 Not Implemented\r\n\r\n");
    socket.destroy();
  });

  return server;
}
