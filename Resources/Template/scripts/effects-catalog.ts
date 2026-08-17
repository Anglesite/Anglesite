import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export type EffectCategory =
  | "text" | "cards" | "buttons" | "backgrounds" | "navigation"
  | "canvasBackground" | "cursorReactive" | "scrollDriven" | "generativeArt";

export interface EffectPlacement {
  kind: "inline" | "background";
  allowedParents: string[] | null;
}

export interface EffectCatalogEntry {
  component: string;
  title: string;
  ownerDescription: string;
  category: EffectCategory;
  keyProps: Record<string, string>;
  props: Record<string, unknown>;
  snippet: string;
  placement?: EffectPlacement;
}

export interface EffectsCatalog {
  version: number;
  components: EffectCatalogEntry[];
}

const HERE = dirname(fileURLToPath(import.meta.url));

export function catalogPath(): string {
  return resolve(HERE, "../integrations/effects.json");
}

export function loadEffectsCatalog(): EffectsCatalog {
  return JSON.parse(readFileSync(catalogPath(), "utf8")) as EffectsCatalog;
}

/** Entries with no `placement` — legacy `@astroanimate/core` micro-animations, copy-paste only. */
export function legacyEntries(catalog: EffectsCatalog): EffectCatalogEntry[] {
  return catalog.components.filter((e) => !e.placement);
}

/** Entries with `placement` — the 12 new hand-authored effects, each with a real
 *  `src/components/effects/<component>.astro` file. */
export function placeableEntries(catalog: EffectsCatalog): EffectCatalogEntry[] {
  return catalog.components.filter((e) => !!e.placement);
}
