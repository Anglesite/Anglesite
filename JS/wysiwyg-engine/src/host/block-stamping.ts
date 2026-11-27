import type { BlockId, BlockModel, BlockNode, SourceLoc } from "../types.js";
import { BLOCK_ID_ATTR } from "../hit-test.js";

/**
 * Marks the live preview's DOM with block ids (#2239), so everything that finds a block by
 * `BLOCK_ID_ATTR` (hit-testing, the rich-text editor, the selection handle, scroll-into-view,
 * drag reorder) works on a real site, not only on the test fixtures, which render the attribute
 * themselves.
 *
 * The page is Astro's own render, so the mapping comes from what `astro dev` already stamps on
 * every element authored in an `.astro` file: `data-astro-source-file` (absolute path) and
 * `data-astro-source-loc` (`line:column` at about the end of the element's opening tag; measured
 * against `astro dev`, it can land one column past its first child's start). The page model
 * gives each node's start (`BlockNode.sourceLoc`). Within one file, an element's loc comes after
 * its own start, before the start of whatever follows it outside its subtree, and before every
 * one of its descendants' locs, so:
 *
 * - **An element written in the page** is the first stamped element of the page's file whose
 *   loc is at or after the block's start and before the next start outside the block's subtree,
 *   with the same tag name. An element that didn't render (a false conditional) matches nothing
 *   and stays unmarked, rather than taking a neighbour's element.
 * - **A manifest component** (`BlockNode.componentPath`) leaves no trace of where it was used,
 *   only its own file's elements. Its instances, in page order, pair with that file's top-level
 *   rendered elements, in DOM order — only when the counts match one-to-one. A component with
 *   several root elements, or one also rendered by a layout, is left unmarked.
 *
 * Builds only render none of these attributes, so this marks nothing outside `astro dev`.
 *
 * Astro's own dev toolbar (its Audit app) copies both attributes into a private map and removes
 * them from the DOM on `DOMContentLoaded`. {@link snapshotSourceAnnotations} runs first, from the
 * engine's injected script (a `WKUserScript` at `.atDocumentEnd`, which runs after parsing and
 * before `DOMContentLoaded`'s handlers), and keeps its own copy.
 */

const SOURCE_FILE_ATTR = "data-astro-source-file";
const SOURCE_LOC_ATTR = "data-astro-source-loc";

/** Each annotated element's `data-astro-source-*` values, captured before anything removes them. */
const snapshots = new WeakMap<Element, { file: string; loc: string }>();

/** Copies every element's `data-astro-source-file`/`-loc` aside. Call as early as possible on a
 *  freshly loaded page; calling again picks up elements added since. */
export function snapshotSourceAnnotations(root: ParentNode): void {
  for (const el of Array.from(root.querySelectorAll(`[${SOURCE_FILE_ATTR}][${SOURCE_LOC_ATTR}]`))) {
    const file = el.getAttribute(SOURCE_FILE_ATTR);
    const loc = el.getAttribute(SOURCE_LOC_ATTR);
    if (file && loc) snapshots.set(el, { file, loc });
  }
}

/** The element's source annotations: live attributes when present, else the snapshot. */
function annotationsOf(el: Element): { file: string; loc: string } | undefined {
  const file = el.getAttribute(SOURCE_FILE_ATTR);
  const loc = el.getAttribute(SOURCE_LOC_ATTR);
  return file && loc ? { file, loc } : snapshots.get(el);
}

interface Located {
  el: Element;
  file: string;
  line: number;
  column: number;
}

/** Orders two positions; negative when `a` comes first. */
function compare(a: SourceLoc, b: SourceLoc): number {
  return a.line - b.line || a.column - b.column;
}

function parseLoc(value: string | null): SourceLoc | null {
  const match = /^(\d+):(\d+)$/.exec(value ?? "");
  return match ? { line: Number(match[1]), column: Number(match[2]) } : null;
}

