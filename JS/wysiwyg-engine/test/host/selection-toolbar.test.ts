// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { instructionForAction } from "../../src/host/selection-toolbar.js";

describe("instructionForAction", () => {
  it("builds a canned instruction for rewrite", () => {
    expect(instructionForAction("rewrite")).toContain("clearer");
  });

  it("builds a canned instruction for tighten", () => {
    expect(instructionForAction("tighten")).toMatch(/shorter/i);
  });

  it("builds a canned instruction for a tone preset", () => {
    const friendlier = instructionForAction("tone", "friendlier");
    const formal = instructionForAction("tone", "more formal");
    expect(friendlier).toContain("friendlier");
    expect(formal).toContain("more formal");
    expect(friendlier).not.toBe(formal);
  });
});
