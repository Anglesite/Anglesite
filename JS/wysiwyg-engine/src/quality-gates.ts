import type { BlockId, Op, OpResult } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import { computeHandleRect } from "./selection.js";

export type FindingCategory = "contrast" | "altText" | "headingOrder" | "linkIntegrity" | "imageWeight";
export type FindingSeverity = "advisory" | "warning";

/** A live quality-gate finding (spec §6). Wire-compatible with the Swift `Finding` type in
 *  `Sources/AnglesiteCore/WYSIWYG/QualityGates/Finding.swift`. */
export interface Finding {
  id: string;
  blockId: BlockId;
  category: FindingCategory;
  severity: FindingSeverity;
  message: string;
  fix?: Op;
}

/** Host -> engine seam for quality-gate findings (design doc §3) — deliberately separate from
 *  `HostTransport`: findings are a push-only advisory stream, not part of the ops protocol, so a
 *  host with no quality-gate service can simply never call the listener. */
export interface QualityGateTransport {
  onFindings(listener: (findings: Finding[]) => void): () => void;
}

/** Attribute a rendered chip element carries its `Finding.id` under. */
export const CHIP_ATTR = "data-quality-chip-id";

/** Owner-facing label per category, used only for ARIA naming — the chip's own visible text is
 *  `finding.message` (already owner-consequence phrased); this is what lets a screen-reader user
 *  tell several simultaneous chips (and their identically-worded "Apply" buttons) apart. */
const CATEGORY_LABELS: Record<FindingCategory, string> = {
  contrast: "Contrast",
  altText: "Alt text",
  headingOrder: "Heading order",
  linkIntegrity: "Broken link",
  imageWeight: "Image size",
};

/** One rendered chip plus what `#positionChip` needs to place it again later — a scroll/resize
 *  reposition has no findings push to re-derive the anchor block or stack slot from. */
interface RenderedChip {
  element: HTMLElement;
  blockId: BlockId;
  stackIndex: number;
}

/** Above any plausible page content: chips are advisory chrome floating over the owner's own site,
 *  which the engine has no say in the stacking context of. */
const CHIP_Z_INDEX = "2147483000";

/** Chips are drawn over a site whose CSS the engine doesn't control, so every visual property is
 *  set explicitly rather than inherited — the same "own every declaration" approach the e2e
 *  fixture's own block rendering takes. There is no stylesheet to hang a class off: the engine
 *  ships no CSS file and injects none (`selection.ts`/`drag-drop.ts` draw nothing themselves), so
 *  inline style is the convention here, not a shortcut. */
function styleChip(chip: HTMLElement, severity: FindingSeverity): void {
  chip.style.zIndex = CHIP_Z_INDEX;
  chip.style.display = "flex";
  chip.style.alignItems = "center";
  chip.style.flexWrap = "wrap"; // a long owner-consequence message wraps inside maxWidth
  chip.style.gap = "6px";
  chip.style.maxWidth = "22rem";
  chip.style.padding = "4px 8px";
  chip.style.borderRadius = "6px";
  chip.style.border = "1px solid rgba(255, 255, 255, 0.18)";
  chip.style.boxShadow = "0 1px 4px rgba(0, 0, 0, 0.32)";
  chip.style.font = "500 12px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif";
  chip.style.color = "#ffffff";
  chip.style.background = severity === "warning" ? "#9a3412" : "#334155";
  chip.style.pointerEvents = "auto";
}

function styleApplyButton(button: HTMLButtonElement): void {
  button.style.flex = "0 0 auto";
  button.style.padding = "2px 8px";
  button.style.borderRadius = "4px";
  button.style.border = "1px solid rgba(255, 255, 255, 0.5)";
  button.style.background = "rgba(255, 255, 255, 0.16)";
  button.style.color = "inherit";
  button.style.font = "inherit";
  button.style.cursor = "pointer";
}

/**
 * Renders quality-gate chips anchored to blocks (spec §3.1: the engine owns "quality-gate chips").
 * The host always pushes the full current finding set (design doc §3/§5, not a delta), so this does
 * its own keyed diff (by `Finding.id`) against what it has already rendered — a push never depends
 * on any previous one having arrived.
 */
export class QualityGateChips {
  #engine: WysiwygEngine;
  #container: HTMLElement;
  #chips = new Map<string, RenderedChip>();
  #unsubscribe: () => void;
  #reposition = (): void => this.#repositionAll();

