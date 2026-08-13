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

/**
 * Renders quality-gate chips anchored to blocks (spec §3.1: the engine owns "quality-gate chips").
 * The host always pushes the full current finding set (design doc §3/§5, not a delta), so this does
 * its own keyed diff (by `Finding.id`) against what it has already rendered — a push never depends
 * on any previous one having arrived.
 */
export class QualityGateChips {
  #engine: WysiwygEngine;
  #container: HTMLElement;
  #chips = new Map<string, HTMLElement>();
  #unsubscribe: () => void;

  constructor(engine: WysiwygEngine, transport: QualityGateTransport, container: HTMLElement = document.body) {
    this.#engine = engine;
    this.#container = container;
    this.#unsubscribe = transport.onFindings((findings) => this.#render(findings));
  }

  dispose(): void {
    this.#unsubscribe();
    for (const chip of this.#chips.values()) chip.remove();
    this.#chips.clear();
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
        this.#updateChip(existing, finding, stackIndex);
      } else {
        const chip = this.#buildChip(finding, stackIndex);
        this.#chips.set(finding.id, chip);
        this.#container.appendChild(chip);
      }
    }
    for (const [id, chip] of this.#chips) {
      if (seen.has(id)) continue;
      chip.remove();
      this.#chips.delete(id);
    }
  }

  /** Positions `chip` near `blockId`'s on-screen element, offset downward by `stackIndex` steps so
   *  multiple findings on the same block stack rather than overlap — or, when there is no on-screen
   *  element (a page-level finding like contrast, anchored to the root sentinel; or a block that
   *  scrolled out of the DOM), in a fixed top-right tray rather than left unplaced. */
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
    chip.style.top = `${rect.y + offset}px`;
    chip.style.left = `${rect.x + rect.width}px`;
    chip.style.right = "";
  }

  #buildChip(finding: Finding, stackIndex: number): HTMLElement {
    const chip = document.createElement("div");
    chip.setAttribute(CHIP_ATTR, finding.id);
    chip.dataset.category = finding.category;
    chip.dataset.severity = finding.severity;
    this.#positionChip(chip, finding.blockId, stackIndex);
    this.#fillChip(chip, finding);
    return chip;
  }

  #updateChip(chip: HTMLElement, finding: Finding, stackIndex: number): void {
    this.#positionChip(chip, finding.blockId, stackIndex);
    chip.dataset.severity = finding.severity;
    this.#fillChip(chip, finding);
  }

  #fillChip(chip: HTMLElement, finding: Finding): void {
    chip.replaceChildren();
    const message = document.createElement("span");
    message.textContent = finding.message;
    chip.appendChild(message);
    const fix = finding.fix;
    if (!fix) return;
    const applyButton = document.createElement("button");
    applyButton.type = "button";
    applyButton.textContent = "Apply";
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
