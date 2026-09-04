# Safari MCP transport spike: how a sandboxed `Anglesite.app` reaches a user-launched `safaridriver --mcp`

**Status:** current
**Date:** 2026-09-04
**Issue:** [#1887](https://github.com/Anglesite/Anglesite/issues/1887) (split from [#453](https://github.com/Anglesite/Anglesite/issues/453))

## Question

#453 proposes an optional Safari MCP client for Anglesite. The owner's decision (2026-09-04)
fixed the shape: `Anglesite.app` never spawns `safaridriver` itself — no temporary-exception
entitlement exists for launching arbitrary binaries outside the sandboxed bundle, and none is
being requested. The user launches Safari MCP themselves; the app only connects. But
`safaridriver --mcp` ships stdio-only, and a sandboxed app cannot attach to another process's
stdio. This spike asks: is there any transport a sandboxed `Anglesite.app` can use to reach a
user-launched `safaridriver --mcp` session at all?

## Finding: yes — an off-the-shelf, user-launched stdio→HTTP bridge over loopback TCP

No new entitlement, no Apple-provided MCP network transport, and no code in this repo are
needed to establish the connection itself. `Resources/Anglesite.entitlements` already grants
`com.apple.security.network.client` (outbound) for other features, and outbound loopback TCP
from a sandboxed app needs nothing more than that. The missing piece is entirely on the
*user's* side of the boundary: something has to turn `safaridriver --mcp`'s stdio JSON-RPC
into a socket the app can dial. That something does not need to be written for this — the
existing npm package **`mcp-proxy`** (`npx -y mcp-proxy --port <port> -- safaridriver --mcp`)
does exactly this today, unmodified, as a plain user-launched subprocess wrapping another
subprocess. Verified live below.

What *does* still need building (out of scope for this spike; see "Gap" below) is teaching
`AnglesiteCore`'s MCP client to speak the standard, sessionful MCP Streamable HTTP handshake —
today it only speaks a bespoke stateless dialect used for the app's own container sidecar.

## What was tried

### 1. Confirm `safaridriver --mcp` really is stdio-only

```
$ safaridriver --version
Included with Safari 27.0 (22625.1.29.11.26)
$ safaridriver --mcp --help
...
	--mcp                     Run as an MCP (Model Context Protocol) server using stdio
	                          transport. Reads JSON-RPC from stdin, writes to stdout.
```

No port/HTTP flag exists for `--mcp` (unlike plain WebDriver mode's `-p/--port`). Confirmed
live with a direct stdio round trip:

```
$ (cat init.json; sleep 3) | safaridriver --mcp
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"Safari","version":"1.0.0"}}}
```

`safaridriver --mcp` speaks the **2024-11-05** MCP revision (the original stdio/initialize
handshake), not the newer 2026-07-28 revision. Matters for the gap below.

### 2. Rule out an Apple-provided network transport

`man safaridriver` doesn't mention `--mcp` at all (stale man page); `--help` documents no port
or socket option for it. There is no XPC service or other macOS-27 IPC surface advertised for
this either. Apple ships exactly one transport for `safaridriver --mcp`: stdio. So the
"Apple-provided network transport" candidate from the issue is a no-go — nothing to connect to
without a bridge in between.

### 3. Confirm a generic stdio→HTTP bridge works against real `safaridriver --mcp`

Started an off-the-shelf bridge, `mcp-proxy` (`npm view mcp-proxy` → `6.7.12`), wrapping
`safaridriver --mcp` on loopback:

```
$ npx -y mcp-proxy --port 8931 --host 127.0.0.1 -- safaridriver --mcp
starting server on port 8931
```

Then drove it with `curl` exactly the way `AnglesiteCore/HTTPTransport.send(_:)` drives an
endpoint — POST, `Content-Type: application/json`, `Accept: application/json,
text/event-stream` — using the **standard sessionful** MCP Streamable HTTP handshake
(`initialize` with no `MCP-Protocol-Version` header, capture `Mcp-Session-Id` from the
response, replay it on every later request):

```
$ curl -s -D - -X POST http://127.0.0.1:8931/mcp -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05",...}}'
HTTP/1.1 200 OK
mcp-session-id: 022cad97-3190-4019-815e-0b688f63e638
content-type: text/event-stream; charset=utf-8

event: message
data: {"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Safari","version":"1.0.0"}},"jsonrpc":"2.0","id":1}

$ curl -s -X POST http://127.0.0.1:8931/mcp -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: 022cad97-..." \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
event: message
data: {"result":{"tools":[{"name":"browser_console_messages",...}, ... 17 tools total ...]},"jsonrpc":"2.0","id":2}
```

This is a full, unmodified round trip: real Safari MCP tool listings (17 tools, matching the
July 2026 validation in the `safari-mcp-import-backend` memory) served over loopback HTTP by a
process the user starts with one shell command — no Anglesite code involved on either end of
the bridge.

### 4. Rule out reusing `AnglesiteCore`'s own HTTP dialect against `mcp-proxy` as-is

`mcp-proxy` also advertises a `--modern` flag ("serve MCP protocol revision 2026-07-28"),
which looked at first like a direct match for `AnglesiteCore/HTTPTransport`'s own
`MCP-Protocol-Version: 2026-07-28` header. It isn't the same dialect:

```
$ curl ... -H "MCP-Protocol-Version: 2026-07-28" -d '{"method":"initialize",...}'
HTTP/1.1 400 Bad Request
{"error":{"message":"Bad Request: the request headers and body disagree: an initialize
request (legacy handshake) was sent with a modern MCP-Protocol-Version header"}}

$ curl ... -H "MCP-Protocol-Version: 2026-07-28" -d '{"method":"server/discover",...}'
HTTP/1.1 400 Bad Request
{"error":{"message":"Bad Request: No valid session ID provided"}}
```

`mcp-proxy --modern` still requires a session (from a legacy-style `initialize`) — it's the
*standard* spec's evolving Streamable HTTP transport, sessionful either way. `AnglesiteCore`'s
`HTTPTransport`/`MCPClient`, by contrast, implement a **bespoke stateless** variant built for
this app's own container sidecar: no `initialize`, no `Mcp-Session-Id` ever sent or stored, a
`server/discover` readiness probe instead (see `MCPClient.swift:105-109,313-316`). The two
share a version string but are not interoperable. This is the actual gap — see below.

## Why this clears the sandbox

The app only ever needs to be an **outbound TCP client to `127.0.0.1`**, exactly like any
other loopback HTTP call it already makes. `com.apple.security.network.client` — already
present in `Resources/Anglesite.entitlements` for unrelated features — covers this
completely. `com.apple.security.network.server` (also already present, for the container's
own loopback proxies) is not needed for this feature at all: the bridge process is the
server, the app is the client. No entitlement change, no App Sandbox exception, no Apple
review risk.

## Gap: what a follow-up implementation issue actually has to build

Not "a transport" — `AnglesiteCore/HTTPTransport` already is one, and it works over loopback
today for the container sidecar. What's missing is **protocol-mode support**: `HTTPTransport`
(or a sibling transport reusing its plumbing) needs to speak the standard sessionful MCP
Streamable HTTP handshake — send `initialize`, capture `Mcp-Session-Id`, replay it — as an
alternate mode alongside the existing stateless dialect. That handshake is what lets the app
talk to `mcp-proxy`-wrapped `safaridriver --mcp`, and, incidentally, to any other
standard-compliant MCP HTTP server a user might point the app at later (not just Safari MCP).
This is real Swift implementation work, correctly out of scope for this docs-only spike.

## Recommendation

**Positive finding.** Per #1887's acceptance criteria, #453's child issues 2 (detection +
settings affordance) and 3 (one verification pass) can now be filed against this transport:

- The user runs a one-line, user-launched bridge subprocess themselves (e.g.
  `npx -y mcp-proxy --port <port> -- safaridriver --mcp`, or the equivalent with
  `supergateway`) — Settings copy should give this exact command, matching the existing
  "user launches Safari MCP themselves" shape from #453's acceptance criteria.
- The app connects as a plain loopback HTTP client to `http://127.0.0.1:<port>/mcp`.
- Child issue 2 (or a prerequisite slice of it) needs to add sessionful
  (`initialize`/`Mcp-Session-Id`) support to `AnglesiteCore`'s MCP HTTP client path — the
  existing stateless-only `HTTPTransport` cannot talk to `mcp-proxy` (or any standards-compliant
  MCP HTTP server) as it stands today. Scope that as its own task within child issue 2 rather
  than assuming the existing transport already covers it.
- Detection (child issue 2) should probe for a *reachable bridge on the configured loopback
  port*, not for a `safaridriver` binary path or a spawned process — the app has no visibility
  into what the user has running beyond the socket.
