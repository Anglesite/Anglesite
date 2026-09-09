# Anglesite v2 on Windows & Linux — Cross-Platform Swift Port Design

**Date:** 2026-07-08
**Status:** Approved design (desk analysis — no compilation spikes yet)
**Supersedes:** the "separate native apps, not ports" direction in `docs/specs/2026-06-26-personal-publishing-os-pivot-analysis.md` §5.8 — reconfirmed as a shared-code port by the owner on 2026-09-08 (`docs/specs/2026-09-08-product-direction-review-decisions.md` D2).
**Scope decisions (owner-approved):** platform-native AI by default with opt-in external LLMs via Settings; all-Swift per-platform UI bindings; native containers per platform; incremental seams in the existing package (no separate kit repo, no daemon restructuring).

## 1. Summary

Anglesite's business logic is already substantially portable: `AnglesiteSiteModel` (285 lines) is pure Foundation, and `AnglesiteCore` (~24k lines, 194 files) has only 25 files that import Apple-only frameworks, clustering into five seams. The architecture work done for the container epic (`SiteRuntime` protocol #65, HTTP/Streamable MCP transport #64, centralized `ProcessSupervisor`, `SiteFileWatching` protocol) is most of the porting groundwork. This design completes the dependency-injection story so the shared core compiles and tests on macOS, Linux, and Windows, and adds per-platform native app shells that follow each platform's conventions.

## 2. Goals & non-goals

**Goals**

