// Element-metadata collection for JS → native messages that address a page element.
//
// The page script does NOT build a final selector — it collects a structured payload that the
// plugin's `server/selector.mjs` resolves on the native side. Keeps one source of truth for the
// selector strategy (data-anglesite-id > data-testid > #id > role/aria > stable classes >
// tag:nth-child) and avoids shipping a duplicated/fork-prone copy of that logic into JS.
// Decided in #18. Ported verbatim from the retired `JS/edit-overlay/src/selector.ts` (#1957).

export interface AncestorInfo {
  tag: string;
  id?: string;
  classes?: string[];
  nthChild?: number;
  role?: string;
  ariaLabel?: string;
}

export interface ElementInfo {
  tag: string;
  id?: string;
  classes: string[];
  nthChild: number;
  ancestors?: AncestorInfo[];
  dataAnglesiteId?: string;
  dataTestId?: string;
  role?: string;
  ariaLabel?: string;
  textContent?: string;
}

const MAX_TEXT_HINT = 80;

/** Collect `ElementInfo` for `element`. Ancestors are root-first and stop at (but include)
 *  `<body>`. `textContent` is whitespace-collapsed and truncated to 80 chars with an ellipsis;
 *  classes are forwarded raw (the server filters Astro's `astro-*` build hashes). */
export function elementInfoFor(element: Element): ElementInfo {
  return {
    ...leafInfoFor(element),
    ancestors: collectAncestors(element),
  };
}

function leafInfoFor(el: Element): Omit<ElementInfo, "ancestors"> {
  const info: Omit<ElementInfo, "ancestors"> = {
    tag: el.tagName,
    classes: classesOf(el),
    nthChild: positionAmongSiblings(el),
  };
  if (el.id) info.id = el.id;
  const dataAnglesiteId = el.getAttribute("data-anglesite-id");
  if (dataAnglesiteId) info.dataAnglesiteId = dataAnglesiteId;
  const dataTestId = el.getAttribute("data-testid");
  if (dataTestId) info.dataTestId = dataTestId;
  const role = el.getAttribute("role");
  if (role) info.role = role;
  const ariaLabel = el.getAttribute("aria-label");
  if (ariaLabel) info.ariaLabel = ariaLabel;
  const text = condenseText(el.textContent ?? "");
  if (text) info.textContent = text;
  return info;
}

function ancestorInfoFor(el: Element): AncestorInfo {
  const info: AncestorInfo = {
    tag: el.tagName,
    nthChild: positionAmongSiblings(el),
  };
  if (el.id) info.id = el.id;
  const classes = classesOf(el);
  if (classes.length > 0) info.classes = classes;
  const role = el.getAttribute("role");
  if (role) info.role = role;
  const ariaLabel = el.getAttribute("aria-label");
  if (ariaLabel) info.ariaLabel = ariaLabel;
  return info;
}

function collectAncestors(element: Element): AncestorInfo[] {
  // Walk parents up to (but not past) `<html>`. Include `<body>` so the server's selector path
  // can begin there; exclude `<html>` since selectors don't typically anchor there.
  const chain: Element[] = [];
  let cur: Element | null = element.parentElement;
  while (cur && cur.tagName !== "HTML") {
    chain.push(cur);
    cur = cur.parentElement;
  }
  // Root-first: reverse so the server's `buildSelector` can join with " > " directly.
  return chain.reverse().map(ancestorInfoFor);
}

function classesOf(el: Element): string[] {
  return Array.from(el.classList);
}

function positionAmongSiblings(el: Element): number {
  if (!el.parentElement) return 1;
  return Array.from(el.parentElement.children).indexOf(el) + 1;
}

function condenseText(raw: string): string {
  const normalized = raw.replace(/\s+/g, " ").trim();
  if (normalized.length <= MAX_TEXT_HINT) return normalized;
  return normalized.slice(0, MAX_TEXT_HINT) + "…";
}
