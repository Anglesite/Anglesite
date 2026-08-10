# iOS Thin Client Readiness Audit

**Issues:** [#59](https://github.com/Anglesite/Anglesite/issues/59), [#71](https://github.com/Anglesite/Anglesite/issues/71)  
**Scope:** Phase 5 preflight for the remote-only iOS/iPadOS app target.

## Purpose

#71 is a new iOS thin client, not a conditional build of the existing macOS shell. The iOS app should
host SwiftUI plus `WKWebView` via `UIViewRepresentable`, drive `RemoteSandboxSiteRuntime`, and avoid
host subprocesses, local container runtime code, security-scoped package access, and AppKit-only
targets.

Run:

```sh
scripts/audit-ios-thin-client-readiness.sh
```

Expected today:

- The command exits 0 and reports **no tracked blockers** — the seams landed with the
  `AnglesiteMobile` target: `Package.swift` declares `.iOS`, `project.yml` has the iOS app
  target + `Resources/Info-iOS.plist`, the host subprocess backend (`InProcessBackend`) and
  `LocalContainerSiteRuntime` are `#if !os(iOS)`-gated out of iOS builds, and the
  AppKit-coupled Intents surface lives in its own macOS-gated file.

The SwiftPM `AnglesiteIOS` shell target depends on `AnglesiteSiteModel` and `AnglesiteCore` (post
Phase 8/#885, `AnglesiteCore` is iOS-portable, so the shell's models — `PostListModel`,
`MicropubSession`, `SitePickerModel`, etc. — use it directly for `RemoteSandboxSiteRuntime`,
`KeychainStore`, and the HTTP MCP client). The audit doesn't treat that dependency as unsafe; the
dedicated checks above it (FSEvents, security-scoped bookmarks, host subprocess backend, local
container runtime, AppKit imports) already verify `AnglesiteCore`/`AnglesiteBridge` compile clean
for iOS. The iOS *app* target (`AnglesiteMobile`, Xcode-only) is where `AnglesiteCore`,
`AnglesiteBridge`, and `AnglesiteIOS` compose; those products all build with
`--triple arm64-apple-ios27.0`.

## Readiness Gate

When adding the iOS target, run:

```sh
scripts/audit-ios-thin-client-readiness.sh --expect-ready
```

Expected once #71 is ready to compile:

- The command exits 0.
- It prints `No tracked iOS thin-client blockers remain.`
- The new iOS target links only the shared pieces it can actually use: `AnglesiteBridge` boundary
  code, the HTTP MCP client, `SandboxControlClient`, and `RemoteSandboxSiteRuntime`.

Fail if `--expect-ready` exits 0 while the target still links host runtime, local container,
FSEvents, AppKit-only, or security-scoped package code.

## Evidence To Record On #71

- Output of `scripts/audit-ios-thin-client-readiness.sh --expect-ready`.
- The new iOS scheme build command and result.
- Confirmation that preview uses `WKWebView` through `UIViewRepresentable`.
- Confirmation that runtime selection is remote-only and never reaches generic subprocess
  supervision or `LocalContainerSiteRuntime`.
- Confirmation that the Cloudflare Worker URL/API token path uses iOS Keychain storage.
