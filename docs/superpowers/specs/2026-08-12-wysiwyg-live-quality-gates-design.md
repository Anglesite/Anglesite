# WYSIWYG slice 5 — live quality gates — design

Tracking: [#1226](https://github.com/Anglesite/Anglesite/issues/1226), part of epic
[#1221](https://github.com/Anglesite/Anglesite/issues/1221). Implements spec §6 of
[`2026-08-03-modern-wysiwyg-editor-design.md`](2026-08-03-modern-wysiwyg-editor-design.md).

## 1. Summary

After each applied op, the host re-analyzes the page's block model for five
categories of issue (contrast, alt text, heading order, link integrity, image
weight) and streams findings to the engine as advisory chips anchored to
blocks, phrased in owner consequences. Where the right answer is mechanical
(oversized image, heading skip), the chip offers a one-tap apply that submits
the fix through the normal ops pipeline — getting undo, coalescing, and
diffability for free. This is the editor's live, gentle front end; the
existing `pre-deploy-check.ts` / `a11y-audit.ts` hard backstop is unchanged
and still runs at deploy time.

## 2. Why native Swift, not the existing TS/Node a11y tooling

Two check systems already exist in this repo — `pre-deploy-check.ts` (security
posture, not a11y) and `a11y-audit.ts`/`a11y-validate.ts` (heading order, link
text, alt text, plus optional `pa11y`/`axe-core` contrast checks). Both
operate on fully **built `dist/` HTML**, run through the container executor.
That path is correct for an on-demand audit but too slow to run after every
keystroke.

This slice runs analysis natively in Swift, directly against the `BlockModel`
the host already holds in memory — no build, no container round-trip:

- **Contrast** reuses `Sources/AnglesiteCore/WCAGContrast.swift` as-is,
  evaluated against each block's resolved design tokens.
- **Alt text** and **heading order** are hand-ported from the pure
  tree/string logic in `Resources/Template/scripts/a11y-validate.ts` into
  Swift. There is no cross-language sharing bridge between the Node checker
  and the Swift host, and for logic this size (simple tree walks over typed
  data), porting is cheaper than building one. The two implementations are
  independent from this point forward — a change to one does not
  automatically apply to the other; note this in code comments at both sites.
- **Link integrity** checks internal `href`s only, against a lightweight route
  index the host builds when a site opens and refreshes on model updates.
  External-link reachability requires a network call and stays owned by the
  deploy-time backstop — it is not re-checked live.
- **Image weight** stats the resolved asset file directly under `Source/` —
  filesystem access, no build.

## 3. Architecture

```
WYSIWYGCanvasController.onOpApplied(op, inverse, newModel)
        │
        ▼
QualityGateRunner.analyze(newModel, GateContext) -> [Finding]
   (runs all 5 checkers, diffs against the previous finding set)
        │
        ▼  (delta only)
WYSIWYGOpsDispatcher: new host→engine push, "quality-findings"
        │  (webView.evaluateJavaScript calling a new
        │   window.__anglesiteWysiwygHost._handleQualityFindings(json) global,
        │   mirroring the existing _handleModelUpdate)
        ▼
JS/wysiwyg-engine/src/quality-gates.ts
   - anchors a chip per finding near its block (selection.ts handle-rect pattern)
   - click-to-expand: message + Apply button when a fix is present
        │  Apply clicked
        ▼
engine.submit(finding.fix)   // ordinary op — same path as any manual edit
```

`QualityGateRunner` is a new type in `Sources/AnglesiteCore/WYSIWYG/QualityGates/`,
owned by `WYSIWYGCanvasController` alongside the existing `undoCoordinator`
subscriber on `onOpApplied`. It requires no changes to the ops protocol
itself (`Op`, `invertOp`, `HostTransport`) — findings ride a new, separate
push channel, and applying a fix reuses `submit-op` unchanged.

### GateContext

Each checker receives the current `BlockModel` plus a small context object
carrying what it needs beyond the model itself:

```swift
struct GateContext {
    let resolvedTokens: [String: DesignToken]   // for contrast
    let internalRoutes: Set<String>              // for link integrity
    let assetRoot: URL                           // for image weight (Source/ layout)
}
```

`internalRoutes` is rebuilt when the model updates from an outside hand-edit
(same trigger as `ModelSync`'s staleness check), not on every op — the page
list changes far less often than block content does.

### Finding shape

```typescript
interface Finding {
  id: string;              // stable per (blockId, category) so re-renders diff cleanly
  blockId: string;
  category: "contrast" | "altText" | "headingOrder" | "linkIntegrity" | "imageWeight";
  severity: "advisory" | "warning";
  message: string;          // owner-consequence phrasing, e.g. "photos this big load
                             // slowly on phones" — never lint jargon
  fix?: Op;                 // present only for the two apply-capable categories this slice
}
```

Mirrored on the Swift side as `Finding` alongside the existing `WYSIWYGOps.swift`
types. `fix` is populated only for **headingOrder** this slice: a `setProp`
correcting the block's heading level to close a skip (e.g. h2 → h4 becomes
h2 → h3) — cheap and synchronous, computable straight from the model already
in memory.

**imageWeight is detection-only this slice, not apply.** Shrinking display
dimensions alone would not reduce bytes downloaded, so a real fix has to
produce an actual smaller/re-encoded asset file — which means an async,
MCP-backed round trip to the sidecar's image-optimization tool. Doing that
work inside the after-every-op analysis loop would reintroduce the exact
per-keystroke latency problem native-Swift analysis exists to avoid (§2), and
deferring it to click-time would need a second request/response message
alongside `submit-op` — real scope, not a detail. The chip still surfaces
with the owner-consequence message ("photos this big load slowly on
phones"); wiring its apply action to the sidecar's optimizer is a clean,
separable fast-follow (added to §7).

Contrast, alt text, and link-integrity findings are advisory-only this slice
— no mechanical fix is safe to apply without owner judgment (a color choice,
alt-text wording, or a corrected URL are all decisions, not derivations).

## 4. Chip UI

New `JS/wysiwyg-engine/src/quality-gates.ts`, engine-owned per spec §3.1
("quality-gate chips" is explicitly listed among what the engine owns). No
existing chip/badge primitive exists in the canvas chrome (`rich-text.ts`,
`drag-drop.ts`, `breakpoints.ts`, `selection.ts`) — this introduces one:

- A small anchored pill per finding, positioned via the same handle-rect
  geometry `selection.ts` already computes for selection handles.
- Multiple findings on one block stack/badge-count rather than overlap.
- Click expands to the message and, when `fix` is present, an Apply button.
- Applying calls `engine.submit(fix)` and optimistically removes the chip;
  if the op is rejected (stale model), the chip re-appears on the next
  findings push along with the rest of the reconciled set.

## 5. Error handling

- A checker throwing (bad token reference, unreadable asset file) is caught
  per-checker in `QualityGateRunner.analyze` — one broken category logs and
  contributes no findings rather than blocking the other four.
- If the findings push itself fails to reach the engine (webview reload
  mid-flight), the next `onOpApplied` cycle re-sends the full current set,
  not just a delta — the engine's chip set is always reconcilable from the
  latest push, never dependent on receiving every intermediate one.
- Link integrity's `internalRoutes` index failing to build (e.g. mid-way
  through a large content collection) degrades to "no link-integrity
  findings this cycle" rather than false positives.

## 6. Testing

- **Swift** (`AnglesiteCoreTests`): one test file per checker, feeding
  synthetic `BlockModel` + `GateContext` fixtures — known-bad token pairs for
  contrast, a heading tree with a skip, a block with a broken internal href,
  an oversized image stat. Plus a `QualityGateRunnerTests` covering the
  diff/delta logic and the per-checker error isolation from §5.
- **TypeScript** (`test/quality-gates.test.ts`, jsdom env per slice 3's
  convention): chip anchoring against `selection.ts`'s geometry, diff
  rendering (add/remove/update chips from successive pushes), and apply
  submitting the right op.
- **One Playwright e2e** (`e2e/quality-gates.spec.ts`): drop an oversized
  image onto the canvas, assert a chip appears with the owner-consequence
  message, click Apply, assert the resize op lands and the chip clears.

## 7. Out of scope (YAGNI)

- **Shadow-root piercing.** Spec §4.1 flags this as a future requirement once
  custom-element blocks exist in a theme; none do yet (confirmed: zero
  `customElements.define`/`attachShadow` usage anywhere under
  `Resources/Template`). `BlockKind` already has a `"custom-element"` case at
  the type level; no piercing logic is written until there's real
  shadow-DOM content to pierce.
- **AI-driven fixes** (e.g. AI-generated alt text). Explicitly slice 6.
- **Image-weight one-tap apply.** This slice ships detection only (see §3);
  wiring Apply to the sidecar's MCP-backed image-optimization tool is a
  fast-follow once the async request/response shape it needs is worth its
  own design pass.
- **External link reachability.** Stays owned by the deploy-time backstop;
  live gates check internal href resolution only.
- **Advisory-only categories getting apply buttons.** Contrast, alt text, and
  link integrity stay read-only chips this slice.
- **Collaboration-aware findings** (e.g. suppressing a chip a peer is already
  fixing). Slice 7 territory.

## 8. File structure

```
Sources/AnglesiteCore/WYSIWYG/QualityGates/
  QualityGateRunner.swift        — orchestrates the 5 checkers, diffs, error isolation
  GateContext.swift
  Finding.swift
  ContrastGate.swift              — wraps WCAGContrast.swift
  AltTextGate.swift                — ported from a11y-validate.ts
  HeadingOrderGate.swift           — ported from a11y-validate.ts
  LinkIntegrityGate.swift          — new
  ImageWeightGate.swift            — new

JS/wysiwyg-engine/src/
  quality-gates.ts                 — chip rendering, anchoring, diffing, apply submission

Sources/AnglesiteBridgeCore/
  WYSIWYGOpsDispatcher.swift        — +1 push message type ("quality-findings")

test/quality-gates.test.ts
e2e/quality-gates.spec.ts
AnglesiteCoreTests/WYSIWYG/QualityGates/*Tests.swift
```

## 9. Next steps

Hand off to `writing-plans` for a task-by-task implementation plan covering
the Swift checkers, the dispatcher push channel, the engine-side chip module,
and the test suites in §6.
