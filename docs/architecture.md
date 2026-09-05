# Anglesite — Desired Application Architecture

The end-state after the [Claude Code removal roadmap](superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md):
no `claude` binary, deterministic Swift + Apple Intelligence only, and all JavaScript
running **inside the per-site container** rather than as a host-spawned process.

This diagram shows the trust / execution boundaries — what runs on the Apple device, what
runs in Apple's Private Cloud Compute, what runs inside the site container, and where the
filesystem source of truth and the deploy target sit.

```mermaid
flowchart TB
    user(["Site owner (non-technical)"])

    subgraph device["Apple device — Anglesite.app (Swift host, sandboxed)"]
        direction TB
        subgraph frontdoors["Front-doors — one capability, many entry points"]
            gui["GUI controls / wizards<br/>(non-technical default)"]
            siri["Siri / Spotlight<br/>(App Intents)"]
            chat["Chat panel (optional)"]
        end
        fmbrain["FoundationModelAssistant<br/>FM brain · tool-calling orchestrator"]
        subgraph swift["Deterministic Swift"]
            b1["Bucket 1 hot-paths<br/>create_page/post · list_content · annotations"]
            b3["Bucket 3 wizards<br/>deploy · check · backup · integrations · themes"]
            gate["pre-deploy-check<br/>native security gate"]
        end
        mcpclient["MCPClient<br/>HTTP/WS transport"]
        webview["WKWebView<br/>live preview"]
    end

    subgraph ai["Apple Intelligence — on device"]
        ondevice["On-device Foundation Models<br/>~3B + vision<br/>ApplyEditTool · SearchContentTool · Spotlight"]
    end

    subgraph pcc["Private Cloud Compute — Apple cloud, no external APIs"]
        pccgen["Bucket 5 heavy generation<br/>copy-edit · design-interview · social · repurpose"]
    end

    subgraph container["Site container — per-site runtime<br/>(Apple Containerization on macOS · Cloudflare remote/iOS)"]
        direction TB
        mcpserver["Node MCP server"]
        subgraph js["All JS runs in-guest"]
            applyedit["apply_edit / undo_edit<br/>HTML/Astro patcher"]
            astro["Astro dev + build"]
            media["Sharp · Satori · Pagefind · Keystatic"]
        end
    end

    repo[("Site Source/<br/>git repo — source of truth")]
    cf["Cloudflare Workers<br/>deploy target"]

    user --> gui & siri & chat
    gui --> swift
    siri --> swift
    siri --> fmbrain
    chat --> fmbrain
    fmbrain -->|on-device tier| ondevice
    fmbrain -->|escalate: PCC tier| pccgen
    fmbrain -->|tool calls| swift
    fmbrain -->|tool calls| mcpclient
    b1 --> repo
    b3 --> gate
    mcpclient -->|"MCP HTTP/WS (#64)"| mcpserver
    mcpserver --> js
    applyedit --> repo
    astro --> repo
    repo -. mounted .-> container
    astro -->|dev server URL| webview
    gate -->|deploy| cf

    classDef appleTrust fill:#e3f2fd,stroke:#1565c0,color:#0d47a1;
    classDef containerBound fill:#fff3e0,stroke:#e65100,color:#e65100;
    classDef external fill:#fce4ec,stroke:#ad1457,color:#880e4f;
    classDef store fill:#f1f8e9,stroke:#558b2f,color:#33691e;
    class device,ai,pcc appleTrust;
    class container,js containerBound;
    class cf external;
    class repo store;
```

## Boundaries

| Boundary | What's inside | How it's crossed |
|---|---|---|
| **Apple device (host)** | The Swift app: front-doors (GUI / Siri / chat), the `FoundationModelAssistant` orchestrator, deterministic Swift (Bucket 1 hot-paths + Bucket 3 wizards), the native `pre-deploy-check` gate, `MCPClient`, and the `WKWebView` preview. | User input; in-process Apple Intelligence API; `MCPClient` to the container. |
| **Apple Intelligence (on-device)** | The ~3B on-device Foundation Models + vision, with the registered FM `Tool`s (`ApplyEditTool`, `SearchContentTool`, Spotlight). | Called in-process by the FM brain; never leaves the device. |
| **Private Cloud Compute** | Heavy generation that exceeds the on-device ceiling (Bucket 5: copy-edit, design-interview, social, repurpose). Apple-operated; **no external LLM APIs ever**. | The FM brain escalates to the PCC tier over Apple's attested, encrypted channel. |
| **Site container (per-site)** | **All JavaScript**: the Node MCP server and everything it drives in-guest — `apply_edit`/`undo_edit` (HTML/Astro patcher), the Astro dev server + build, Sharp, Satori, Pagefind, Keystatic. Apple Containerization is the macOS runtime direction; Cloudflare Sandbox is the remote/iOS runtime. | The host reaches it only over the in-container **MCP HTTP/WS transport** (#64) — not by host-spawning Node. |
| **Site `Source/` (git repo)** | The filesystem source of truth — the clonable, externally-editable unit. | Mounted into the container; written by the in-guest JS and by Swift Bucket-1 hot-paths; read by `WKWebView` via the dev server. |
| **Cloudflare (deploy target)** | The published site (Workers). | Deploy runs only after the native `pre-deploy-check` gate passes. |

## Notes

- **One capability, one implementation, many front-doors.** A GUI button, "Hey Siri…", and a
  chat request all call the same Swift function or in-container tool — never a second copy.
- **The security gate is unbypassable.** `pre-deploy-check` is native deterministic Swift,
  not an LLM hook, so it cannot be prompt-injected or talked out of running.
- **This is the current state, not a future one.** The container runtimes landed (#66/#69/#70):
  the diagram reflects how Anglesite runs today — all JavaScript executes in-guest via the
  per-site container's MCP HTTP/WS transport, and the host-spawned Node sidecar plus the
  embedded host Node + JIT re-sign apparatus are retired.
