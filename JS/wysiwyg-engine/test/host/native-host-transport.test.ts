// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { NativeHostTransport } from "../../src/host/native-host-transport.js";

describe("NativeHostTransport", () => {
  let postedMessages: unknown[];

  beforeEach(() => {
    postedMessages = [];
    (window as any).webkit = {
      messageHandlers: {
        wysiwyg: { postMessage: (body: unknown) => postedMessages.push(body) },
      },
    };
    delete (window as any).__anglesiteWysiwygHost;
  });

  it("posts a submit-op message and resolves when the native side replies", async () => {
    const transport = new NativeHostTransport();
    void transport; // constructing installs window.__anglesiteWysiwygHost
    const envelope = { id: "req-1", targetVersion: "v0", op: { kind: "setDesignToken", tokenName: "t", value: "a", previousValue: "b" } } as const;
    const pending = transport.sendOp(envelope);
    expect(postedMessages).toEqual([{ type: "submit-op", envelope }]);
    const model = { path: "p", version: "v1", rootIds: [], blocks: {} };
    (window as any).__anglesiteWysiwygHost._handleOpResult("req-1", { status: "applied", model });
    await expect(pending).resolves.toEqual({ status: "applied", model });
  });

  it("notifies model-update listeners when the native side pushes one", () => {
    const transport = new NativeHostTransport();
    const seen: unknown[] = [];
    const unsubscribe = transport.onModelUpdate((model) => seen.push(model));
    const model = { path: "p", version: "v2", rootIds: [], blocks: {} };
    (window as any).__anglesiteWysiwygHost._handleModelUpdate(model);
    expect(seen).toEqual([model]);
    unsubscribe();
    (window as any).__anglesiteWysiwygHost._handleModelUpdate(model);
    expect(seen).toHaveLength(1);
  });

  it("notifies findings listeners when the native side pushes quality-gate findings", () => {
    const transport = new NativeHostTransport();
    const seen: unknown[] = [];
    const unsubscribe = transport.onFindings((findings) => seen.push(findings));
    const findings = [{ id: "b1::imageWeight", blockId: "b1", category: "imageWeight", severity: "warning", message: "big" }];
    (window as any).__anglesiteWysiwygHost._handleQualityFindings(findings);
    expect(seen).toEqual([findings]);
    unsubscribe();
    (window as any).__anglesiteWysiwygHost._handleQualityFindings(findings);
    expect(seen).toHaveLength(1);
  });

  it("posts a writing-help-request message and resolves when the native side replies", async () => {
    const transport = new NativeHostTransport();
    const pending = transport.requestWritingHelp("Original text.", "Tighten this.");
    expect(postedMessages).toHaveLength(1);
    const posted = postedMessages[0] as { type: string; requestId: string; text: string; instruction: string };
    expect(posted.type).toBe("writing-help-request");
    expect(posted.text).toBe("Original text.");
    expect(posted.instruction).toBe("Tighten this.");
    expect(typeof posted.requestId).toBe("string");
    (window as any).__anglesiteWysiwygHost._handleWritingHelpReply(posted.requestId, { status: "rewritten", text: "Shorter." });
    await expect(pending).resolves.toEqual({ status: "rewritten", text: "Shorter." });
  });

  it("resolves with an unavailable reply when the native side reports one", async () => {
    const transport = new NativeHostTransport();
    const pending = transport.requestWritingHelp("x", "y");
    const posted = postedMessages[0] as { requestId: string };
    (window as any).__anglesiteWysiwygHost._handleWritingHelpReply(posted.requestId, { status: "unavailable", message: "not available" });
    await expect(pending).resolves.toEqual({ status: "unavailable", message: "not available" });
  });
});
