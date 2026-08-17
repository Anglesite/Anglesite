import { describe, expect, it } from "vitest";
import { buildVCard } from "../../src/popup/vcard";
import type { MF2Item } from "../../src/detect/microformats";

describe("buildVCard", () => {
  it("renders a vCard from h-card properties", () => {
    const hCard: MF2Item = {
      type: ["h-card"],
      properties: {
        name: ["Glenn Jones"],
        org: ["Example Org"],
        url: ["https://example.com/glenn"],
        email: ["mailto:glenn@example.com"],
      },
    };
    const vcard = buildVCard(hCard);
    expect(vcard).toContain("BEGIN:VCARD");
    expect(vcard).toContain("FN:Glenn Jones");
    expect(vcard).toContain("ORG:Example Org");
    expect(vcard).toContain("URL:https://example.com/glenn");
    expect(vcard).toContain("EMAIL:glenn@example.com");
    expect(vcard).toContain("END:VCARD");
  });

  it("omits optional lines that have no value and falls back to Unknown for a missing name", () => {
    const hCard: MF2Item = { type: ["h-card"], properties: {} };
    const vcard = buildVCard(hCard);
    expect(vcard).toContain("FN:Unknown");
    expect(vcard).not.toContain("ORG:");
    expect(vcard).not.toContain("URL:");
    expect(vcard).not.toContain("EMAIL:");
  });
});
