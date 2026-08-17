import type { MF2Item } from "../detect/microformats";

function firstValue(properties: Record<string, unknown[]>, key: string): string | null {
  const value = properties[key]?.[0];
  return typeof value === "string" ? value : null;
}

/**
 * Escapes a vCard (RFC 2426) property value: `;`, `,`, and `\` are backslash-escaped and newlines
 * become the literal two-character sequence `\n`. Applied uniformly to every value written into
 * the card — URLs and emails don't technically need comma/semicolon escaping, but a typical URL
 * or email doesn't contain those characters raw, so applying the same helper everywhere is
 * simpler and harmless.
 */
function escapeVCardValue(value: string): string {
  return value.replace(/([\\;,])/g, "\\$1").replace(/\n/g, "\\n");
}

export function buildVCard(hCard: MF2Item): string {
  const name = firstValue(hCard.properties, "name") ?? "Unknown";
  const org = firstValue(hCard.properties, "org");
  const url = firstValue(hCard.properties, "url");
  const email = firstValue(hCard.properties, "email");

  const lines = [
    "BEGIN:VCARD",
    "VERSION:3.0",
    `FN:${escapeVCardValue(name)}`,
    // Structured name (N) is mandatory in vCard 3.0. mf2 h-card only reliably gives a flat
    // `name`, not separate family/given/additional/prefix/suffix fields, so the display name goes
    // in the "given name" slot with the rest left empty — a common, acceptable pattern for
    // sources without structured name data.
    `N:;${escapeVCardValue(name)};;;`,
  ];
  if (org) lines.push(`ORG:${escapeVCardValue(org)}`);
  if (url) lines.push(`URL:${escapeVCardValue(url)}`);
  if (email) lines.push(`EMAIL:${escapeVCardValue(email.replace(/^mailto:/i, ""))}`);
  lines.push("END:VCARD");
  return lines.join("\r\n");
}
