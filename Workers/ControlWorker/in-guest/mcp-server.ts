import { createMcpServer } from "./mcp-server-core.js";

const SESSION_TOKEN = process.env.SESSION_TOKEN ?? "";
const MCP_PORT = Number(process.env.MCP_PORT ?? "4399");
const UPSTREAM_PORT = Number(process.env.MCP_UPSTREAM_PORT ?? "4400");
const MCP_ENTRY =
  process.env.ANGLESITE_MCP_ENTRY ??
  "/opt/anglesite/mcp-sidecar/server/index.mjs";

if (!SESSION_TOKEN) {
  process.stderr.write(
    "mcp-server: SESSION_TOKEN not set — refusing to start\n",
  );
  process.exit(1);
}

// The baked sidecar entry starts itself (an import side effect keyed off these
// env vars — see anglesite-skills/server/index.mjs) on a loopback-only port, so
// only this process's Bearer-authenticated proxy below is reachable from
// outside the guest.
process.env.ANGLESITE_MCP_TRANSPORT = "http";
process.env.ANGLESITE_MCP_HOST = "127.0.0.1";
process.env.ANGLESITE_MCP_PORT = String(UPSTREAM_PORT);
await import(MCP_ENTRY);

createMcpServer({
  expectedToken: SESSION_TOKEN,
  upstreamPort: UPSTREAM_PORT,
}).listen(MCP_PORT, "0.0.0.0", () => {
  process.stdout.write(`mcp-server listening on :${MCP_PORT}\n`);
});
