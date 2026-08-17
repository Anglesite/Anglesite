import type { MF2Item } from "../detect/microformats";

function firstValue(properties: Record<string, unknown[]>, key: string): string | null {
  const value = properties[key]?.[0];
  return typeof value === "string" ? value : null;
}

export function buildVCard(hCard: MF2Item): string {
  const name = firstValue(hCard.properties, "name") ?? "Unknown";
  const org = firstValue(hCard.properties, "org");
  const url = firstValue(hCard.properties, "url");
  const email = firstValue(hCard.properties, "email");

  const lines = ["BEGIN:VCARD", "VERSION:3.0", `FN:${name}`];
  if (org) lines.push(`ORG:${org}`);
  if (url) lines.push(`URL:${url}`);
  if (email) lines.push(`EMAIL:${email.replace(/^mailto:/i, "")}`);
  lines.push("END:VCARD");
  return lines.join("\r\n");
}
