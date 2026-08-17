import Microformats from "../../vendor/microformat-shiv/microformat-shiv.cjs";

export interface MF2Item {
  type: string[];
  properties: Record<string, unknown[]>;
  children?: MF2Item[];
}

export interface MF2Document {
  items: MF2Item[];
  rels: Record<string, string[]>;
  "rel-urls": Record<string, { rels: string[]; text?: string }>;
}

export function parseMicroformats(doc: Document): MF2Document {
  return Microformats.get({ node: doc.body }) as MF2Document;
}

export function findFirstHCard(mf2: MF2Document): MF2Item | null {
  return mf2.items.find((item) => item.type.includes("h-card")) ?? null;
}

export function summarizeTypes(mf2: MF2Document): Record<string, number> {
  const counts: Record<string, number> = {};
  const visit = (item: MF2Item): void => {
    for (const type of item.type) {
      counts[type] = (counts[type] ?? 0) + 1;
    }
    for (const child of item.children ?? []) {
      visit(child);
    }
  };
  for (const item of mf2.items) {
    visit(item);
  }
  return counts;
}
