import { build } from "esbuild";

for (const entry of [
  "in-guest/auth-proxy.ts",
  "in-guest/mcp-auth.ts",
  "in-guest/mcp-server.ts",
]) {
  await build({
    entryPoints: [entry],
    bundle: true,
    platform: "node",
    target: "node22",
    format: "esm",
    outdir: "dist/guest",
  });
}