  constructor(engine: WysiwygEngine, transport: QualityGateTransport, container: HTMLElement = document.body) {
    this.#engine = engine;
    this.#container = container;
    this.#unsubscribe = transport.onFindings((findings) => this.#render(findings));
    // Positions come from getBoundingClientRect(), i.e. viewport coordinates that go stale the
    // moment the page scrolls or the window resizes — and a findings push (the only other thing
    // that repositions anything) may not arrive for a long time, or ever.
    window.addEventListener("scroll", this.#reposition, true);
    window.addEventListener("resize", this.#reposition);
  }

  dispose(): void {
    this.#unsubscribe();
    window.removeEventListener("scroll", this.#reposition, true);
    window.removeEventListener("resize", this.#reposition);
    for (const chip of this.#chips.values()) chip.element.remove();
    this.#chips.clear();
  }

  #repositionAll(): void {
    for (const chip of this.#chips.values()) this.#positionChip(chip.element, chip.blockId, chip.stackIndex);
  }

  #render(findings: Finding[]): void {
    const seen = new Set<string>();
    // Tracks how many findings for the same block have been placed so far in this push, so a
    // second/third finding on one block offsets downward instead of overlapping the first
    // (design doc §4: "stack rather than overlap") — order follows the order the host sent them.
    const countByBlock = new Map<BlockId, number>();
    for (const finding of findings) {
      seen.add(finding.id);
      const stackIndex = countByBlock.get(finding.blockId) ?? 0;
      countByBlock.set(finding.blockId, stackIndex + 1);
      const existing = this.#chips.get(finding.id);
      if (existing) {
        existing.blockId = finding.blockId;
        existing.stackIndex = stackIndex;
        this.#updateChip(existing.element, finding, stackIndex);
      } else {
        const chip = this.#buildChip(finding);
        this.#chips.set(finding.id, { element: chip, blockId: finding.blockId, stackIndex });
        this.#container.appendChild(chip);
        this.#positionChip(chip, finding.blockId, stackIndex);
      }
    }
    for (const [id, chip] of this.#chips) {
      if (seen.has(id)) continue;
      chip.element.remove();
      this.#chips.delete(id);
    }
  }

  /** Positions `chip` near `blockId`'s on-screen element, offset downward by `stackIndex` steps so
   *  multiple findings on the same block stack rather than overlap — or, when there is no on-screen
   *  element (a page-level finding like contrast, anchored to the root sentinel; or a block that
   *  scrolled out of the DOM), in a fixed top-right tray rather than left unplaced.
   *
   *  The anchor is the block's trailing edge, which for a full-width block sits at (or past) the
   *  viewport's own right edge — so the `left` it computes is clamped to keep the whole chip, Apply
   *  button included, on screen and clickable. `offsetWidth` reads 0 for a chip not yet laid out
   *  (and always, under jsdom), which degrades to the unclamped anchor rather than misplacing it.
   */
  #positionChip(chip: HTMLElement, blockId: BlockId, stackIndex: number): void {
    chip.style.position = "fixed";
    const rect = computeHandleRect(blockId);
    const offset = stackIndex * 28;
    if (!rect) {
      chip.style.top = `${8 + offset}px`;
      chip.style.right = "8px";
      chip.style.left = "";
      return;
    }
    const maxLeft = Math.max(8, window.innerWidth - chip.offsetWidth - 8);
    chip.style.top = `${rect.y + offset}px`;
    chip.style.left = `${Math.min(rect.x + rect.width, maxLeft)}px`;
    chip.style.right = "";
  }

  /** Deliberately does *not* position: the caller appends first, then positions, so
   *  `#positionChip`'s viewport clamp has a real `offsetWidth` to work from. */
  #buildChip(finding: Finding): HTMLElement {
    const chip = document.createElement("div");
    chip.setAttribute(CHIP_ATTR, finding.id);
    chip.dataset.category = finding.category;
    chip.dataset.severity = finding.severity;
    // A screen-reader announcement channel: this feature's whole purpose is surfacing
    // accessibility issues to the owner, so the chip itself has to be perceivable by VoiceOver,
    // not just sighted. `role="status"`/`aria-live="polite"` makes assistive tech announce the
    // chip's content when it appears or its text changes — without this, a chip anchored to the
    // block currently being edited is otherwise silent. `aria-label` (set in #fillChip, since it
    // depends on message/category) names the region, per `docs/mac-assed-app-spec.md`'s "a custom
    // control is incomplete until it communicates ... with assistive technologies."
    chip.setAttribute("role", "status");
    chip.setAttribute("aria-live", "polite");
    styleChip(chip, finding.severity);
    this.#fillChip(chip, finding);
    return chip;
  }

  /** Re-appends before updating when the chip has been detached: a host that re-renders its canvas
   *  by clearing the container (the fixture's `root.innerHTML = ""`, and any real host doing the
   *  same) orphans every chip inside it, and `#chips` still holds the reference — so without this,
   *  a later push for the same `Finding.id` would faithfully update an element that is no longer
   *  in the page, and the chip would never come back. */
  #updateChip(chip: HTMLElement, finding: Finding, stackIndex: number): void {
    if (!chip.isConnected) this.#container.appendChild(chip);
    styleChip(chip, finding.severity);
    this.#positionChip(chip, finding.blockId, stackIndex);
    chip.dataset.severity = finding.severity;
    this.#fillChip(chip, finding);
  }

  #fillChip(chip: HTMLElement, finding: Finding): void {
    const categoryLabel = CATEGORY_LABELS[finding.category];
    chip.setAttribute("aria-label", `${categoryLabel} issue: ${finding.message}`);
    chip.replaceChildren();
    const message = document.createElement("span");
    message.textContent = finding.message;
    chip.appendChild(message);
    const fix = finding.fix;
    if (!fix) return;
    const applyButton = document.createElement("button");
    applyButton.type = "button";
    applyButton.textContent = "Apply";
    // Every chip's button reads the bare word "Apply" visually (deliberately terse), but several
    // can be on screen at once — without a distinguishing name, a screen-reader user tabbing
    // through them hears "Apply" repeated with no way to tell which finding each one fixes.
    applyButton.setAttribute("aria-label", `Apply fix for ${categoryLabel.toLowerCase()} issue`);
    styleApplyButton(applyButton);
    applyButton.addEventListener("click", () => {
      applyButton.disabled = true;
      void this.#engine.submit(fix).then((result: OpResult) => {
        if (result.status === "applied") {
          chip.remove();
          this.#chips.delete(finding.id);
        } else {
          applyButton.disabled = false;
        }
      });
    });
    chip.appendChild(applyButton);
  }
}
