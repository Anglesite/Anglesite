# WebViewLayoutFirewall (Stage 2 of #1699) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Starve the macOS 27 beta `SplitViewChildController` min/max-size negotiation loop by giving the Component Editor canvas's `NSViewRepresentable` constant sizing metrics at both the AppKit layer (a frame-based container `NSView`) and the SwiftUI layer (`sizeThatFits` returning a pure function of the proposal).

**Architecture:** One new `NSView` subclass (`WebViewLayoutFirewall`) hosts the canvas `WKWebView` via autoresizing masks — no Auto Layout between container and webview, no intrinsic size. `ComponentCanvasView` (in `ComponentEditorCanvasPane.swift`) changes its `NSViewType` from `WKWebView` to the firewall and implements `sizeThatFits(_:nsView:context:)` so SwiftUI never falls back to measuring the webview. `PreviewView` is deliberately untouched (crash-free today; see the spec's Adoption order). Verification is the spec's 5× windowed repro — this is a falsifiable hypothesis: 5 crashes with the firewall in place means revert and escalate, not iterate.

**Tech Stack:** Swift 6.4 / SwiftUI / AppKit / WebKit; Swift Testing for unit tests; AX-scripted windowed repro via `osascript`.

**Spec:** `docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md` (Stage 2).

## Global Constraints

- Apple frameworks only; no new dependencies.
- Doc comments follow `docs/comment-style-guide.md`; CI fails on broken DocC links.
- Commit subjects: conventional, issue-scoped, **≤72 chars**. Use non-closing types (`feat`/`test`/`docs`) scoped to #1699 — the PR body's `Closes #1699` does the closing (CONTRIBUTING ▸ commit-scope/closing-keyword collision).
- No new user-visible strings in this change → no String Catalog sync needed. If any user-facing string does get added, run the CONTRIBUTING `xcstringstool sync` recipe scoped to this worktree's `BUILD_DIR`.
- PR body must use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings: **Summary**, **Paired PR check**, **Test plan**. Self-contained app change — no sidecar pairing.
- Work happens in this worktree (`.claude/worktrees/issue-775-status-cbd65b`, branch `claude/issue-1699-6ba2fd`); container artifacts are already provisioned; `Anglesite.xcodeproj` is generated (use `scripts/build-app.sh`, never raw `xcodebuild`).

---

### Task 1: `WebViewLayoutFirewall` type

**Files:**
- Create: `Sources/AnglesiteApp/WebViewLayoutFirewall.swift`
- Test: `Tests/AnglesiteAppTests/WebViewLayoutFirewallTests.swift`

**Interfaces:**
- Consumes: nothing app-specific (AppKit/WebKit only).
- Produces: `final class WebViewLayoutFirewall: NSView` with `init(webView: WKWebView)`, `let webView: WKWebView`, and `static func sizeResponse(width: CGFloat?, height: CGFloat?) -> CGSize`. Task 2 depends on all three exactly as named.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/WebViewLayoutFirewallTests.swift`:

```swift
import Testing
import AppKit
import WebKit
@testable import AnglesiteAppCore

/// Sizing invariants for the #1699 Stage 2 layout firewall: the container must present
/// constant metrics to `NSHostingView`/`SplitViewChildController` no matter what the wrapped
/// `WKWebView` does internally. The crash itself is only provable in a windowed run (see the
/// spec's Verification section); these tests freeze the invariants that make the firewall one.
@MainActor
@Suite("WebViewLayoutFirewall sizing invariants (#1699)")
struct WebViewLayoutFirewallTests {
    private func makeFirewall() -> WebViewLayoutFirewall {
        WebViewLayoutFirewall(webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
    }

    @Test("reports no intrinsic size on either axis")
    func noIntrinsicSize() {
        let firewall = makeFirewall()
        #expect(firewall.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        #expect(firewall.intrinsicContentSize.height == NSView.noIntrinsicMetric)
    }

    @Test("hosts the webview frame-based, not with Auto Layout")
    func frameBasedHosting() {
        let firewall = makeFirewall()
        #expect(firewall.webView.superview === firewall)
        #expect(firewall.webView.translatesAutoresizingMaskIntoConstraints)
        #expect(firewall.webView.autoresizingMask.contains(.width))
        #expect(firewall.webView.autoresizingMask.contains(.height))
        #expect(firewall.constraints.isEmpty)
        #expect(firewall.webView.constraints.allSatisfy { $0.firstItem !== firewall && $0.secondItem !== firewall })
    }

    @Test("webview tracks the container's frame")
    func webViewTracksFrame() {
        let firewall = makeFirewall()
        firewall.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        #expect(firewall.webView.frame == firewall.bounds)
        firewall.setFrameSize(NSSize(width: 800, height: 300))
        #expect(firewall.webView.frame == firewall.bounds)
    }

    @Test("sizeResponse is a pure function of the proposal")
    func sizeResponseIsPure() {
        // Min probe (0), max probe (infinity), and a concrete proposal each map straight
        // through; unspecified dimensions collapse to 0 (fully flexible, no opinion).
        #expect(WebViewLayoutFirewall.sizeResponse(width: 0, height: 0) == .zero)
        #expect(WebViewLayoutFirewall.sizeResponse(width: .infinity, height: .infinity)
            == CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        #expect(WebViewLayoutFirewall.sizeResponse(width: 512, height: 384)
            == CGSize(width: 512, height: 384))
        #expect(WebViewLayoutFirewall.sizeResponse(width: nil, height: nil) == .zero)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter WebViewLayoutFirewallTests 2>&1 | tail -20`
Expected: compile FAILURE — `cannot find 'WebViewLayoutFirewall' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteApp/WebViewLayoutFirewall.swift`:

```swift
import AppKit
import WebKit

/// Frame-based container for a `WKWebView` mounted via `NSViewRepresentable` inside the site
/// window's `NavigationSplitView`/`.inspector()` chrome — Stage 2 of the #1699 design
/// (`docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md`).
///
/// On macOS 27 beta, a `WKWebView`-hosting representable mounting while the detail column
/// reconfigures feeds a self-sustaining min/max-size negotiation loop between `NSHostingView`
/// and AppKit's private `SplitViewChildController`, which ends in the runaway-constraints
/// guard aborting the process (#1696, 5/5 reproductions on 26A5425a). This container starves
/// that loop by presenting constant sizing metrics: it has no intrinsic size, holds no Auto
/// Layout relationship with the webview (autoresizing masks only), and — via
/// ``sizeResponse(width:height:)`` — answers SwiftUI's sizing probes as a pure function of
/// the proposal, so repeated probes can never produce new values to renegotiate.
@MainActor
final class WebViewLayoutFirewall: NSView {
    /// The wrapped webview. Exposed so representable `updateNSView`/coordinator logic keeps
    /// operating on the `WKWebView` itself (loads, bridges, `onWebView` reporting).
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("WebViewLayoutFirewall is code-constructed only") }

    /// Constant by contract: the firewall never has an opinion the layout system could react
    /// to. (`NSView`'s default is already `noIntrinsicMetric`; overriding pins the invariant
    /// against AppKit changing that default and gives the unit test a symbol to freeze.)
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// The answer `ComponentCanvasView.sizeThatFits(_:nsView:context:)` returns for a sizing
    /// proposal: the proposal itself, with unspecified dimensions collapsed to zero. Min probe
    /// → 0, max probe → infinity, concrete proposal → itself — fully flexible, zero-opinion,
    /// and (the property the firewall exists for) a pure function of the input, so SwiftUI's
    /// measurement never varies across passes. Static and view-independent so the unit tests
    /// can freeze it without constructing a representable `Context`.
    static func sizeResponse(width: CGFloat?, height: CGFloat?) -> CGSize {
        CGSize(width: width ?? 0, height: height ?? 0)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter WebViewLayoutFirewallTests 2>&1 | tail -20`
Expected: 4 tests PASS. (If `swift test` hangs silently, check `pgrep -fl swift-test` for a stale SwiftPM lock-holder first.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/WebViewLayoutFirewall.swift Tests/AnglesiteAppTests/WebViewLayoutFirewallTests.swift
git commit -m "feat(#1699): add WebViewLayoutFirewall container"
```

---

### Task 2: Adopt the firewall in `ComponentCanvasView`

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorCanvasPane.swift:197-246` (the `ComponentCanvasView` representable)

**Interfaces:**
- Consumes: `WebViewLayoutFirewall(webView:)`, `.webView`, `WebViewLayoutFirewall.sizeResponse(width:height:)` from Task 1.
- Produces: no API change visible outside the file — `ComponentCanvasView`'s call sites (`ComponentEditorCanvasPane`) and its `onWebView: (WKWebView) -> Void` contract are unchanged.

- [ ] **Step 1: Change the representable's view type**

In `ComponentEditorCanvasPane.swift`, `ComponentCanvasView.makeNSView` currently ends (lines 224–231):

```swift
        let configuration = WebViewBridge.localDevConfiguration(handler: handler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewBridge.applyPreviewDefaults(to: webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        onWebView(webView)
        return webView
    }
```

Replace the signature and body so it returns the firewall (webview setup unchanged):

```swift
    func makeNSView(context: Context) -> WebViewLayoutFirewall {
        let onSelection = self.onSelection
        let onComputedStyles = self.onComputedStyles
        let handler = AnglesiteScriptHandler(
            router: resolveEditRouter(editRouter),
            onCanvasSelection: { message in await MainActor.run { onSelection(message) } },
            onComputedStyles: { report in await MainActor.run { onComputedStyles(report) } }
        )
        let configuration = WebViewBridge.localDevConfiguration(handler: handler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewBridge.applyPreviewDefaults(to: webView)
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        onWebView(webView)
        // #1699 Stage 2: the webview must not be the representable's NSViewType — mounting a
        // bare WKWebView during a detail-column swap feeds the macOS 27 beta
        // SplitViewChildController negotiation storm. See WebViewLayoutFirewall's doc comment.
        return WebViewLayoutFirewall(webView: webView)
    }
```

- [ ] **Step 2: Update `updateNSView` and add `sizeThatFits`**

Replace `updateNSView` (currently lines 233–245) with:

```swift
    func updateNSView(_ container: WebViewLayoutFirewall, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        let targetURL = url
        let coordinator = context.coordinator
        let webView = container.webView
        coordinator.pendingReload?.cancel()
        coordinator.pendingReload = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            coordinator.loadedURL = targetURL
            coordinator.pendingReload = nil
            webView.load(URLRequest(url: targetURL))
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: WebViewLayoutFirewall, context: Context
    ) -> CGSize? {
        // Never return nil: nil falls back to SwiftUI measuring the platform view, which is
        // exactly the varying-answer path the firewall exists to bypass (#1699 Stage 2).
        WebViewLayoutFirewall.sizeResponse(width: proposal.width, height: proposal.height)
    }
```

Also update the type's doc comment (lines 191–196) by appending one sentence to the existing paragraph: `Hosted inside a `WebViewLayoutFirewall` (not returned bare) — see that type's doc comment for the #1699 constraint-storm rationale.`

- [ ] **Step 3: Verify the package still builds and the full app-side suite passes**

Run: `swift test --package-path . 2>&1 | tail -5`
Expected: 0 failures. (Don't run concurrently with another agent's full `swift test` on this machine — FoundationModels suites flake under contention.)

- [ ] **Step 4: Build the app**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (warning "Check container resources" is fine only if the `Resources/container-*` artifacts are missing — they're provisioned in this worktree, so it should not appear).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorCanvasPane.swift
git commit -m "feat(#1699): mount canvas webview behind layout firewall"
```

---

### Task 3: Windowed 5× repro verification

The spec's falsifiability contract: **5 consecutive windowed runs of the #1696 repro with 0 crashes = hypothesis confirmed; any 5-run set with crashes = revert Task 2 (keep Task 1's type only if something else adopts it — otherwise revert both) and escalate to Stage 3 discussion. No variant-iterating.**

Preconditions (already true in this session's environment; re-establish if executing fresh): built Debug app in this worktree's DerivedData; `Untitled 4.anglesite` in the app's recents (`Hcard.astro` + seeded `profile.json`); `osascript` has Accessibility permission; no other agent driving the GUI.

- [ ] **Step 1: Record the pre-run crash-report baseline**

```bash
ls -t ~/Library/Logs/DiagnosticReports/Anglesite-*.ips 2>/dev/null | head -3
```

Note the newest timestamp — only reports newer than this count.

- [ ] **Step 2: Run the scripted repro 5×**

For each run: launch the app, open `Untitled 4` (crash-restore dialog: click Reopen; if a `SecurityAgent` keychain prompt appears, the human clicks Deny — see #1705), wait for the window title to show the dev-server URL, then Website ▸ Graph… → set the graph search field to `Hcard` → click the `Hcard.astro` node → click **Open File** → watch 12s. The exact harness (AX paths verified against current `main` this session):

```bash
APP="$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Anglesite.app"
for RUN in 1 2 3 4 5; do
  open "$APP"; sleep 6
  osascript -e 'tell application "System Events" to tell process "Anglesite" to click button "Reopen" of window 1' >/dev/null 2>&1
  for i in $(seq 1 25); do T=$(osascript -e 'tell application "System Events" to tell process "Anglesite" to get name of window 1' 2>/dev/null); case "$T" in *http*) break;; esac; sleep 3; done
  osascript >/dev/null 2>&1 <<'EOF'
tell application "System Events" to tell process "Anglesite"
  set frontmost to true
  click menu item "Graph…" of menu "Website" of menu bar item "Website" of menu bar 1
  delay 5
  set g to group 2 of splitter group 1 of group 2 of splitter group 1 of group 1 of splitter group 1 of group 1 of window 1
  set focused of text field 1 of g to true
  set value of text field 1 of g to "Hcard"
  delay 2
end tell
EOF
  osascript -e 'tell application "System Events" to click at {857, 524}' >/dev/null 2>&1   # Hcard.astro node
  sleep 2
  osascript -e 'tell application "System Events" to click at {1217, 253}' >/dev/null 2>&1  # Open File
  VERDICT="ALIVE (canvas mounted)"
  for i in 1 2 3 4 5 6; do sleep 2; pgrep -x Anglesite >/dev/null || { VERDICT="DEAD after $((i*2))s"; break; }; done
  echo "RUN$RUN: $VERDICT"
  osascript -e 'tell application "Anglesite" to quit' >/dev/null 2>&1; sleep 3; pkill -x Anglesite 2>/dev/null; sleep 2
done
```

(The two `click at` coordinates assume the same screen/window placement as this session's Stage 0 runs; if the node/button don't hit, re-derive them from a `screencapture -x` screenshot — node is the lone canvas card after filtering, Open File is the detail-pane button.)

Expected: `RUN1..RUN5: ALIVE (canvas mounted)` and **no new** `Anglesite-*.ips` newer than the Step 1 baseline.

- [ ] **Step 3: Positive functional check (not just absence-of-crash)**

On the final run, before quitting: `screencapture -x /tmp/firewall-canvas.png` and confirm visually that the Component Editor actually opened and the canvas pane renders the Hcard component (or its loading state progressing to content) — the firewall must not have broken canvas display, sizing (canvas fills its pane), or the Design/Source toggle chrome.

- [ ] **Step 4: Record the verdict**

Append the outcome (date, OS build, 5-run table, new-crash-report count) to the spec's Status block in `docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md`, and post it as a comment on #1699.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md
git commit -m "docs(#1699): record Stage 2 firewall verification verdict"
```

---

### Task 4: PR

- [ ] **Step 1: Re-read CONTRIBUTING ▸ "Commits and pull requests" and the PR template**

Read `.github/PULL_REQUEST_TEMPLATE.md` and copy its exact headings.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin claude/issue-1699-6ba2fd
gh pr create --repo Anglesite/Anglesite \
  --title "fix(#1699): firewall canvas WKWebView against split storm" \
  --body "$(cat <<'EOF'
## Summary

- Adds `WebViewLayoutFirewall`, a frame-based container `NSView` that presents constant sizing metrics (no intrinsic size, no Auto Layout to its webview, `sizeThatFits` a pure function of the proposal), and mounts the Component Editor canvas's `WKWebView` behind it.
- This is Stage 2 of the #1699 design (`docs/superpowers/specs/2026-08-31-wkwebview-split-chrome-crash-design.md`): on macOS 27 beta (verified through Beta 8, 26A5425a), a bare WKWebView-hosting representable mounting during a detail-column swap feeds AppKit's private `SplitViewChildController` min/max negotiation loop until the runaway-constraints guard aborts the app (#1696: 5/5 reproductions).
- Also carries the #1699 design doc + Stage 0/Stage 2 verification records and the Stage 2 implementation plan.

Closes #1699

## Paired PR check

- [x] This change is **self-contained** to `Anglesite/Anglesite`.
- [ ] This change **needs a paired PR** in [`Anglesite/anglesite-skills`](https://github.com/Anglesite/anglesite-skills) (MCP sidecar server).

## Test plan

- [ ] `swift test --package-path .` — full suite green, including new `WebViewLayoutFirewallTests` sizing invariants.
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — succeeded.
- [ ] Windowed #1696 repro (Graph → Hcard.astro → Open File) 5× on macOS 27 Beta 8 (26A5425a): 0 crashes, 0 new `.ips`; canvas renders and fills its pane (screenshot check). Same harness that reproduced the crash 5/5 pre-fix the same day.
EOF
)"
```

Check the checkboxes in the body to reflect what actually ran (edit before submitting if a step was skipped — do not claim unrun checks).

- [ ] **Step 3: Confirm the PR and issue state**

`gh pr view --repo Anglesite/Anglesite` — verify the body sections match the template and `Closes #1699` is present. Leave the `🛠️ In Progress` label on #1699 per CONTRIBUTING.
