# Apple Containerization under the App Sandbox (MAS) — sub-spike notes

> **Status:** desk research + empirical run of the 3-config matrix on macOS 27.0 / Apple Silicon (build 26A5353q), 2026-06-09. **The empirical results are stronger than the prediction.** Harness: `Spikes/ContainerSpike/` (#60; deleted once its findings landed here — see #1802).
>
> ### Empirical findings (2026-06-09)
>
> Four data points, three of which the desk research didn't anticipate:
>
> 1. **Unsigned (no sandbox, no entitlements).** `VZVirtualMachineConfiguration.validate()` returns `VZErrorDomain: Invalid virtual machine configuration. The process doesn't have the "com.apple.security.virtualization" entitlement.` → **The Virtualization entitlement is the gate, not the sandbox.** Even DevID needs an Apple-issued provisioning profile granting `com.apple.security.virtualization` to ship `LocalContainerSiteRuntime`. Wall 2 is *more* load-bearing than the desk research initially framed.
> 2. **Config A — ad-hoc signed with hardened runtime + `.virtualization` + `.vm.networking`.** Process **SIGKILL'd at launch** (`amfid` rejected; empty stdout/stderr, exit 137). `main()` never ran. → **Restricted entitlements are unfakeable.** `codesign --sign -` writes them into the binary but the system refuses to honor them without a real cert chain + provisioning profile. The hardened runtime flag (`--options runtime`) is the trigger.
> 3. **Config B — ad-hoc signed with sandbox + `.virtualization`.** Process **SIGTRAP'd at launch** (exit 133, empty output). Same root cause as A via a different code path.
> 4. **Config C — ad-hoc signed with sandbox only, no restricted entitlements.** Process **hangs indefinitely at `sandboxd` container init.** A raw Mach-O CLI binary lacks a stable bundle id, so sandboxd can't compute `~/Library/Containers/<id>/` and waits forever. → **An app-sandbox process needs a real `.app` bundle**; you can't probe MAS-like behavior with a bare CLI.
>
> **Net conclusion is stronger than the original prediction:** *no* MAS-like configuration of Apple Containerization is empirically testable on this hardware without going through Apple's restricted-entitlement approval process first. That itself is the answer — the gating dependency on Apple Developer Relations is fully confirmed, and #60's fallback branch is unambiguously the right call.

## TL;DR

> ⚠️ **SUPERSEDED (2026-06-25) — Wall 3 is resolved; MAS-local IS viable.** The original prediction
> below (MAS can't ship the local path → MAS uses Cloudflare) assumed the local path needed a routable
> per-container IP via `vmnet`. It doesn't: **NAT (`VZNATNetworkDeviceAttachment`) + vsock + a host-side
> vsock→TCP proxy** reach guest ports with only `com.apple.security.virtualization` — no
> `com.apple.vm.networking`. A shipping sandboxed MAS app (`try-containers/Containers`) proves it. So
> `LocalContainerSiteRuntime` (#69) is viable on **MAS too** (Apple Silicon), gated only on the
> clearable `.virtualization` grant *(✅ since dissolved entirely — the entitlement is unrestricted,
> no grant exists; see the 2026-07-07 addendum)*. See the **"Wall 3 resolved"** addendum at the
> bottom. The walls/prediction below are retained for history.

**Prediction:** the MAS build of Anglesite will **not** be able to drive Apple Containerization locally. The DevID build can. Take the fallback branch in #60's "Output (decision)":

- `Anglesite` (DevID) → **`LocalContainerSiteRuntime`** (Apple Containerization).
- `AnglesiteMAS` (sandboxed) → **`RemoteSandboxSiteRuntime`** (Cloudflare), same code path as Intel / macOS < 26 / iOS.

Confidence: **high on "MAS can't ship local containers," moderate on the exact failure mode.** The binary spike below resolves the moderate-confidence pieces.

## Why MAS almost certainly can't ship the local path

Three independent walls, any one of which stops MAS. The third is the one without a workaround.

### Wall 1 — `container` CLI is structurally MAS-hostile

If we shipped the `apple/container` daemon model unchanged, it'd be a non-starter for MAS regardless of entitlements:

| Step | Where it lands | MAS-compatible? |
|---|---|---|
| `container` binary install | `/usr/local/bin/container` (admin password prompt) | ❌ no system-path writes from a sandboxed app |
| `container system start` | `launchctl bootstrap` of `com.apple.container.apiserver` etc. | ❌ no arbitrary launchd plist writes from a sandbox |
| XPC helpers | `container-core-images`, `container-network-vmnet`, `container-runtime-linux` | ❌ helpers expect to live outside the sandbox |
| Per-user data | `~/Library/Application Support/com.apple.container` | ⚠️ writeable only via the MAS app's own container, not a sibling |

This wall doesn't apply to the spike's actual question, because #60 proposes **embedding the `containerization` Swift package directly** (skipping the CLI daemon). But noted because anyone reading this later may otherwise reach for the CLI.

### Wall 2 — `com.apple.security.virtualization` is a restricted entitlement

The `containerization` package boots each container in a `Virtualization.framework` VM. That requires `com.apple.security.virtualization`. The entitlement *is* compatible with App Sandbox (Apple's own docs state "Sandbox is supported but not mandatory"), so the *technical* compatibility check passes. But:

- The entitlement is **restricted** — it must be authorized by a provisioning profile that Apple specifically issues.
- Historically granted case-by-case to virtualization-vendor apps. Not a blanket "tick a box in App Store Connect" capability.
- This is a possible-but-uncertain hurdle: surmountable, but slows down the MAS release timeline meaningfully if Apple takes weeks to respond.

This wall is **negotiable** with Apple. Wall 3 is not.

### Wall 3 — `com.apple.vm.networking` is the killer

> ✅ **RESOLVED (2026-06-25): not the killer after all.** NAT + vsock clear this without `vmnet` —
> see the "Wall 3 resolved" addendum at the bottom. The analysis below is retained for history.

The `container` daemon's networking model uses `vmnet` (`container-network-vmnet` XPC helper). The same will be true if we embed the Swift package directly and let it use its default networking — `vmnet` is what Apple's framework provides for container-on-VM networking with a routable IP.

`com.apple.vm.networking` is **explicitly restricted to developers of virtualization software** and requires a Developer Technical Support (DTS) incident with an Apple representative to grant. It is not on the standard App Store entitlement list. There is no documented path for a website-building app to qualify for it.

Without `vmnet`, the local-container path loses the "each container gets a dedicated IP → `http://<ip>:4321` direct" property that §0 of the design doc is built around. We'd have to invent a workaround — e.g. listen inside the guest on a host-shared socket via vsock and proxy through the host — that's no longer "use Apple Containerization as designed," and ends up roughly as much work as the Cloudflare path anyway.

**This is the load-bearing wall.** Even if Apple grants `com.apple.security.virtualization` for the MAS build, the lack of `com.apple.vm.networking` makes the local-container path architecturally unworkable.

## Precedent

| App | Uses Virtualization.framework? | Sandboxed? | Mac App Store? |
|---|---|---|---|
| ViableS (Howard Oakley) | Yes | Yes (for isolation) | **No** — author explicitly declined ("no benefit to users or to me, just more hassle") |
| UTM | Yes | Yes (DevID build) | Yes (UTM SE — but **emulation-only, no Hypervisor/Virtualization**) |
| VirtualBuddy, Tart, Lima | Yes | No | No |
| Parallels Desktop | Yes | Partial | Yes (App Store Edition with stripped feature set) |

The pattern: shipping a Virtualization-using app on MAS is **rare**, requires negotiation with Apple, and even when it works the App Store version is usually a stripped-down variant. Anglesite is not a virtualization vendor; the runway to make the case to Apple is much longer than the runway to ship via the Cloudflare path.

## Addendum — MAS precedent found (2026-06-20)

A shipping, **sandboxed Mac App Store** app drives Apple Containerization in-process: [`try-containers/Containers`](https://github.com/try-containers/Containers) ("Containers — Run LXCs", [App Store](https://apps.apple.com/app/containers-run-lxcs/id6759180330), requires macOS 26+). This is a direct counter-data-point to the Precedent table above, which had **no** Virtualization-using app on the MAS.

What its source shows:

- **In-process runtime, not the CLI/daemon.** `ContainerSystem/Services/SandboxedContainersService.swift` (header: *"runs LinuxContainer directly in-process, bypassing XPC and child process spawning entirely"*, dated 2026-02-04) imports the real `Containerization` / `ContainerizationOS` / `ContainerizationOCI` packages and calls `VZVirtualMachineManager(...)` directly. It depends on `github.com/apple/container` (per `project.pbxproj`) but **does not** ship the `container` daemon. This is exactly the "embed the Swift package directly" approach #60 proposed and #69 specs — so it sidesteps **Wall 1** entirely, confirming Wall 1 is avoidable.
- **`Containers.entitlements`** (sandboxed MAS build):
  - `com.apple.security.virtualization` → `true`
  - `com.apple.security.temporary-exception.files.absolute-path.read-write` → `/Users/`
  - `com.apple.security.temporary-exception.files.absolute-path.read-only` → `/etc/resolver/`
  - `com.apple.security.temporary-exception.apple-events` → `com.apple.systemevents`
  - **No `com.apple.vm.networking`.**

### What this revises

- **Wall 2 (`com.apple.security.virtualization`) is demonstrably clearable by an indie on MAS.** The spike rated this "negotiable / possible-but-uncertain." We now have a non-virtualization-vendor indie that got it granted for a sandboxed MAS app. Downgrade Wall 2 from "uncertain hurdle" to "clearable": it requires a provisioning-profile request to Apple (the same restricted-entitlement approval process `Containers` went through) — non-trivial but not a showstopper.
- **Wall 3 (`com.apple.vm.networking`) — still the load-bearing wall, but the precedent reframes it.** The Containers app ships **without** `vmnet`, which means it either (a) runs containers with reduced/host-proxied networking rather than routable per-container IPs, or (b) the in-process `LinuxContainer` path doesn't need `vmnet` for its networking model. **This is the open question to resolve before any MAS-local runtime for Anglesite** (see #69, `LocalContainerSiteRuntime` — where the investigation lands), because §0's design depends on the `http://<container-ip>:4321` routable-IP property. Study how `SandboxedContainersService` does networking without `vmnet` — that's the missing piece, not the entitlement.

### What does *not* change

- **Cloudflare-on-MAS remains the shipping decision.** It works today with zero Apple negotiation; the precedent only tells us a MAS-local path is *more feasible than the spike assumed*, not that it's free. Revisit local-on-MAS only if offline MAS editing becomes a priority (see the Appendix's option #1 trade-off).
- The temporary-exception entitlements (broad `/Users/` RW, `/etc/resolver/` read, AppleEvents to System Events) are App-Review-approved case by case — a real but surmountable review conversation.

## What the binary spike actually produced (2026-06-09 run)

The 3-config matrix was run on macOS 27.0 / Apple Silicon (build 26A5353q). The harness lived at `Spikes/ContainerSpike/` (removed after landing its findings here — see #1802) with each configuration recorded under `Entitlements/`. Results, in order of run:

| Config | Codesign | Outcome | Interpretation |
|---|---|---|---|
| (baseline, unsigned) | none | tier-1 returns `VZErrorDomain` naming the missing `.virtualization` entitlement | The framework's entitlement check is what fails first; not a sandbox check. |
| **A** — `.virtualization` + `.vm.networking`, hardened runtime | ad-hoc (`codesign --sign -`) | exit 137 (SIGKILL), no output | `amfid` refused the binary at launch — restricted entitlements aren't honored without a real cert chain + provisioning profile. |
| **B** — sandbox + `.virtualization` | ad-hoc | exit 133 (SIGTRAP), no output | Same root cause as A through a different code path. |
| **C** — sandbox only, no restricted entitlements | ad-hoc | hung indefinitely at `sandboxd` container init; killed after 20+ minutes | A raw Mach-O CLI binary has no `.app` bundle, so `sandboxd` can't compute the `~/Library/Containers/<bundle-id>/` path — it waits. |

### Why "all four configurations failed in different ways" is the right answer

It demonstrates, in four independent ways, that **you can't sneak around Apple's restricted-entitlement and bundle-structure enforcement**:

- `amfid` enforces restricted entitlements at process launch by inspecting the cert chain.
- The hardened runtime flag is the precise trigger for that check.
- `sandboxd` requires a real `.app` bundle to compute the sandbox container path.

So the original spike design — "ad-hoc-sign three configurations and observe error paths" — was structurally unable to ever reach the configurations it wanted to test. The implication is that the only way to empirically test the local-container path under DevID, let alone MAS, is to:

1. Apply to Apple for the `com.apple.security.virtualization` (and, for the local path's networking model to work, `com.apple.vm.networking`) entitlement.
2. Get an issued provisioning profile.
3. Sign a real `.app` bundle with the Developer ID identity + that profile.

Which is the *gating-on-Apple-Developer-Relations* outcome the spike was supposed to inform a decision about. **The empirical run confirms #60's fallback branch is the right call**, because there is no fast path through Apple — and even the "happy" outcome (DevID local path) takes negotiation with Apple before it can be implemented.

### Numbers we did not measure

- Cold-boot wall-clock for an `astro dev`-ready local container. Would feed §0 decision 5b's "warming…" UX threshold. Pending: real Developer ID identity + provisioning profile.
- Memory footprint per container. Same gating dependency.
- The exact error string Apple Containerization emits when `.vm.networking` is granted-but-restricted. Same dependency.

Recommended: defer these to whenever Anglesite has the Developer ID provisioning profile in hand. The current spike has produced enough to lock in the plan.

## Recommended decisions to record

1. **#60 outcome ← fallback branch.** Confirmed empirically. #59's plan can proceed under this assumption.
2. **`SiteRuntime` selection at app start.**
   - `AnglesiteMAS` → always `RemoteSandboxSiteRuntime` (Cloudflare).
   - `Anglesite` → prefer `LocalContainerSiteRuntime` when macOS ≥ 26 + Apple Silicon, fall back to `RemoteSandboxSiteRuntime` otherwise.
3. **`com.apple.security.virtualization` is a DevID-only ask.** Don't try to file a MAS DTS request — Cloudflare path on MAS is shippable today and avoids the dependency on an Apple negotiation.
4. **Reframe the embedded-Node retirement on MAS.** Phase 10.1's bundled-Node re-sign is still needed *for as long as MAS continues to spawn Node directly*. If the runtime swings to the Cloudflare path on MAS (which it must, given the above), Node retires on MAS the moment `RemoteSandboxSiteRuntime` is the only runtime there — earlier than the design doc's "Phase 5 also retires Node on local" framing.
5. **Heads-up for the §0 paired plugin work (#63).** The HTTP/SSE MCP transport becomes the *only* MCP transport on MAS (no local-stdio fallback), so its reliability bar is higher than if it were a "remote-only" path. Worth flagging in #63.

## Questions resolved by the empirical run

- **"Does `Virtualization.framework` fail loudly or silently when `.virtualization` is absent?"** — Loudly. `VZErrorDomain` with the entitlement named verbatim in the message. Easy to feature-detect against.
- **"Is there a networking model that sidesteps `com.apple.vm.networking`?"** — Not testable empirically without the entitlements unlocked, but mooted: per the desk research and the apple/container daemon's reliance on `container-network-vmnet`, the routable-per-container-IP property §0 of the design depends on requires `vmnet`. If a future Anglesite team gets the entitlements, this should be revisited.
- **"Cold-boot wall-clock for `astro dev`-ready container."** — Deferred. Requires a real Developer ID provisioning profile to test.

## Appendix — "Can MAS still run Node *some other way*?"

Question that came up after the empirical run: the spike confirmed MAS can't ship Apple Containerization, but doesn't say MAS can't ship *Node*. The #59 cloudflare-sandbox design treats "containerized" as universal-or-bust, but the original driver of that pivot was **iOS** (which truly can't run Node at all), with the iOS-MAS code-path sharing as a secondary benefit. So: what's actually available to MAS for Node?

### The option that's already in the codebase

**Phase 10.1's vendored Node in the sandbox.** It ships today and works:

- `Resources/node-runtime/` is re-signed by `scripts/resign-node.sh` with `Resources/node-runtime.entitlements` (inherit + `app-sandbox` + `cs.allow-jit` + `cs.allow-unsigned-executable-memory`).
- `AnglesiteMAS` holds a per-`SiteWindow` security-scoped bookmark grant; spawned Node inherits folder access to `~/Sites/<name>/`.
- `ProcessSupervisor` orchestrates spawn / restart / log capture for `node`, the bundled MCP server, `npm`, `wrangler`, `gh`.

This is a *working* MAS path. The current #59 trajectory retires it; the question is whether that retirement is necessary.

### Alternatives, ranked by realism

| # | Approach | Trade-off |
|---|---|---|
| 1 | **Keep Phase 10.1 on MAS, Cloudflare on iOS only.** Two runtime paths, each simpler than the unified Cloudflare-on-both. Preserves offline editing on MAS. The seam from §4 of the cloudflare-sandbox design (`SiteRuntime` protocol) already accommodates this. | Maintaining two runtimes forever. |
| 2 | **Embed Node as a library** (e.g., [NodeJS-mobile](https://github.com/JaneaSystems/nodejs-mobile)) instead of spawning. Same entitlement story (still needs JIT under MAS), but in-process — no `Process()`, no separate-binary re-sign, sandbox bookmarks just work. | Architectural cleanup, not a new capability. iOS App Store JIT rules still block the iOS use case, so iOS still needs Cloudflare. |
| 3 | **DevID-signed helper app launched from MAS.** Two-app distribution: MAS shell + DevID Node helper, IPC between them. | Apple's review team treats this as a sandbox-escape pattern; awkward dual-installer UX. Not recommended. |
| 4 | **WASM-hosted JS in JavaScriptCore in-process** (no Node). Build "Astro lite" using `esbuild-wasm`, `wasm-vips`, etc. | Massive scope — likely person-years for full Astro compatibility. Not v0-realistic. |
| 5 | **Cloudflare-on-MAS** (current #59 design). | Eliminates Node from MAS entirely; matches iOS code path. Adds Cloudflare account + Workers Paid plan ($5/mo) as a MAS dependency; loses offline editing. |

### The trade that's actually being made

| Cloudflare-on-MAS gives up | Cloudflare-on-MAS gains |
|---|---|
| Offline editing on MAS | One runtime path shared with iOS |
| Phase 10.1's already-shipped work (vendored Node, npm cache, re-sign, JIT entitlement) | Drops all of Phase 10.1's complexity from MAS |
| "No external dependency" property | Same `SiteRuntime` implementation as iOS |
| ~milliseconds-to-spawn local Node | Persistent Cloudflare account requirement on MAS |

The argument for staying on Cloudflare-on-MAS is **not** "MAS can't run Node" — that's the iOS argument. It's "we don't want to maintain two runtime paths forever." That's a real engineering-economics question, separate from the technical-possibility question the spike was answering.

### Recommendation (advisory, not decided)

Surface **option #1** as a deliberate choice in #59's plan-write rather than letting it disappear into the Cloudflare default. Specifically, the plan should answer:

- Do we want offline editing on MAS to survive? (If yes, #1 is on the table.)
- Is "Cloudflare account required" acceptable as a MAS purchase-time precondition? (If no, #1 is required.)
- Are we comfortable maintaining `LocalSiteRuntime` indefinitely for the MAS-and-DevID branch? (If no, retire it and accept the trade.)

Whichever way it goes, the question deserves an explicit answer in the plan, not an inherited default.

## Sources

- Apple Containerization Swift package — [apple/containerization](https://github.com/apple/containerization), [`Package.swift`](https://github.com/apple/containerization/blob/main/Package.swift), [`LinuxContainer.swift`](https://github.com/apple/containerization/blob/main/Sources/Containerization/LinuxContainer.swift)
- `container` CLI architecture — [apple/container](https://github.com/apple/container), [technical-overview.md](https://github.com/apple/container/blob/main/docs/technical-overview.md), [DeepWiki: Installation](https://deepwiki.com/apple/container/2.1-installation)
- Apple docs — [Virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization), [vm.networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking), [Adding the Virtualization Entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project)
- Apple Developer Forums — ["How to request com.apple.vm.\* entitlements"](https://developer.apple.com/forums/thread/656411) (restricted, DTS-only, "virtualization software developers")
- Anil Madhavapeddy, ["Under the hood with Apple's new Containerization framework"](https://anil.recoil.org/notes/apple-containerisation)
- Howard Oakley, ["Sandbox and isolate your VMs with a new version of ViableS"](https://eclecticlight.co/2023/08/30/sandbox-and-isolate-your-vms-with-a-new-version-of-viables/) (precedent: sandboxed Virtualization app, DevID, no MAS plans)

---

## Addendum — Wall 3 resolved: NAT + vsock clears the vmnet requirement (2026-06-25)

The 2026-06-20 addendum left **the** open question: the `try-containers/Containers`
MAS app drives Apple Containerization in-process and ships **without**
`com.apple.vm.networking`, so *how* does it network — and can Anglesite reach guest
ports without vmnet? Source review of both `try-containers/Containers` and
`apple/containerization` resolves it: **Wall 3 is clearable. `com.apple.vm.networking`
is not needed.**

### What the precedent actually does

- **Outbound (guest → internet):** `NATInterface` → `VZNATNetworkDeviceAttachment()`
  — Virtualization.framework's built-in NAT. Needs only `com.apple.security.virtualization`,
  **not** vmnet. (`apple/containerization` `Sources/Containerization/VZVirtualMachineInstance.swift`;
  used by `try-containers/Containers` `ContainerSystem/Services/SandboxedContainersService.swift`.)
  Note `NATInterface` (vmnet-free) is a *distinct* type from `NATNetworkInterface` / `VmnetNetwork`
  (the vmnet-backed types the `container` daemon uses) — the precedent uses the former.
- **Inbound (host → guest port):** **vsock** (`VZVirtioSocketDevice`), which needs only
  `.virtualization`. The load-bearing **public** API is `LinuxContainer.dialVsock(port:)`, which
  returns a `FileHandle` to a guest port; every VM gets a `VZVirtioSocketDeviceConfiguration`
  automatically. `apple/containerization` also contains `UnixSocketRelay` / `VsockListener` doing
  vsock↔socket splicing — useful **reference patterns**, but confirm their access level (public vs
  internal) during #69 before taking a direct dependency; the proxy can be written against the
  public `dialVsock` alone if they're not exported.

**Platform constraint:** `VZVirtioSocketDevice` + `VZNATNetworkDeviceAttachment` (Virtualization.framework)
mean `LocalContainerSiteRuntime` (#69) is **Apple Silicon only**. Intel Macs (and iOS) fall back to
`RemoteSandboxSiteRuntime` (Cloudflare), exactly as for macOS < 26.

### Why this dissolves Wall 3 for Anglesite

Wall 3 was "load-bearing" only because §0 of the design assumed the **routable
per-container IP** (`http://<container-ip>:4321`) that *bridged*/vmnet networking provides.
Anglesite doesn't need a routable IP — it needs a URL the `WKWebView` can load and an MCP
HTTP/WS endpoint. Both are delivered by a **host-side vsock→TCP proxy**:

1. Host listens on `127.0.0.1:<localPort>`; each accepted TCP conn → `container.dialVsock(port: 4321)`;
   splice bidirectionally. `WKWebView` loads `http://127.0.0.1:<localPort>`.
2. Same for the MCP server → guest vsock 4399; `MCPClient.connect(httpEndpoint:)`.
3. Guest side: a vsock-listen→TCP bridge per port in the OCI image, since Astro/Node speak TCP
   not vsock.

Implementation notes (not prescriptions): the host should **bind port 0** and use the
OS-assigned port (the `14321`/`14399` values used elsewhere in this addendum are illustration
only — fixed ports risk colliding with whatever the user is already running). For the guest
bridge, `socat vsock-listen:N,fork TCP:127.0.0.1:N` is fine for a **PoC**, but ship a small
compiled vsock→TCP helper instead — `socat` is a heavy dependency for a minimal image and has
rough edges under `fork` (signal handling, max-children).

This is exactly the "vsock + host proxy" workaround the original Wall 3 analysis dismissed as
"roughly as much work as the Cloudflare path" — but the shipping MAS precedent shows it is
viable and modest (~5–8 dev-days for a PoC: host `VsockTCPProxy` ~1–2d following the library's
relay pattern; guest bridge ~0.5d; `LocalContainerSiteRuntime` integration ~2–3d; amd64→
**arm64** image for Apple Silicon ~1–2d).

### Entitlements for the MAS-local runtime (#69)

| Entitlement | Status |
|---|---|
| `com.apple.security.virtualization` | ~~**Restricted — request from Apple.**~~ ✅ **Unrestricted — nothing to request** (2026-07-07 addendum). Wall 2 dissolved; ad-hoc builds boot VMs. |
| `com.apple.security.network.client` / `.server` | Standard MAS — for the `127.0.0.1` proxy listen/connect. |
| `com.apple.security.temporary-exception.files.absolute-path.read-write` (`/Users/`) | Temporary exception (App-Review case-by-case), as in the precedent. |
| `com.apple.vm.networking` | **NOT needed.** This was Wall 3; the NAT+vsock architecture avoids it. |

### Net

The local-container path (#69 `LocalContainerSiteRuntime`) is **architecturally viable on MAS**,
contingent only on the (clearable, precedented) `com.apple.security.virtualization` grant. The
remaining engineering is the vsock→TCP proxy + guest bridge + the runtime integration — landed
under #69. Sources (with commit SHAs) and the full Q&A: see the Wall 3 research notes that fed
this addendum (`try-containers/Containers` `SandboxedContainersService.swift` /
`Containers.entitlements`; `apple/containerization` `VZVirtualMachineInstance.swift`,
`VirtualMachineInstance.swift`, `LinuxContainer.swift`, `UnixSocketRelay.swift`, `VsockListener.swift`).

---

## Addendum — Wall 2 dissolved: the entitlement is unrestricted (2026-07-07)

**Empirical result:** `scripts/run-container-probe.sh echo` with its **default ad-hoc identity**
(`codesign --sign -`, no Apple account, no provisioning profile) booted an Apple Containerization
VM and passed the vsock echo gate on this machine (`GATE: PASS`). Therefore
`com.apple.security.virtualization` is an ordinary, **unrestricted** entitlement — there is no
Apple approval to request and no provisioning-profile grant involved, for DevID *or* dev builds.

### What the 2026-06-09 matrix actually showed

The original run's failures were re-attributed:

- **Config A** (SIGKILL) carried `com.apple.vm.networking` — that *is* (was) the restricted one.
  `amfid`'s rejection was about `.vm.networking`, not `.virtualization`. (As of 2026, "VMNet" is a
  self-service capability in the developer portal, available to every membership tier — even the
  formerly DTS-only entitlement no longer needs a negotiation.)
- **Config B** (SIGTRAP) failed for the same reason as Config C: an app-sandboxed **raw CLI
  binary** with no `.app` bundle. Sandbox bootstrap, not entitlement enforcement.
- The "Wall 2 = restricted, needs Apple approval" conclusion — echoed later by #498's
  "entitlement not honored on ad-hoc builds" hypothesis — was a misreading. #498's real problems
  were unlogged boot (#499) and a stale-lockfile `npm ci` (#502, which itself observed "the VM
  booting fine" on an ad-hoc Debug build).

### Corroboration

- Virtualization is **not listed** on Apple's supported-capabilities (macOS) page — it is not a
  portal capability at all, so there is nothing to request or embed in a profile.
- `Code-Hex/vz`'s documented workflow is exactly `codesign --sign -` with this entitlement.
- `try-containers/Containers` ships it sandboxed on the Mac App Store (per the 2026-06-20
  addendum) — no "restricted-entitlement approval process" needs to be inferred from that.

### Net

The June 20 addendum's "Wall 2 is clearable via a provisioning-profile request" overstated the
cost: there is no request. Remaining MAS check: App Store Connect upload validation accepting the
entitlement with a standard profile — exercised by `scripts/release.sh --validate-only`.