- One SwiftPM package in this repo where `AnglesiteSiteModel`, `AnglesiteCore`, and a new webview-agnostic `AnglesiteBridgeCore` compile and pass `swift test` on macOS, Linux (Ubuntu CI), and Windows.
- Per-platform app shells following platform best practices: SwiftUI/AppKit (macOS, unchanged), GTK4/libadwaita via Adwaita for Swift (Linux), WinUI 3 via swift-winrt (Windows).
- Container-backed site runtimes on every platform (no host Node anywhere, preserving #70).
- Platform-native on-device AI as the **default** where the platform provides it; graceful, capability-flagged degradation where it doesn't.
- **External LLMs supported as an explicit opt-in in Settings** (never a silent default), so users on less capable machines can still use assistant features. Features that require a frontier-class model are **clearly labeled** as such in the UI (BBEdit-style feature badging), rather than silently failing on on-device models. *This consciously amends the #459 "no external LLM APIs, ever" rule; the roadmap doc and CLAUDE.md need a follow-up edit to match.*

**Non-goals**

- No Electron or web-tech app shell.
- No port of `AnglesiteIntents` (AppIntents is Apple-only). Windows/Linux platform affordances (jump lists, D-Bus actions) are future work, not a v1 requirement.
- No port of `AnglesiteContainer` (Apple Containerization is the macOS substrate; other platforms get their own `SiteRuntime` impls).
- No daemon/IPC restructuring of the macOS app; the mac app keeps its current in-process architecture.
- No relocation of the core into a separate package/repo. The compiler + CI matrix enforce purity; a repo boundary is not needed.

## 3. Current portability inventory

| Module | Size | Verdict |
|---|---|---|
| `AnglesiteSiteModel` | 2 files / 285 lines | Pure Foundation — ports as-is |
| `AnglesiteCore` | 194 files / ~24k lines | 25 files import Apple-only frameworks (see seams) |
| `AnglesiteBridge` | 3 files / 474 lines | WKWebView-specific; split portable message/overlay logic out |
| `AnglesiteApp` | 74 files / ~14k lines | SwiftUI/AppKit — per-platform by design |
| `AnglesiteIntents` | 31 files / ~3.4k lines | AppIntents — Apple-only, not ported |
| `AnglesiteContainer` | 3 files / ~1k lines | Apple Containerization — macOS substrate, not ported |
| `JS/edit-overlay` | TypeScript | Portable by construction (plain DOM/TS) |

Foundation, `Observation`, Swift Testing, `Process`, and `URLSession` (FoundationNetworking) all ship in the cross-platform Swift toolchain. The risk off-macOS is *behavioral* (Process semantics on Windows, path handling), not availability — mitigated by running the existing test suite on the new platforms from day one.

The `platforms: [.macOS("27.0")]` declaration in `Package.swift` constrains only Apple platforms; it does not impede Linux/Windows builds.

## 4. Target layout

```
Sources/
├── AnglesiteSiteModel/      unchanged
├── AnglesiteCore/           purified; Apple imports isolated under Platform/
│   └── Platform/            protocol seams + Darwin implementations
├── AnglesiteBridgeCore/     NEW: webview-agnostic overlay + message schema
├── AnglesiteBridge/         WKWebView adapter (Darwin-only target)
├── AnglesiteApp/            SwiftUI shell (macOS; owned by xcodeproj, unchanged)
├── AnglesiteLinux/          NEW: Adwaita shell + WebKitGTK adapter + PodmanSiteRuntime
└── AnglesiteWindows/        NEW: WinUI 3 shell + WebView2 adapter + WSL2SiteRuntime
```

`Package.swift` gains platform-conditional target inclusion using the same pattern as the existing `includeContainer` conditional: Darwin-only targets (`AnglesiteContainer`, `AnglesiteIntents`, `AnglesiteBridge`) are excluded off-Darwin; `AnglesiteLinux`/`AnglesiteWindows` only build on their platforms. Inside shared targets, `#if canImport(...)` / `#if os(...)` guards are allowed **only** under `AnglesiteCore/Platform/`; everywhere else the code stays condition-free. The Linux/Windows CI legs are the enforcement mechanism.

## 5. The five portability seams in AnglesiteCore

Each seam is a protocol with per-platform implementations, following the pattern already set by `SiteFileWatching` (protocol) / `FSEventsFileWatcher` (Darwin impl) and `SiteRuntime`.

| # | Seam | Darwin (today) | Linux | Windows |
|---|---|---|---|---|
| 1 | `SecretStore` | Keychain (`KeychainStore`, `SessionToken`) | libsecret / Secret Service (D-Bus) | Credential Manager (`CredRead`/`CredWrite`) |
| 2 | `SiteFileWatching` | `FSEventsFileWatcher` | inotify watcher | `ReadDirectoryChangesW` watcher |
| 3 | `AssistantBackend` | FoundationModels (`LanguageModelSession` + FM tools); external LLM opt-in | external LLM opt-in; else degrade | Phi Silica (`Microsoft.Windows.AI` via swift-winrt); external LLM opt-in |
| 4 | `EmbeddingProvider` | `NLEmbedding` / `NLContextualEmbedding` | deterministic lexical fallback | deterministic lexical fallback |
| 5 | Logging & misc | `os.log`/`OSLog`, `CryptoKit`, `UTType`, `CoreSpotlight`, `Darwin` | swift-log; swift-crypto; `#if`-out UTType/Spotlight | same as Linux |

Notes:

- **Near-mechanical swaps:** `swift-crypto` is Apple's API-compatible cross-platform CryptoKit subset (import alias, no call-site changes expected). `swift-log` with an os.log backend preserves current macOS behavior. These are the first PRs.
- **Compile-out, not port:** `CoreSpotlight` indexing, `SiriReadiness*`, and `UTType+Anglesite` guard out off-Darwin. `.anglesite` remains a plain directory on Windows/Linux (no package-UTI concept there); identity via `Info.plist` UUID works everywhere (`PropertyListDecoder` is cross-platform). Security-scoped bookmarks are MAS-sandbox-only and already conditional.
- **FM tools split cleanly:** per the #459 "tool before brain" rule, deterministic tool logic is already separate from the FM `Tool` conformance wrappers (`ApplyEditTool`, `SearchContentTool`, `SetupIntegrationTool`, …). The deterministic halves port for free; only the thin FM shims are Darwin-gated, and `AssistantBackend` twins them per platform.
- **Capability discovery is explicit:** a `PlatformCapabilities` value (`hasAssistant`, `hasEmbeddings`, `hasSpotlightIndexing`, …) provided by each platform module. Shells **hide** absent features rather than graying them out.

## 6. UI + preview per platform

### Platform UX quality bar

The shared core provides capability and business behavior; it does **not** prescribe a lowest-common-denominator interface. Each shell must implement the platform's interaction model and pass the applicable release checklist:

| Target | Required standard | Shell implication |
|---|---|---|
| macOS | [`mac-assed-app-spec.md`](../../mac-assed-app-spec.md) | Preserve standard menu, keyboard, document/window, Finder, VoiceOver, and AppKit/SwiftUI behavior. |
| Windows | [`windows-assed-app-spec.md`](../../windows-assed-app-spec.md) | Use Windows command, taskbar, File Explorer, accessibility, DPI/multi-monitor, and package-manager behavior. |
| Linux | [`linux-assed-app-spec.md`](../../linux-assed-app-spec.md) | Target Ubuntu GNOME intentionally while maintaining freedesktop.org interoperability, Wayland, portals, XDG paths, Orca access, and package-confinement correctness. |

A platform shell may adapt navigation, commands, windowing, file access, settings, notifications, and system integration to its platform. Shared models should expose capabilities and intent, not force a macOS-specific or generic-web presentation. Any deliberate departure from an applicable standard must be recorded in the feature design and shown to be clearer, accessible, reversible, and task-appropriate.

### Linux — GTK4/libadwaita via Adwaita for Swift

- [Adwaita for Swift](https://git.aparoksha.dev/aparoksha/adwaita-swift) (aparoksha, actively maintained as of March 2026) provides a SwiftUI-like declarative API over GTK4/libadwaita — the closest idiomatic target for translating view structure. `@Observable` core models are consumed through its state system.
- Preview embeds **WebKitGTK**; its `WebKitUserContentManager` script-message API maps 1:1 onto the WKScriptMessageHandler pattern the bridge uses today.
- Distribution: **Flatpak** (Flathub), which also pins the GTK/libadwaita/WebKitGTK runtime versions.
- Risk containment: the shell is deliberately thin; if Adwaita-swift stalls, replacement with direct GTK4 bindings touches only `AnglesiteLinux`.

### Windows — WinUI 3 via swift-winrt

- [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) (The Browser Company) is production-proven by Arc for Windows. Known wart: the Swift app builds as a DLL hosted by a small C++ bootstrap exe; the projection-generation step joins the build pipeline.
- Preview embeds **WebView2** through the same WinRT projection (`CoreWebView2.WebMessageReceived` / `PostWebMessageAsJson` ↔ script messages). No Swift-specific WebView2 support exists; none is needed — it is a WinRT/COM surface like the rest of WinUI.
- Distribution: **MSIX** via Microsoft Store and winget.
- Swift on Windows is officially supported with a dedicated Swift.org Windows workgroup (formed January 2026) covering Foundation/Dispatch Windows idioms.

### AnglesiteBridgeCore split

The edit-overlay TypeScript is already portable. The Swift-side message schema, serialization, and overlay-injection orchestration move from `AnglesiteBridge` into a new webview-agnostic `AnglesiteBridgeCore`; each platform contributes a thin adapter (WKWebView / WebKitGTK / WebView2) that injects the compiled overlay bundle and shuttles JSON messages. Existing `AnglesiteBridgeTests` move to the core target and run on all platforms.

## 7. Site runtime substrate

`SiteRuntime` (protocol) and the HTTP/Streamable MCP transport are reused unchanged — the payoff of #64/#65. The MCP server and toolchain run inside the container on every platform, so the plugin/server code needs no porting work beyond image architecture.

- **Linux — `PodmanSiteRuntime`:** drives rootless podman (CLI via `ProcessSupervisor`, or the podman REST socket) using the same OCI image. The vendored image is arm64-only today; the image pipeline adds **linux/amd64** (and keeps arm64). Port-mapping replaces the vsock proxies; preview and MCP arrive over localhost TCP exactly as the HTTP transport already expects.
- **Windows — `WSL2SiteRuntime`:** podman (or containerd) inside WSL2, reached via WSL2's localhost forwarding. WSL2 enablement is real install friction: the runtime detects absence and presents a guided setup flow. Escape hatch: the iOS `RemoteSandboxSiteRuntime` (Cloudflare sandbox) is platform-agnostic and can serve Windows users who cannot enable WSL2 — a product decision deferred to the Windows MVP phase.
- **`ProcessSupervisor` Windows audit:** Foundation `Process` exists on Windows but differs behaviorally — no POSIX signals (`TerminateProcess` vs SIGTERM/SIGKILL escalation), argument quoting, path separators, process groups/job objects for cleanup. The audit lands as tests in the CI matrix before any Windows runtime work builds on it. Log streaming (stdout/stderr → debug pane) must be preserved on all platforms — logs are sacred.

## 8. AI strategy — platform-native by default, external LLMs opt-in

`AssistantBackend` abstracts session lifecycle, prompt/system-instruction handling, structured (guided) generation, and tool invocation. The **default backend on every platform is the platform-native on-device model**; an **external LLM backend is available on every platform as an explicit opt-in in Settings**.

- **Darwin (default):** wraps FoundationModels exactly as today (on-device, escalating to Private Cloud Compute).
- **Windows (default):** wraps [Phi Silica](https://learn.microsoft.com/en-us/windows/ai/apis/phi-silica) (`Microsoft.Windows.AI`, Windows App SDK), reached through swift-winrt. Structurally similar (sessions, prompts, structured responses). Two first-class caveats:
  1. Phi Silica is a **Limited Access Feature** — shipping requires a Microsoft unlock token (request early; it gates the whole phase).
  2. Hardware coverage is Copilot+ NPUs plus recent NVIDIA GPUs (RTX 30+, 6 GB+) — many Windows machines qualify for neither; those users either run with `hasAssistant == false` or opt into an external LLM.
- **Linux (default):** no platform AI — assistant-less by default, deterministic tools only, assistant UI hidden via `PlatformCapabilities`. Opting into an external LLM in Settings lights up the full assistant feature set. Local open models (llama.cpp/ONNX) remain a future *native* option behind the same protocol.
- **`ExternalLLMBackend` (all platforms, opt-in):** a URLSession-based `AssistantBackend` speaking a standard chat-completions-style protocol against a user-configured endpoint + key (which also covers self-hosted local servers such as Ollama/llama.cpp — "external to the app" need not mean "off the machine"). API keys live in the `SecretStore` seam (§5), so the credential story is uniform across Keychain / libsecret / Credential Manager. Notably this backend is the *cheapest* of the three to build — plain HTTP, no platform bindings — and works identically everywhere, making it the fastest route to assistant parity on Linux.
- **Model-capability tiers, not just presence flags:** `PlatformCapabilities.hasAssistant` is joined by a model-tier signal (`onDevice` vs `frontier`). Features designed for frontier-class models are **clearly labeled in the UI** (BBEdit-style badging of gated features) and appear disabled-with-explanation rather than hidden, so users understand what opting into an external model unlocks. On-device-designed features run on whichever backend is active.
- **Embeddings:** no NLEmbedding analog off-Darwin. `EmbeddingProvider` gets a deterministic lexical fallback (BM25-style) so knowledge search degrades in quality, not availability. An external-endpoint embedding provider can piggyback on the same Settings opt-in later; revisit if Windows App SDK ships embedding APIs.

## 9. Build, CI, distribution

- **CI matrix:** add `ubuntu-latest` and `windows-latest` legs running `swift build && swift test` for the portable targets (`AnglesiteSiteModel`, `AnglesiteCore`, `AnglesiteBridgeCore`). The compiler is the purity lint — no separate import-checking tooling.
- macOS app build (xcodeproj/XcodeGen) is untouched. Linux/Windows apps are SwiftPM-driven (`swift build` + platform packaging: `flatpak-builder`, MSIX packaging via the WinUI pipeline).
- The existing gated e2e patterns (`.enabled(if:)` traits, env-gated targets) extend naturally: podman-requiring tests gate on a `ANGLESITE_PODMAN_TESTS` env var, mirroring `ANGLESITE_CONTAINER_TESTS`.

## 10. Phasing (Linux first)

Linux goes first: the Swift toolchain is most mature there, containers are native (no VM/WSL2 layer), and CI can exercise everything.

1. **Purity phase.** Add the Linux CI leg; land the five seams as small, individually-reviewable PRs (swift-crypto and swift-log first; then SecretStore, file watcher, assistant/embedding seams; compile-out Spotlight/UTType/Siri probes). macOS behavior unchanged throughout — each PR is a refactor with the existing suite as the safety net.
2. **Linux MVP.** `AnglesiteBridgeCore` split → `PodmanSiteRuntime` → Adwaita shell with WebKitGTK preview. Exit criterion: open a `.anglesite` package, edit, live-preview, and deploy on Ubuntu.
3. **Windows toolchain spike.** swift-winrt build pipeline, WinUI hello-world hosting `AnglesiteCore`, `ProcessSupervisor` behavioral audit, Windows CI leg. Explicit go/no-go before committing to the Windows MVP.
4. **Windows MVP.** `WSL2SiteRuntime` → WinUI shell with WebView2 preview → MSIX packaging.
5. **AI backends.** `ExternalLLMBackend` first (plain HTTP + `SecretStore`, works on all platforms — can land alongside or even before the Linux MVP since it needs no platform bindings); then Phi Silica (blocked on LAF token — request during phase 3); evaluate a Linux local-model backend later.

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| swift-winrt/WinUI maturity (single-vendor projection, C++ bootstrap, codegen in build) | High | Phase-3 spike with explicit go/no-go before Windows MVP investment |
| WSL2 install friction on Windows | High | Guided setup flow; remote-sandbox runtime as escape hatch |
| Phi Silica LAF gating + narrow hardware coverage | Medium | Capability-flagged absence is the baseline; external-LLM opt-in covers less capable machines; request LAF token early |
| Adwaita-swift is a small-community project | Medium | Thin shell; replaceable with direct GTK4 bindings without touching Core |
| Foundation behavioral drift (Process on Windows, paths, plist/URL edge cases) | Medium | Full existing test suite runs on both new platforms from phase 1 |
| Multi-arch image pipeline (amd64 + arm64) | Low | buildx already in the image pipeline; add a platform to the build |

## 12. Open questions (deferred, non-blocking)

- Whether Windows v1 offers the remote-sandbox runtime as a first-class alternative to WSL2 or only as a fallback (product decision at Windows MVP).
- External-LLM wire protocol and provider surface: one OpenAI-compatible chat-completions endpoint config (covers Ollama/vLLM/most providers) vs. per-provider adapters (e.g. native Anthropic Messages API). Decide at the `ExternalLLMBackend` slice.
- Which assistant features get the `frontier` tier label at launch, and the exact UI treatment for gated features (disabled-with-explanation vs. upsell-style badge).
- Whether the amended LLM policy (platform-native default, Settings opt-in, labeled frontier features) also applies to the macOS app *before* the cross-platform work lands — i.e. does the macOS app grow the external-LLM Settings opt-in ahead of the port. (The #459 roadmap doc and CLAUDE.md were amended with the new policy on 2026-07-08.)
- Flatpak sandbox vs. rootless-podman-from-Flatpak interaction (may require `flatpak-spawn` or a host-side helper; investigate at Linux MVP).
- Jump lists / D-Bus application actions as `AnglesiteIntents` analogs (post-v1).

## References

- Swift on Windows: https://www.swift.org/install/windows/ (Windows workgroup, Jan 2026)
- swift-winrt: https://github.com/thebrowsercompany/swift-winrt
- WinUI-from-Swift walkthrough: https://www.infoworld.com/article/2335273/using-swift-with-winui-on-windows.html
- Adwaita for Swift: https://git.aparoksha.dev/aparoksha/adwaita-swift
- WebView2: https://learn.microsoft.com/en-us/microsoft-edge/webview2/
- Phi Silica / Windows AI APIs: https://learn.microsoft.com/en-us/windows/ai/apis/phi-silica
- Prior art in-repo: `SiteRuntime` (#65), HTTP MCP transport (#64), no-host-Node (#70), package model (#242), Claude Code removal roadmap (#459)
