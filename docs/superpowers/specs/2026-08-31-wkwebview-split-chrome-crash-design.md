# WKWebView panes vs. NavigationSplitView/.inspector() chrome — direction decision (#1699)

**Date:** 2026-08-31
**Issue:** #1699 (architecture discussion), spun out of #1696 (Component Editor repro)
**Status:** Approved direction; Stage 0 **failed** (2026-08-31): macOS 27 Beta 8
(26A5425a) still crashes — 5/5 runs of the #1696 repro, every crash report carrying
the identical `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` →
`_postWindowNeedsUpdateConstraints` fingerprint. Stages 1 and 2 are active.

Two side findings from the Stage 0 pass, tracked separately from this design:
Beta 7's saved toolbar customization (`"NSToolbar Configuration site"`, containing
SwiftUI-internal item identifiers) crashes the app at launch under Beta 8's
`AppKitToolbarStrategy.applyItemCustomizations`; and window restore runs
`DeployModel.hasUsableToken()`'s synchronous `SecItemCopyMatching` on the main
thread, wedging the whole app behind the keychain authorization prompt.

## Problem

A `WKWebView`-hosting `NSViewRepresentable` newly appearing inside a site window's
`NavigationSplitView`/`.inspector()` chrome (`SiteWindow.swift`) crashes the app on
macOS 27.0 beta (26A5421a). AppKit's runaway-layout guard fires
(`NSGenericException`: "more Update Constraints in Window passes than there are views
in the window") after `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`
loops — a min/max-size negotiation feedback between `NSHostingView` and the private
split controller that backs both `NavigationSplitView` and `.inspector()`.

The reliable repro is #1696: Graph view → select `Hcard.astro` → **Open File** →
crash within ~1s, before the Component Editor canvas finishes loading. This blocks
the #910 manual QA checklist and, by extension, Component Editor sign-off.

## What is established (from the #1696 diagnostic trail)

- App state is clean: `mainPaneMode`, `componentEditor`, and loading flags each
  transition exactly once before the crash. No app-level oscillation.
- Timing mitigations do not help: raising `AppKitConstraintStormMitigation.settleDelay`
  300ms → 1500ms had no effect. This is a *self-sustaining* negotiation loop, not the
  #1126-class *transaction-coalescing* race the existing mitigation addresses. Once the
  loop starts, no settle delay before it matters.
- The loop is in the window chrome, not the Component Editor: replacing the editor's
  inner `HSplitView` with a hand-rolled split still crashed with
  `SplitViewChildController` in the stack — those frames can only come from the outer
  `NavigationSplitView`/`.inspector()`.
- The pairing matters, not the split alone: three standalone `HSplitView` uses
  (`CommunitiesView`, `SiteGraphExplorerView`, `DesignInterviewPanel`) are crash-free.
- **Counter-example that scopes the bug:** `PreviewView` mounts a raw `WKWebView`
  *late* (when the dev server becomes ready) inside the same chrome, daily, crash-free.
  Both `PreviewView` and `ComponentCanvasView` return a raw `WKWebView` from
  `makeNSView`. The delta is the mount context: the Component Editor swap tears down
  `SiteGraphExplorerView` (itself `HSplitView`-backed), mounts an outline+canvas pane
  pair, and presents the Metadata/Style inspector in close succession. So "any
  WKWebView appearing anywhere in the chrome" (the issue's summary) is over-broad —
  the trigger is a WKWebView mount *concurrent with split/inspector reconfiguration*.
- External evidence points at an OS regression: developer.apple.com forum threads
  report the identical exception from SwiftUI `.inspector()` on this OS cycle's betas
  (thread 801818), and broken `NavigationSplitView` constraints on every beta of the
  cycle (thread 793895), with no Apple response. Same conclusion as our
  instrumentation: framework bug class, not app code.

## Decision

A staged ladder, cheapest-first. Stage 0 gates Stage 2, and Stage 2's failure gates
Stage 3; Stage 1 (Apple Feedback) is unconditional.

### Stage 0 — Re-verify on a newer OS build (human step; gates everything)

The dev machine is on the crashing build (26A5421a); **macOS 27 Beta 8 (26A5425a) is
available in Software Update**. The app targets macOS 27+, which has not shipped —
no end user will ever run Beta 7. Until the crash is confirmed to survive a newer
build, *no* architecture change is justified.

Procedure: install Beta 8, rebuild off `main`, run the #1696 repro 5×
(open site → Graph → `Hcard.astro` → Open File). Record pass/fail on #1699.

- **If fixed:** #1699 closes as an OS bug with a note to re-verify at GM; #910
  unblocks; existing `AppKitConstraintStormMitigation` call sites stay as-is (they
  address a different, still-real race). Stages 2–3 never run.
- **If still crashing:** proceed to Stages 1 and 2.

### Stage 1 — File Apple Feedback (do regardless of Stage 0's outcome)

The report is already assembled: exception string, first-throw stack with
`SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`, the
`AppKit:DisplayCycle` unified-log excerpt showing the constraint count climbing
385→401 past the guard limit, the local `.ips`
(`~/Library/Logs/DiagnosticReports/Anglesite-2026-08-31-151936.ips`), and a
minimal description: "WKWebView-hosting NSViewRepresentable mounted during
NavigationSplitView detail-column reconfiguration with .inspector() present."
The loop lives entirely in AppKit/SwiftUI-private code, so Feedback is the only
path to a real fix. Reference the two forum threads as corroboration.

### Stage 2 — Layout firewall around WKWebView-hosting panes (only if Stage 0 still crashes)

**Hypothesis:** the negotiation loop feeds on sizing metrics that change while the
webview mounts. A container view that gives the hosting machinery *nothing to
renegotiate* starves the loop.

**Component:** one new type in `Sources/AnglesiteApp/` (proposed name
`WebViewLayoutFirewall`): an `NSView` subclass that

- hosts the `WKWebView` as a subview sized by `autoresizingMask = [.width, .height]`
  with `translatesAutoresizingMaskIntoConstraints = true` — frame-based, no Auto
  Layout constraints between container and webview;
- reports `intrinsicContentSize == NSSize(width: NSView.noIntrinsicMetric,
  height: NSView.noIntrinsicMetric)` and never calls
  `invalidateIntrinsicContentSize()`/`setNeedsUpdateConstraints()` on the webview's
  behalf, so the representable presents constant sizing metrics to `NSHostingView`
  regardless of what the webview does internally.

**Interface:** `init(webView:)`; the wrapped webview stays reachable (property) so
existing coordinator/`updateNSView` logic keeps operating on the `WKWebView` itself.
The representable's `NSViewType` changes from `WKWebView` to the firewall; nothing
else about `ComponentCanvasView`'s API changes.

**Adoption order:** `ComponentCanvasView` (`ComponentEditorCanvasPane.swift`) only.
`PreviewView` is deliberately left untouched — it is crash-free today, and wrapping
it would risk regressing WYSIWYG hit-testing/drop-targeting for no observed benefit.
If the firewall proves itself *and* a preview-side crash ever surfaces, adopting it
there is a follow-up, not part of this change.

**This is a hypothesis, not a certainty.** It is chosen because it is the cheapest
still-plausible lever: session-sized, zero UX change, keeps
`NavigationSplitView`/`.inspector()`, and testable against a 2/2-reliable repro.
If 5 consecutive repro runs still crash with the firewall in place, the hypothesis
is falsified — revert and escalate to Stage 3 rather than iterating on variants.

### Stage 3 — Hand-rolled `NSSplitViewController` window shell (deferred; NOT chosen)

Replacing `NavigationSplitView`/`.inspector()` with an AppKit
`NSSplitViewController`-based shell would remove the crash site entirely and give
direct control of layout timing — at the cost of weeks of work touching every
window, re-implementing column visibility, scene-state persistence, toolbar and
inspector integration, and a large accessibility/keyboard regression surface
(macOS spec compliance re-verification across the board). This is justified only
if Stage 2 is falsified **and** the bug persists at macOS 27 GM. It would get its
own design doc; nothing here commits to its shape.

## Ruled out

- **Detached window/panel hosting for WKWebView panes** — fragments the
  single-window site-editing model the macOS UX spec is built around; a
  platform-convention departure with a permanent UX cost for a (likely temporary)
  OS bug.
- **More timing mitigations** — empirically falsified by the 1500ms experiment;
  adding a fourth magic delay is exactly what #1155 warned against.
- **Reworking the Component Editor's own layout further** — falsified by the
  hand-rolled-split experiment; the loop is not local to the editor.

## Verification

- The crash requires a real windowed session (per `AppKitConstraintStormMitigation`'s
  own docs, headless runs can't trigger the storm), so every stage's pass/fail is a
  windowed manual run of the #1696 repro, 5× per verdict. Record outcomes on #1699 —
  #1143's unverified "fix" is the cautionary tale this process exists to avoid.
- Stage 2, if built: `swift test --package-path .` + Debug app build must stay green;
  the firewall type gets a unit test for its sizing invariants (intrinsic size
  reports `noIntrinsicMetric`; subview tracks container bounds), acknowledging the
  crash itself is only provable in a windowed run.
- **Success criteria for closing #1699:** the #1696 repro passes 5×, on whichever
  stage got it there, and #910's checklist can proceed past "Open File".

## Consequences

- #910 stays blocked until Stage 0 (or Stage 2) produces a passing repro.
- #1699 remains the tracking issue for the whole ladder; per-stage work items land
  as ordinary session-sized changes referencing it. Stage 3, if ever reached, opens
  as its own issue + design doc.