/** Whether Astro's absolute `file` is the project-relative `path`. Tolerates Windows separators. */
export function sameSourceFile(file: string, path: string): boolean {
  const normalized = file.replaceAll("\\", "/");
  const relative = path.replaceAll("\\", "/").replace(/^\.\//, "");
  return normalized === relative || normalized.endsWith(`/${relative}`);
}

/** HTML or custom-element tag names; component names (`BaseLayout`) start upper-case. */
const ELEMENT_TAG = /^[a-z][a-z0-9-]*$/;

function locatedElements(root: ParentNode): Located[] {
  snapshotSourceAnnotations(root); // anything still annotated now, e.g. added since the first snapshot
  const located: Located[] = [];
  for (const el of Array.from(root.querySelectorAll("*"))) {
    const annotations = annotationsOf(el);
    const loc = annotations && parseLoc(annotations.loc);
    if (annotations && loc) located.push({ el, file: annotations.file, ...loc });
  }
  return located;
}

/** Elements this module marked, per root — so clearing never touches a block id the page
 *  rendered itself (the e2e fixtures do, and a future server-side mapping might). */
const marked = new WeakMap<ParentNode, Set<Element>>();

function mark(root: ParentNode, el: Element, id: BlockId): boolean {
  if (el.hasAttribute(BLOCK_ID_ATTR)) return false;
  el.setAttribute(BLOCK_ID_ATTR, id);
  let set = marked.get(root);
  if (!set) marked.set(root, (set = new Set()));
  set.add(el);
  return true;
}

/** Removes the block ids this module set on `root`, and only those. */
export function clearBlockIds(root: ParentNode): void {
  for (const el of marked.get(root) ?? []) el.removeAttribute(BLOCK_ID_ATTR);
  marked.delete(root);
}

/**
 * Re-marks `root` for `model`: clears this module's old marks, then sets `BLOCK_ID_ATTR` on each
 * block's element as described above. An element that already carries a block id it didn't set
 * is left alone. Returns the ids it marked, for logging and tests.
 */
export function stampBlockIds(model: BlockModel, root: ParentNode): BlockId[] {
  clearBlockIds(root);
  const located = locatedElements(root);
  const stamped: BlockId[] = [];
  const blocks = Object.values(model.blocks);

  // Page-authored elements.
  const pageElements = located.filter((l) => sameSourceFile(l.file, model.path)).sort(compare);
  // In source order, so a parent claims its own loc before a child whose start that loc can
  // land just past (the one-column quirk above) looks at it.
  const claimed = new Set<Element>();
  const pageBlocks = blocks
    .filter(isPageElement)
    .sort((a, b) => compare(a.sourceLoc as SourceLoc, b.sourceLoc as SourceLoc));
  for (const block of pageBlocks) {
    const start = block.sourceLoc as SourceLoc;
    const next = nextStartOutside(block, model, blocks);
    const match = pageElements.find(
      (l) => !claimed.has(l.el) && compare(l, start) >= 0 && (!next || compare(l, next) < 0),
    );
    if (!match) continue;
    if (match.el.tagName.toLowerCase() !== block.componentName.toLowerCase()) continue;
    claimed.add(match.el);
    if (mark(root, match.el, block.id)) stamped.push(block.id);
  }

  // Manifest components, one-to-one by order.
  const byPath = new Map<string, BlockNode[]>();
  for (const block of blocks) {
    if (!block.componentPath || !block.sourceLoc) continue;
    byPath.set(block.componentPath, [...(byPath.get(block.componentPath) ?? []), block]);
  }
  for (const [path, instances] of byPath) {
    const roots = located
      .filter((l) => sameSourceFile(l.file, path) && !insideSameFile(l.el, l.file))
      .map((l) => l.el);
    if (roots.length !== instances.length) continue;
    instances.sort((a, b) => compare(a.sourceLoc as SourceLoc, b.sourceLoc as SourceLoc));
    instances.forEach((block, index) => {
      const el = roots[index];
      if (el && mark(root, el, block.id)) stamped.push(block.id);
    });
  }
  return stamped;
}

/** The earliest start after `block`'s own that isn't inside `block`'s subtree, or `undefined` if
 *  nothing follows it. Text starts count too: a following text node still ends the element. */
function nextStartOutside(block: BlockNode, model: BlockModel, blocks: BlockNode[]): SourceLoc | undefined {
  const start = block.sourceLoc as SourceLoc;
  const inside = new Set<string>([block.id]);
  const pending = [block];
  for (let current = pending.pop(); current; current = pending.pop()) {
    for (const childIds of Object.values(current.slots)) {
      for (const childId of childIds) {
        const child = model.blocks[childId];
        if (child && !inside.has(childId)) {
          inside.add(childId);
          pending.push(child);
        }
      }
    }
  }
  let next: SourceLoc | undefined;
  for (const other of blocks) {
    if (inside.has(other.id) || !other.sourceLoc || compare(other.sourceLoc, start) <= 0) continue;
    if (!next || compare(other.sourceLoc, next) < 0) next = other.sourceLoc;
  }
  return next;
}

function isPageElement(block: BlockNode): boolean {
  return (
    block.kind !== "text" &&
    block.kind !== "fragment" &&
    block.componentPath === undefined &&
    block.sourceLoc !== undefined &&
    ELEMENT_TAG.test(block.componentName)
  );
}

/** Whether `el` sits inside another element rendered from `file` — i.e. it isn't a root of that
 *  file's render. */
function insideSameFile(el: Element, file: string): boolean {
  for (let parent = el.parentElement; parent; parent = parent.parentElement) {
    const parentFile = annotationsOf(parent)?.file;
    if (parentFile !== undefined) return parentFile === file;
  }
  return false;
}
